#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/state}"
HOST_SHARE_DIR="${HOST_SHARE_DIR:-/host-share}"
SYNC_SOURCE="${STATE_DIR}/mnt/share"

mkdir -p "${HOST_SHARE_DIR}" "${SYNC_SOURCE}"

while true; do
    rsync -a --delete --exclude '.zfsbox-ready' --exclude '.zfsbox-ctl' "${HOST_SHARE_DIR}/" "${SYNC_SOURCE}/"
    rsync -a --delete --exclude '.zfsbox-ready' --exclude '.zfsbox-ctl' "${SYNC_SOURCE}/" "${HOST_SHARE_DIR}/"
    sleep 2
done
