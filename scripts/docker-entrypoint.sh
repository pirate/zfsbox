#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -eq 0 ]]; then
    set -- sleep infinity
fi

mkdir -p "${ZFSBOX_STATE_DIR:-/data/.zfsbox/state}"

if [[ "$(uname -s)" == "Linux" ]]; then
    "${PROJECT_DIR}/scripts/reconcile-host-mounts.sh"
fi

exec "$@"
