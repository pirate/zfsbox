#!/usr/bin/env bash
set -Eeuo pipefail

host_root_mount="/host"
state_dir=""
pubkey_file=""

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

if [[ -n "${state_dir}" ]]; then
    pubkey_file="${host_root_mount}${state_dir}/id_ed25519.pub"
fi

mkdir -p /root/.ssh
chmod 0700 /root/.ssh

for _ in $(seq 1 60); do
    [[ -n "${pubkey_file}" && -s "${pubkey_file}" ]] && break
    sleep 1
done

if [[ -n "${pubkey_file}" && -s "${pubkey_file}" ]]; then
    cp "${pubkey_file}" /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
fi

modprobe zfs >/dev/null 2>&1 || true
