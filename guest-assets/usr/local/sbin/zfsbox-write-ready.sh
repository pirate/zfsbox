#!/usr/bin/env bash
set -Eeuo pipefail

host_root_mount="/host"
state_dir=""

for arg in $(cat /proc/cmdline); do
    case "${arg}" in
        zfsbox.host_root_mount=*)
            host_root_mount="${arg#zfsbox.host_root_mount=}"
            ;;
        zfsbox.state_dir=*)
            state_dir="${arg#zfsbox.state_dir=}"
            ;;
    esac
done

[[ -n "${state_dir}" ]] || exit 0

ready_file="${host_root_mount}${state_dir}/guest-ready"
mkdir -p "$(dirname "${ready_file}")"

{
    printf 'status=ready\n'
    printf 'timestamp=%s\n' "$(date -Is)"
} > "${ready_file}"
