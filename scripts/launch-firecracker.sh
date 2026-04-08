#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/state}"
ASSETS_DIR="${STATE_DIR}/assets"
API_SOCK="${STATE_DIR}/firecracker.socket"
CONFIG_PATH="${STATE_DIR}/firecracker.vm.json"
LOG_PATH="${STATE_DIR}/firecracker.log"
PID_PATH="${STATE_DIR}/firecracker.pid"

TAP_DEV="${TAP_DEV:-tap0}"
VM_MEMORY_MB="${VM_MEMORY_MB:-2048}"
VM_VCPUS="${VM_VCPUS:-2}"

rm -f "${API_SOCK}" "${PID_PATH}"

cat > "${CONFIG_PATH}" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${ASSETS_DIR}/vmlinux",
    "initrd_path": "${ASSETS_DIR}/initrd.img",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/init net.ifnames=0"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "${ASSETS_DIR}/rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false
    },
    {
      "drive_id": "zpool",
      "path_on_host": "${ASSETS_DIR}/zpool.raw",
      "is_root_device": false,
      "is_read_only": false
    }
  ],
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "guest_mac": "02:FC:00:00:00:01",
      "host_dev_name": "${TAP_DEV}"
    }
  ],
  "machine-config": {
    "vcpu_count": ${VM_VCPUS},
    "mem_size_mib": ${VM_MEMORY_MB},
    "ht_enabled": false
  }
}
EOF

"${ASSETS_DIR}/firecracker" --api-sock "${API_SOCK}" --config-file "${CONFIG_PATH}" >"${LOG_PATH}" 2>&1 &
printf '%s\n' "$!" > "${PID_PATH}"

