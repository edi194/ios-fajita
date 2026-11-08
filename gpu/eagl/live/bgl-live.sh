#!/bin/bash
# SPDX-License-Identifier: MIT
# Live (no reboot) test of backboardd on the Bergamota GL renderer, over SSH. See docs/GPU_EAGL.md ("Live backboardd test").
#   bgl-live.sh install    payload -> /usr/local/lib/bergamota-gl (sha256-verified), /usr/libexec/backboardd.real = copy of the original
#                          (hash checked), launcher installed AS /usr/libexec/backboardd (atomic rename), revert.sh written. Nothing is
#                          restarted and the launcher is inert without the marker: backboardd keeps running as before.
#   bgl-live.sh arm        start the dead-man (sleep 180; revert.sh) detached on the phone
#   bgl-live.sh mode soft|1|off [debug]  write/remove the marker /private/var/run/bglrender: "MODE BOOT-SESSION-UUID [debug]" (soft = softpipe,
#                          1 = GPU if available). The launcher honours it only when the uuid is the CURRENT boot's kern.bootsessionuuid.
#   bgl-live.sh respring   kill -9 backboardd (launchd restarts it through the launcher; SpringBoard restarts with it)
#   bgl-live.sh disarm     kill the dead-man (the experiment is judged good)
#   bgl-live.sh revert     run revert.sh now (original backboardd back, marker removed, backboardd restarted)
# Env: PAYLOAD (default research/bergamota-gl), LAUNCHER (the -DBGL_REAL_PATH build; default $GPU_EAGL_WORK/payload-build/bgl-launch-live).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PAYLOAD="${PAYLOAD:-$REPO/research/bergamota-gl}"
O=(-o BatchMode=yes -o ConnectTimeout=10 -o UserKnownHostsFile="${KNOWN_HOSTS:-$HOME/.ssh/known_hosts_ios18}")
HOST="${PHONE:-root@192.168.7.2}"
ph() { ssh "${O[@]}" "$HOST" "export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin; $*"; }
put() { scp -O "${O[@]}" "$@"; }
D=/usr/local/lib/bergamota-gl
case "${1:-}" in
install)
  LAUNCHER="${LAUNCHER:-$GPU_EAGL_WORK/payload-build/bgl-launch-live}"
  T="$(mktemp -d)"; cp "$LAUNCHER" "$T/bgl-launch-live"; python3 -I "$REPO/tools/renegade/pacstrip.py" --sign "$T/bgl-launch-live" >/dev/null
  cat > "$T/revert.sh" <<'EOT'
#!/bin/sh
# Bergamota GL renderer: undo the live test. Safe to run any number of times.
rm -f /private/var/run/bglrender
if [ -f /usr/libexec/backboardd.real ]; then
  mv -f /usr/libexec/backboardd.real /usr/libexec/backboardd
fi
for p in $(ps ax | grep '/usr/libexec/backboardd' | grep -v grep | cut -c1-6); do kill -9 $p; done
EOT
  ph "mkdir -p $D/OpenGLES.framework /var/root/bgl-in; rm -rf /var/root/bgl-in/*"
  put "$PAYLOAD/libOSMesa.8.dylib" "$PAYLOAD/libdrm.2.dylib" "$T/bgl-launch-live" "$T/revert.sh" "$HOST:/var/root/bgl-in/"
  put "$PAYLOAD/OpenGLES.framework/OpenGLES" "$HOST:/var/root/bgl-in/OpenGLES"
  (cd "$T" && shasum -a 256 bgl-launch-live revert.sh | cut -c1-64; cd "$PAYLOAD" && shasum -a 256 libOSMesa.8.dylib libdrm.2.dylib OpenGLES.framework/OpenGLES | cut -c1-64) > "$T/sha.local"
  ph "cd /var/root/bgl-in && sha256sum bgl-launch-live revert.sh libOSMesa.8.dylib libdrm.2.dylib OpenGLES | cut -c1-64" > "$T/sha.phone"
  cmp "$T/sha.local" "$T/sha.phone" || { echo "sha256 mismatch: abort"; exit 1; }
  echo "payload staged and verified"
  ph "set -e; cd /var/root/bgl-in
      for f in libOSMesa.8.dylib libdrm.2.dylib; do rm -f $D/\$f; cp \$f $D/\$f; chmod 755 $D/\$f; done
      rm -f $D/OpenGLES.framework/OpenGLES; cp OpenGLES $D/OpenGLES.framework/OpenGLES; chmod 755 $D/OpenGLES.framework/OpenGLES
      rm -f $D/revert.sh; cp revert.sh $D/revert.sh; chmod 755 $D/revert.sh
      rm -f $D/bgl-launch; cp bgl-launch-live $D/bgl-launch; chmod 755 $D/bgl-launch
      if [ ! -f /usr/libexec/backboardd.real ]; then
        cp /usr/libexec/backboardd /usr/libexec/backboardd.real.tmp; chmod 755 /usr/libexec/backboardd.real.tmp
        [ \"\$(sha256sum /usr/libexec/backboardd | cut -c1-64)\" = \"\$(sha256sum /usr/libexec/backboardd.real.tmp | cut -c1-64)\" ]
        mv /usr/libexec/backboardd.real.tmp /usr/libexec/backboardd.real
      fi
      cp bgl-launch-live /usr/libexec/backboardd.new; chmod 755 /usr/libexec/backboardd.new; mv -f /usr/libexec/backboardd.new /usr/libexec/backboardd
      rm -rf /var/root/bgl-in; ls -l /usr/libexec/backboardd /usr/libexec/backboardd.real $D"
  ;;
arm)     ph "setsid nohup sh -c 'sleep 180; $D/revert.sh' > /dev/null 2>&1 < /dev/null & echo dead-man armed" ;;
mode)    case "${2:-}" in soft|1) ph "echo \"$2 \$($D/bgl-launch --bgl-print-boot-uuid) ${3:-}\" > /private/var/run/bglrender; cat /private/var/run/bglrender";; off) ph "rm -f /private/var/run/bglrender; echo marker removed";; *) echo "mode soft|1|off"; exit 1;; esac ;;
respring) ph "echo \"\$($D/bgl-launch --bgl-print-boot-uuid) 0 0\" > /private/var/tmp/bgl-render.state; for p in \$(ps ax | grep '/usr/libexec/backboardd' | grep -v grep | cut -c1-6); do kill -9 \$p; done; echo killed backboardd" ;;
disarm)  ph "for p in \$(ps ax | grep 'sleep 180' | grep -v grep | cut -c1-6); do kill \$p; done; echo dead-man cancelled" ;;
revert)  ph "$D/revert.sh; echo reverted" ;;
*) sed -n 3,16p "$0"; exit 1 ;;
esac
