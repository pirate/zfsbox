#!/usr/bin/env bash
set -Eeuo pipefail

host_root_mount="/host"

for arg in $(cat /proc/cmdline); do
    case "${arg}" in
        zfsbox.host_root_mount=*)
            host_root_mount="${arg#zfsbox.host_root_mount=}"
            ;;
    esac
done

mkdir -p "${host_root_mount}"

if mountpoint -q "${host_root_mount}"; then
    exit 0
fi

mount -t virtiofs hostroot "${host_root_mount}" >/dev/null 2>&1 && exit 0
mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,cache=mmap,access=client hostroot "${host_root_mount}"
