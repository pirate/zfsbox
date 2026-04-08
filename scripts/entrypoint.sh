#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/state}"
HOST_SHARE_DIR="${HOST_SHARE_DIR:-/host-share}"

cleanup() {
    /opt/zfsbox/scripts/teardown.sh || true
}

trap cleanup EXIT INT TERM

mkdir -p "${STATE_DIR}" "${HOST_SHARE_DIR}"

/opt/zfsbox/scripts/preflight.sh
/opt/zfsbox/scripts/setup-tap.sh
/opt/zfsbox/scripts/build-guest.sh
/opt/zfsbox/scripts/launch-firecracker.sh
/opt/zfsbox/scripts/provision-guest.sh
/opt/zfsbox/scripts/mount-export.sh
/opt/zfsbox/scripts/sync-export.sh &
printf '%s\n' "$!" > "${STATE_DIR}/sync.pid"

echo "zfsbox ready: ${HOST_SHARE_DIR}"

while kill -0 "$(cat "${STATE_DIR}/firecracker.pid")" 2>/dev/null; do
    sleep 5
done
