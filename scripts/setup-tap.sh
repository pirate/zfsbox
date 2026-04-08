#!/usr/bin/env bash
set -Eeuo pipefail

TAP_DEV="${TAP_DEV:-tap0}"
TAP_HOST_CIDR="${TAP_HOST_CIDR:-172.16.0.1/30}"
VM_SUBNET_CIDR="${VM_SUBNET_CIDR:-172.16.0.0/30}"
STATE_DIR="${STATE_DIR:-/state}"

HOST_IFACE="$(ip -j route show default | jq -r '.[0].dev')"

mkdir -p "${STATE_DIR}"
printf '%s\n' "${HOST_IFACE}" > "${STATE_DIR}/host_iface"

ip link del "${TAP_DEV}" 2>/dev/null || true
ip tuntap add dev "${TAP_DEV}" mode tap
ip addr add "${TAP_HOST_CIDR}" dev "${TAP_DEV}"
ip link set dev "${TAP_DEV}" up

sysctl -w net.ipv4.ip_forward=1 >/dev/null

iptables -C FORWARD -i "${TAP_DEV}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "${TAP_DEV}" -j ACCEPT
iptables -C FORWARD -o "${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o "${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s "${VM_SUBNET_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "${VM_SUBNET_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE

