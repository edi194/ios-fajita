// Fastboot over WebUSB. Protocol: ASCII commands of at most 64 bytes on bulk OUT; replies on bulk IN are
// "INFO..." / "TEXT..." (progress, keep reading), "DATA%08x" (send that many bytes now), "OKAY..." or "FAIL...".
// Prior art: fastboot.js (Danny Lin, MIT) and GrapheneOS's web installer (MIT); this is a fresh implementation
// built around streaming sparse pieces and a hard command/partition allowlist.

/** The only partitions this site can ever write. Never modem, persist, bluetooth, dsp or a bootloader. */
export const ALLOWED_PARTITIONS = ["userdata", "boot", "logo"] as const;
export type Partition = (typeof ALLOWED_PARTITIONS)[number];

export const USB_FILTERS: USBDeviceFilter[] = [{ classCode: 0xff, subclassCode: 0x42, protocolCode: 0x03 }];

export class FastbootError extends Error {}

export type LogKind = "cmd" | "okay" | "info" | "fail" | "data" | "note";
export type Logger = (kind: LogKind, text: string) => void;

/** Commands the client may send. Everything else (erase, format, oem, flashing unlock, set_active...) is refused here. */
function allowed(cmd: string): boolean {
  if (/^getvar:[A-Za-z0-9_:.-]{1,58}$/.test(cmd)) return true;
  if (/^download:[0-9a-f]{8}$/.test(cmd)) return true;
  const flash = /^flash:(.+)$/.exec(cmd);
  if (flash) return (ALLOWED_PARTITIONS as readonly string[]).includes(flash[1]);
  return cmd === "reboot" || cmd === "reboot-bootloader";
}

const withTimeout = <T>(p: Promise<T>, ms: number, what: string): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new FastbootError(`${what}: no answer from the phone after ${Math.round(ms / 1000)} s (unplug and replug it, then start again)`)), ms);
    p.then((v) => (clearTimeout(t), resolve(v)), (e) => (clearTimeout(t), reject(e)));
  });

export class FastbootDevice {
  private epIn = 0;
  private epOut = 0;
  private packetIn = 512;
  private iface = 0;
  private busy = false;
  log: Logger = () => {};
  readonly usb: USBDevice;

  private constructor(usb: USBDevice) {
    this.usb = usb;
  }

  static supported(): boolean {
    return typeof navigator !== "undefined" && "usb" in navigator;
  }

  /** Opens the browser's device picker (needs a user gesture). */
  static async request(): Promise<FastbootDevice> {
    const dev = await navigator.usb.requestDevice({ filters: USB_FILTERS });
    return FastbootDevice.open(dev);
  }

  /** Devices this origin was already allowed to use (no picker). */
  static async known(): Promise<USBDevice[]> {
    return (await navigator.usb.getDevices()).filter((d) => d.configurations.some((c) => c.interfaces.some((i) => i.alternates.some(isFastboot))));
  }

  static async open(dev: USBDevice): Promise<FastbootDevice> {
    const fb = new FastbootDevice(dev);
    if (!dev.opened) await dev.open();
    if (!dev.configuration) await dev.selectConfiguration(dev.configurations[0].configurationValue);
    const iface = dev.configuration!.interfaces.find((i) => i.alternates.some(isFastboot));
    if (!iface) throw new FastbootError("this USB device has no fastboot interface");
    const alt = iface.alternates.find(isFastboot)!;
    try {
      await dev.claimInterface(iface.interfaceNumber);
    } catch (e) {
      throw new FastbootError(
        "the browser could not claim the fastboot interface. Close any other fastboot program (adb/fastboot, the Bergamota app) and other tabs using the phone, then replug. " +
          `(${(e as Error).message})`,
      );
    }
    if (alt.alternateSetting !== 0) await dev.selectAlternateInterface(iface.interfaceNumber, alt.alternateSetting);
    for (const ep of alt.endpoints) {
      if (ep.type !== "bulk") continue;
      if (ep.direction === "in") {
        fb.epIn = ep.endpointNumber;
        fb.packetIn = ep.packetSize || 512;
      } else fb.epOut = ep.endpointNumber;
    }
    if (!fb.epIn || !fb.epOut) throw new FastbootError("fastboot interface without bulk endpoints");
    fb.iface = iface.interfaceNumber;
    return fb;
  }

  async close(): Promise<void> {
    try {
      await this.usb.releaseInterface(this.iface);
    } catch {
      /* already gone */
    }
    try {
      await this.usb.close();
    } catch {
      /* already gone */
    }
  }

