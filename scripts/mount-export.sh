#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/state}"
HOST_SHARE_DIR="${HOST_SHARE_DIR:-/host-share}"
VM_IP="${VM_IP:-172.16.0.2}"
SYNC_SOURCE="${STATE_DIR}/mnt/share"

mkdir -p "${HOST_SHARE_DIR}" "${SYNC_SOURCE}"

if mountpoint -q "${SYNC_SOURCE}"; then
    umount "${SYNC_SOURCE}"
fi

for _ in $(seq 1 30); do
    if mount -t nfs -o vers=4,tcp "${VM_IP}:/" "${SYNC_SOURCE}" >/dev/null 2>&1; then
        rsync -a --exclude '.zfsbox-ready' --exclude '.zfsbox-ctl' "${SYNC_SOURCE}/" "${HOST_SHARE_DIR}/"
        exit 0
    fi
    sleep 2
done

echo "Failed to mount NFS export from ${VM_IP}" >&2
exit 1
