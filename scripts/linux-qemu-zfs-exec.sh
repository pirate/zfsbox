#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/linux-qemu-common.sh"

if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") <command> [args...]" >&2
    exit 1
fi

translated_args=("${1}")
shift

for arg in "$@"; do
    case "${arg}" in
        /*)
            if [[ -e "${arg}" ]]; then
                translated_args+=("${LINUX_QEMU_HOST_ROOT_MOUNT}${arg}")
            else
                translated_args+=("${arg}")
            fi
            ;;
        *)
            translated_args+=("${arg}")
            ;;
    esac
done

linux_qemu_guest_exec "${translated_args[@]}"
