#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/state}"
HOST_SHARE_DIR="${HOST_SHARE_DIR:-/host-share}"
TAP_DEV="${TAP_DEV:-tap0}"
VM_SUBNET_CIDR="${VM_SUBNET_CIDR:-172.16.0.0/30}"

if [[ -f "${STATE_DIR}/sync.pid" ]]; then
    sync_pid="$(cat "${STATE_DIR}/sync.pid")"
    kill "${sync_pid}" 2>/dev/null || true
fi

if mountpoint -q "${STATE_DIR}/mnt/share"; then
    umount "${STATE_DIR}/mnt/share" || true
fi

if [[ -f "${STATE_DIR}/firecracker.pid" ]]; then
    pid="$(cat "${STATE_DIR}/firecracker.pid")"
    kill "${pid}" 2>/dev/null || true
fi

if [[ -f "${STATE_DIR}/host_iface" ]]; then
    host_iface="$(cat "${STATE_DIR}/host_iface")"
    iptables -t nat -D POSTROUTING -s "${VM_SUBNET_CIDR}" -o "${host_iface}" -j MASQUERADE 2>/dev/null || true
fi

iptables -D FORWARD -i "${TAP_DEV}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o "${TAP_DEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
ip link del "${TAP_DEV}" 2>/dev/null || true
