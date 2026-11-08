#!/bin/sh
# Share the Mac's internet with the phone's USB Ethernet (phone 192.168.7.2,
# Mac 192.168.7.1). Temporary: IP forwarding and the pf rule reset on reboot;
# `tools/sweet-mac-nat.sh off` removes them now. Needs sudo.
#   tools/sweet-mac-nat.sh [on|off] [uplink interface, default: the default route's]
set -eu
mode=${1:-on}
up=${2:-$(route -n get default | awk '/interface:/{print $2}')}
if [ "$mode" = off ]; then
	sudo pfctl -a com.apple/sweet-usbnet -F nat
	sudo sysctl -w net.inet.ip.forwarding=0
	exit 0
fi
echo "uplink: $up"
sudo sysctl -w net.inet.ip.forwarding=1
echo "nat on $up inet from 192.168.7.0/24 to any -> ($up)" | sudo pfctl -a com.apple/sweet-usbnet -f -
sudo pfctl -E 2>&1 | grep -v "^$" || true
sudo pfctl -a com.apple/sweet-usbnet -s nat
