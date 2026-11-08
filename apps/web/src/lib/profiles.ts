// Renegade's target profiles (tools/renegade/targets.py): which IPSW each root is built from.
export interface Profile {
  id: "ios26" | "ios18";
  device: string;
  model: string;
  version: string;
  build: string;
}

export const PROFILES: Profile[] = [
  { id: "ios26", device: "iPhone12,1", model: "iPhone 11", version: "26.6.2", build: "23G90" },
  { id: "ios18", device: "iPhone11,8", model: "iPhone XR", version: "18.7.8", build: "22H352" },
];

/** Apple names restore IPSWs <device>_<version>_<build>_Restore.ipsw. */
export function profileForIpsw(name: string): { profile: Profile | null; device?: string; version?: string; build?: string } {
  const m = /^(iPhone\d+,\d+)_([\d.]+)_([0-9A-Za-z]+)_Restore\.ipsw$/.exec(name);
  if (!m) return { profile: null };
  const [, device, version, build] = m;
  return { profile: PROFILES.find((p) => p.device === device && p.build === build) ?? null, device, version, build };
}
