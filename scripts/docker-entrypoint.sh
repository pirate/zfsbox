#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -eq 0 ]]; then
    set -- sleep infinity
fi

mkdir -p "${ZFSBOX_STATE_DIR:-/data/.zfsbox/state}"

if [[ "$(uname -s)" == "Linux" ]]; then
    state_root="${ZFSBOX_STATE_DIR:-/data/.zfsbox/state}"
    known_pools_file="${state_root}/linux-qemu/known-pool-paths.tsv"
    known_mounts_file="${state_root}/host-mounts.linux.txt"

    if [[ -s "${known_pools_file}" || -s "${known_mounts_file}" ]]; then
        "${PROJECT_DIR}/scripts/reconcile-host-mounts.sh"
    fi
fi

exec "$@"
