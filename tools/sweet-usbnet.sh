#!/bin/sh
# Host side of the phone's USB Ethernet (kernel sweetusb=2, patches 0075-0077).
#   tools/sweet-usbnet.sh [LOGFILE]
# Waits for the phone's CDC-ECM interface (host MAC 02:00:5e:77:ee:01),
# gives it 192.168.7.1/24 (the phone is 192.168.7.2), then prints the live
# kernel console the phone streams to UDP port 5140 (and appends it to
# LOGFILE if given). Needs sudo for the address.
set -eu

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	echo "Usage: $(basename "$0") [LOGFILE]"
	echo "Wait for the phone's USB Ethernet interface and stream the live kernel UDP console."
	exit 0
fi

mac=02:00:5e:77:ee:01
echo "waiting for the phone's USB Ethernet ($mac)..." >&2
if [ "$(uname)" = Darwin ]; then
	# macOS: the CDC-ECM driver names it enN; ifconfig lists the host-side MAC as "ether"
	ifname=
	until [ -n "$ifname" ]; do
		ifname=$(ifconfig -a | awk -v m="$mac" '/^[a-z]/{i=$1} $1=="ether" && tolower($2)==m {sub(":","",i); print i}')
		[ -n "$ifname" ] || sleep 1
	done
	sudo ifconfig "$ifname" inet 192.168.7.1 netmask 255.255.255.0 up
else
	until ip -o link | grep -qi "$mac"; do sleep 1; done
	ifname=$(ip -o link | grep -i "$mac" | awk -F': ' '{print $2}' | cut -d@ -f1)
	nmcli dev set "$ifname" managed no 2>/dev/null || true
	sudo ip addr replace 192.168.7.1/24 dev "$ifname"
	sudo ip link set "$ifname" up
fi
echo "$ifname up: 192.168.7.1 <-> phone 192.168.7.2; live log on udp/5140" >&2

listen_udp() {
	port=5140
	if command -v python3 >/dev/null 2>&1; then
		python3 -uc 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("",5140))
while True: sys.stdout.buffer.write(s.recv(65536)); sys.stdout.flush()'
	elif command -v socat >/dev/null 2>&1; then
		socat -u "udp-recv:$port,reuseaddr" -
	elif command -v ncat >/dev/null 2>&1; then
		ncat -l -u -k "$port"
	elif nc -h 2>&1 | grep -q -- '-k'; then
		nc -ukl "$port"
	else
		while true; do
			nc -u -l -p "$port" 2>/dev/null || nc -u -l "$port" 2>/dev/null || break
		done
	fi
}

if [ $# -ge 1 ]; then
	listen_udp | tee -a "$1"
else
	listen_udp
fi
