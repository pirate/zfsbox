#!/usr/bin/env bash
set -Eeuo pipefail

ROOTFS_DIR="${1:?usage: build-seeded-linux-qemu-image.sh ROOTFS_DIR OUTPUT_IMAGE [OUTPUT_KERNEL] [OUTPUT_INITRD] [OUTPUT_ROOTFS_UUID]}"
OUTPUT_IMAGE="${2:?usage: build-seeded-linux-qemu-image.sh ROOTFS_DIR OUTPUT_IMAGE [OUTPUT_KERNEL] [OUTPUT_INITRD] [OUTPUT_ROOTFS_UUID]}"
OUTPUT_KERNEL="${3:-$(dirname "${OUTPUT_IMAGE}")/guest-vmlinuz}"
OUTPUT_INITRD="${4:-$(dirname "${OUTPUT_IMAGE}")/guest-initrd.img}"
OUTPUT_ROOTFS_UUID="${5:-$(dirname "${OUTPUT_IMAGE}")/guest-rootfs.uuid}"

if [[ ! -d "${ROOTFS_DIR}" ]]; then
    echo "Guest rootfs directory not found: ${ROOTFS_DIR}" >&2
    exit 1
fi

kernel_path="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort -V | tail -n 1)"
initrd_path="$(find "${ROOTFS_DIR}/boot" -maxdepth 1 -type f -name 'initrd.img-*' | sort -V | tail -n 1)"

if [[ -z "${kernel_path}" ]]; then
    echo "Guest kernel was not found under ${ROOTFS_DIR}/boot." >&2
    exit 1
fi

if [[ -z "${initrd_path}" ]]; then
    echo "Guest initrd was not found under ${ROOTFS_DIR}/boot." >&2
    exit 1
fi

mkdir -p "$(dirname "${OUTPUT_IMAGE}")"

cp "${kernel_path}" "${OUTPUT_KERNEL}"
cp "${initrd_path}" "${OUTPUT_INITRD}"

rootfs_bytes="$(du -sx -B1 "${ROOTFS_DIR}" | awk '{print $1}')"
extra_bytes=$((1024 * 1024 * 1024))
image_bytes=$((rootfs_bytes + extra_bytes))
image_bytes=$((((image_bytes + 1024 * 1024 - 1) / (1024 * 1024)) * (1024 * 1024)))

tmp_raw="$(mktemp -p "$(dirname "${OUTPUT_IMAGE}")" zfsbox-rootfs.XXXXXX.raw)"
trap 'rm -f "${tmp_raw}"' EXIT

truncate -s "${image_bytes}" "${tmp_raw}"
mkfs.ext4 -q -F -L zfsbox-root -d "${ROOTFS_DIR}" "${tmp_raw}"
tune2fs -U random "${tmp_raw}" >/dev/null
blkid -o value -s UUID "${tmp_raw}" > "${OUTPUT_ROOTFS_UUID}"

qemu-img convert -c -f raw -O qcow2 "${tmp_raw}" "${OUTPUT_IMAGE}" >/dev/null