  /** Sends one command and reads replies until OKAY / FAIL / DATA. */
  private async command(cmd: string, timeoutMs = 30_000): Promise<{ status: "OKAY" | "DATA"; value: string }> {
    if (!allowed(cmd)) throw new FastbootError(`refusing to send "${cmd}": not an allowed command`);
    if (cmd.length > 64) throw new FastbootError("command too long");
    if (this.busy) throw new FastbootError("the phone is busy with another command");
    this.busy = true;
    try {
      this.log("cmd", cmd);
      const r = await this.usb.transferOut(this.epOut, new TextEncoder().encode(cmd));
      if (r.status !== "ok") throw new FastbootError(`USB write failed (${r.status})`);
      for (;;) {
        const res = await withTimeout(this.usb.transferIn(this.epIn, Math.max(64, this.packetIn)), timeoutMs, cmd);
        if (res.status !== "ok" || !res.data) throw new FastbootError(`USB read failed (${res.status})`);
        const text = new TextDecoder().decode(res.data);
        const status = text.slice(0, 4);
        const value = text.slice(4);
        if (status === "INFO" || status === "TEXT") {
          this.log("info", value);
          continue;
        }
        if (status === "OKAY") {
          this.log("okay", value);
          return { status, value };
        }
        if (status === "DATA") {
          this.log("data", value);
          return { status, value };
        }
        if (status === "FAIL") {
          this.log("fail", value);
          throw new FastbootError(`the phone answered FAIL: ${value || "(no reason)"}`);
        }
        throw new FastbootError(`unexpected reply "${text}"`);
      }
    } finally {
      this.busy = false;
    }
  }

  /** getvar; resolves to null when the variable does not exist (FAIL). */
  async getvar(name: string): Promise<string | null> {
    try {
      return (await this.command(`getvar:${name}`, 10_000)).value.trim();
    } catch (e) {
      if (e instanceof FastbootError && /answered FAIL/.test(e.message)) return null;
      throw e;
    }
  }

  /**
   * download:<size> then streams exactly `size` bytes. Keeps two USB transfers in flight so the reads of
   * the next buffer overlap the write of the current one.
   */
  async download(size: number, data: AsyncIterable<Uint8Array>, onBytes: (n: number) => void = () => {}): Promise<void> {
    if (size <= 0 || size > 0xffffffff) throw new FastbootError(`bad download size ${size}`);
    const r = await this.command(`download:${size.toString(16).padStart(8, "0")}`);
    if (r.status !== "DATA") throw new FastbootError("the phone did not accept the download");
    const accepted = parseInt(r.value, 16);
    if (accepted !== size) throw new FastbootError(`the phone accepted ${accepted} bytes instead of ${size}`);
    this.busy = true;
    try {
      let sent = 0;
      const inflight: Promise<void>[] = [];
      for await (const buf of data) {
        if (sent + buf.length > size) throw new FastbootError("image produced more bytes than announced");
        const chunk = buf.slice(); // own copy: the producer may reuse its buffer
        inflight.push(
          this.usb.transferOut(this.epOut, chunk).then((res) => {
            if (res.status !== "ok" || res.bytesWritten !== chunk.length) throw new FastbootError(`USB write failed (${res.status})`);
            onBytes(chunk.length);
          }),
        );
        sent += chunk.length;
        if (inflight.length >= 2) await withTimeout(inflight.shift()!, 60_000, "sending data");
      }
      for (const p of inflight) await withTimeout(p, 60_000, "sending data");
      if (sent !== size) throw new FastbootError(`image produced ${sent} bytes instead of ${size}`);
    } finally {
      this.busy = false;
    }
    // the device answers OKAY once it has everything
    for (;;) {
      const res = await withTimeout(this.usb.transferIn(this.epIn, Math.max(64, this.packetIn)), 60_000, "download");
      if (res.status !== "ok" || !res.data) throw new FastbootError(`USB read failed (${res.status})`);
      const text = new TextDecoder().decode(res.data);
      if (text.startsWith("INFO") || text.startsWith("TEXT")) {
        this.log("info", text.slice(4));
        continue;
      }
      if (text.startsWith("OKAY")) {
        this.log("okay", `received ${size} bytes`);
        return;
      }
      this.log("fail", text.slice(4));
      throw new FastbootError(`download failed: ${text.slice(4) || text}`);
    }
  }

  /** flash:<partition> of what was just downloaded. Only allowlisted partitions. */
  async flash(partition: Partition): Promise<void> {
    if (!(ALLOWED_PARTITIONS as readonly string[]).includes(partition)) throw new FastbootError(`refusing to flash ${partition}`);
    await this.command(`flash:${partition}`, 10 * 60_000);
  }

  async reboot(): Promise<void> {
    await this.command("reboot", 15_000);
  }
}

function isFastboot(a: USBAlternateInterface): boolean {
  return a.interfaceClass === 0xff && a.interfaceSubclass === 0x42 && a.interfaceProtocol === 0x03;
}
