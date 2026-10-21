#!/usr/bin/env bash
set -e
IFACE=eno1
GW=192.168.1.1
SUBNET=192.168.1.0/24
SRC=192.168.1.108
TABLE=200
MARK=0x1

ip route replace "$SUBNET" dev "$IFACE" scope link src "$SRC" table "$TABLE"
ip route replace default via "$GW" dev "$IFACE" table "$TABLE"
ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip rule add fwmark "$MARK" table "$TABLE" priority 100

iptables -t mangle -F SUNSHINE_MARK 2>/dev/null || iptables -t mangle -N SUNSHINE_MARK
iptables -t mangle -D OUTPUT -j SUNSHINE_MARK 2>/dev/null || true
iptables -t mangle -A OUTPUT -j SUNSHINE_MARK
iptables -t mangle -A SUNSHINE_MARK -p tcp -m multiport --sports 47984,47989,47990,48010 -j MARK --set-mark "$MARK"
iptables -t mangle -A SUNSHINE_MARK -p udp -m multiport --sports 47998:48000,48002,48010 -j MARK --set-mark "$MARK"
