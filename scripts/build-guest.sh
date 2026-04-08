#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/state}"
ASSETS_DIR="${STATE_DIR}/assets"
BUILD_DIR="${STATE_DIR}/build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
MARKER_FILE="${STATE_DIR}/guest-built.marker"
GUEST_LAYOUT_VERSION="${GUEST_LAYOUT_VERSION:-2}"

FIRECRACKER_VERSION="${FIRECRACKER_VERSION:-v1.15.0}"
GUEST_RELEASE="${GUEST_RELEASE:-noble}"
ROOTFS_SIZE="${ROOTFS_SIZE:-8G}"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-20G}"
POOL_NAME="${POOL_NAME:-tank}"
SHARE_EXPORT="${SHARE_EXPORT:-/tank/share}"
VM_IP="${VM_IP:-172.16.0.2}"
VM_PREFIX="${VM_PREFIX:-30}"
VM_GW="${VM_GW:-172.16.0.1}"
VM_SUBNET_CIDR="${VM_SUBNET_CIDR:-172.16.0.0/30}"

mkdir -p "${ASSETS_DIR}" "${BUILD_DIR}"

case "$(uname -m)" in
    x86_64)
        FC_ARCH="x86_64"
        DEB_ARCH="amd64"
        DEFAULT_MIRROR="http://archive.ubuntu.com/ubuntu"
        ;;
    arm64|aarch64)
        FC_ARCH="aarch64"
        DEB_ARCH="arm64"
        DEFAULT_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
        ;;
    *)
        echo "Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

UBUNTU_MIRROR="${UBUNTU_MIRROR:-${DEFAULT_MIRROR}}"

download_firecracker() {
    if [[ -x "${ASSETS_DIR}/firecracker" ]]; then
        return
    fi

    archive="${ASSETS_DIR}/firecracker-${FIRECRACKER_VERSION}-${FC_ARCH}.tgz"
    url="https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-${FC_ARCH}.tgz"

    wget -O "${archive}" "${url}"
    tar -xzf "${archive}" -C "${ASSETS_DIR}"
    cp "${ASSETS_DIR}/release-${FIRECRACKER_VERSION}-${FC_ARCH}/firecracker-${FIRECRACKER_VERSION}-${FC_ARCH}" "${ASSETS_DIR}/firecracker"
    chmod +x "${ASSETS_DIR}/firecracker"
}

download_extract_vmlinux() {
    if [[ -x "${BUILD_DIR}/extract-vmlinux" ]]; then
        return
    fi

    wget -O "${BUILD_DIR}/extract-vmlinux" "https://raw.githubusercontent.com/torvalds/linux/master/scripts/extract-vmlinux"
    chmod +x "${BUILD_DIR}/extract-vmlinux"
}

mount_chroot_fs() {
    mkdir -p "${ROOTFS_DIR}/dev/pts" "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys"
    mount --bind /dev "${ROOTFS_DIR}/dev"
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    mount -t proc proc "${ROOTFS_DIR}/proc"
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
}

umount_chroot_fs() {
    umount -lf "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount -lf "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount -lf "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount -lf "${ROOTFS_DIR}/dev" 2>/dev/null || true
}

trap umount_chroot_fs EXIT

write_guest_files() {
    cat > "${ROOTFS_DIR}/etc/hostname" <<'EOF'
zfsbox
EOF

    cat > "${ROOTFS_DIR}/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 zfsbox
EOF

    cat > "${ROOTFS_DIR}/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    install -d -m 0755 "${ROOTFS_DIR}/etc/systemd/network"
    cat > "${ROOTFS_DIR}/etc/systemd/network/20-eth0.network" <<EOF
[Match]
Name=eth0

[Network]
Address=${VM_IP}/${VM_PREFIX}
Gateway=${VM_GW}
DNS=1.1.1.1
DNS=8.8.8.8
EOF

    cat > "${ROOTFS_DIR}/etc/default/zfsbox" <<EOF
POOL_NAME=${POOL_NAME}
POOL_DEVICE=/dev/vdb
DATASET_NAME=${POOL_NAME}/share
SHARE_EXPORT=${SHARE_EXPORT}
EOF

    install -d -m 0755 "${ROOTFS_DIR}/usr/local/sbin"
    cat > "${ROOTFS_DIR}/usr/local/sbin/zfsbox-init-share.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/default/zfsbox

if ! zpool list -H "${POOL_NAME}" >/dev/null 2>&1; then
    if ! zpool import -f "${POOL_NAME}" >/dev/null 2>&1; then
        zpool create -f -o ashift=12 -O atime=off -O compression=zstd -O mountpoint=none "${POOL_NAME}" "${POOL_DEVICE}"
    fi
fi

if ! zfs list -H "${DATASET_NAME}" >/dev/null 2>&1; then
    zfs create -o mountpoint="${SHARE_EXPORT}" "${DATASET_NAME}"
fi

mkdir -p "${SHARE_EXPORT}"
chmod 0777 "${SHARE_EXPORT}"
exportfs -ra
systemctl restart nfs-server.service
EOF
    chmod +x "${ROOTFS_DIR}/usr/local/sbin/zfsbox-init-share.sh"

    cat > "${ROOTFS_DIR}/usr/local/sbin/zfsbox-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/default/zfsbox

CTL_DIR="${SHARE_EXPORT}/.zfsbox-ctl"
REQUESTS_DIR="${CTL_DIR}/requests"
RESPONSES_DIR="${CTL_DIR}/responses"

mkdir -p "${REQUESTS_DIR}" "${RESPONSES_DIR}"
date -Is > "${CTL_DIR}/agent.ready"

while true; do
    shopt -s nullglob

    for request_dir in "${REQUESTS_DIR}"/*; do
        [[ -d "${request_dir}" ]] || continue

        request_id="$(basename "${request_dir}")"
        argv_dir="${request_dir}/argv"
        response_dir="${RESPONSES_DIR}/${request_id}"

        if [[ ! -d "${argv_dir}" || -e "${response_dir}/done" ]]; then
            continue
        fi

        mkdir -p "${response_dir}"

        argv=()
        while IFS= read -r -d '' arg_file; do
            argv+=("$(cat "${arg_file}")")
        done < <(find "${argv_dir}" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)

        if [[ "${#argv[@]}" -eq 0 ]]; then
            printf '%s\n' "Empty request" > "${response_dir}/stderr"
            : > "${response_dir}/stdout"
            printf '%s\n' "64" > "${response_dir}/exit_code"
            touch "${response_dir}/done"
            rm -rf "${request_dir}"
            continue
        fi

        if "${argv[@]}" > "${response_dir}/stdout" 2> "${response_dir}/stderr"; then
            exit_code=0
        else
            exit_code=$?
        fi

        printf '%s\n' "${exit_code}" > "${response_dir}/exit_code"
        touch "${response_dir}/done"
        rm -rf "${request_dir}"
    done

    sleep 1
done
EOF
    chmod +x "${ROOTFS_DIR}/usr/local/sbin/zfsbox-agent.sh"

    install -d -m 0755 "${ROOTFS_DIR}/etc/exports.d"
    cat > "${ROOTFS_DIR}/etc/exports.d/zfsbox.exports" <<EOF
${SHARE_EXPORT} ${VM_SUBNET_CIDR}(rw,sync,no_subtree_check,no_root_squash,fsid=0)
EOF

    install -d -m 0755 "${ROOTFS_DIR}/etc/systemd/system"
    cat > "${ROOTFS_DIR}/etc/systemd/system/zfsbox-share.service" <<'EOF'
[Unit]
Description=Prepare the ZFS share disk and export it over NFS
After=network-online.target zfs-import.target zfs-mount.service
Wants=network-online.target
Before=nfs-server.service

[Service]
Type=oneshot
EnvironmentFile=/etc/default/zfsbox
ExecStart=/usr/local/sbin/zfsbox-init-share.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat > "${ROOTFS_DIR}/etc/systemd/system/zfsbox-agent.service" <<'EOF'
[Unit]
Description=Execute host-submitted commands inside the ZFS microVM
After=zfsbox-share.service
Requires=zfsbox-share.service

[Service]
Type=simple
EnvironmentFile=/etc/default/zfsbox
ExecStart=/usr/local/sbin/zfsbox-agent.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

    cat > "${ROOTFS_DIR}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod +x "${ROOTFS_DIR}/usr/sbin/policy-rc.d"
}

build_guest_rootfs() {
    rm -rf "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}"

    debootstrap --arch="${DEB_ARCH}" --variant=minbase "${GUEST_RELEASE}" "${ROOTFS_DIR}" "${UBUNTU_MIRROR}"

    mount_chroot_fs

    write_guest_files

    chroot "${ROOTFS_DIR}" apt-get update
    chroot "${ROOTFS_DIR}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        initramfs-tools \
        iproute2 \
        linux-image-generic \
        nfs-kernel-server \
        rpcbind \
        systemd-sysv \
        zfs-initramfs \
        zfsutils-linux

    rm -f "${ROOTFS_DIR}/usr/sbin/policy-rc.d"

    chroot "${ROOTFS_DIR}" systemctl enable serial-getty@ttyS0.service
    chroot "${ROOTFS_DIR}" systemctl enable systemd-networkd.service
    chroot "${ROOTFS_DIR}" systemctl enable rpcbind.service
    chroot "${ROOTFS_DIR}" systemctl enable nfs-server.service
    chroot "${ROOTFS_DIR}" systemctl enable zfs.target
    chroot "${ROOTFS_DIR}" systemctl enable zfs-import-scan.service
    chroot "${ROOTFS_DIR}" systemctl enable zfs-import-cache.service
    chroot "${ROOTFS_DIR}" systemctl enable zfs-mount.service
    chroot "${ROOTFS_DIR}" systemctl enable zfsbox-share.service
    chroot "${ROOTFS_DIR}" systemctl enable zfsbox-agent.service
    chroot "${ROOTFS_DIR}" update-initramfs -c -k all

    umount_chroot_fs

    kernel_source="$(ls "${ROOTFS_DIR}"/boot/vmlinuz-* | sort -V | tail -n 1)"
    initrd_source="$(ls "${ROOTFS_DIR}"/boot/initrd.img-* | sort -V | tail -n 1)"

    "${BUILD_DIR}/extract-vmlinux" "${kernel_source}" > "${ASSETS_DIR}/vmlinux"
    cp "${initrd_source}" "${ASSETS_DIR}/initrd.img"

    truncate -s "${ROOTFS_SIZE}" "${ASSETS_DIR}/rootfs.ext4"
    mkfs.ext4 -F -d "${ROOTFS_DIR}" "${ASSETS_DIR}/rootfs.ext4"

    truncate -s "${DATA_DISK_SIZE}" "${ASSETS_DIR}/zpool.raw"

    cat > "${MARKER_FILE}" <<EOF
GUEST_LAYOUT_VERSION=${GUEST_LAYOUT_VERSION}
FIRECRACKER_VERSION=${FIRECRACKER_VERSION}
GUEST_RELEASE=${GUEST_RELEASE}
ROOTFS_SIZE=${ROOTFS_SIZE}
DATA_DISK_SIZE=${DATA_DISK_SIZE}
POOL_NAME=${POOL_NAME}
SHARE_EXPORT=${SHARE_EXPORT}
VM_SUBNET_CIDR=${VM_SUBNET_CIDR}
KERNEL=${kernel_source##*/}
EOF
}

download_firecracker
download_extract_vmlinux

EXPECTED_MARKER="$(cat <<EOF
GUEST_LAYOUT_VERSION=${GUEST_LAYOUT_VERSION}
FIRECRACKER_VERSION=${FIRECRACKER_VERSION}
GUEST_RELEASE=${GUEST_RELEASE}
ROOTFS_SIZE=${ROOTFS_SIZE}
DATA_DISK_SIZE=${DATA_DISK_SIZE}
POOL_NAME=${POOL_NAME}
SHARE_EXPORT=${SHARE_EXPORT}
VM_SUBNET_CIDR=${VM_SUBNET_CIDR}
EOF
)"

CURRENT_MARKER="$(grep -E '^(GUEST_LAYOUT_VERSION|FIRECRACKER_VERSION|GUEST_RELEASE|ROOTFS_SIZE|DATA_DISK_SIZE|POOL_NAME|SHARE_EXPORT|VM_SUBNET_CIDR)=' "${MARKER_FILE}" 2>/dev/null || true)"

if [[ ! -f "${MARKER_FILE}" || ! -f "${ASSETS_DIR}/rootfs.ext4" || ! -f "${ASSETS_DIR}/initrd.img" || ! -f "${ASSETS_DIR}/vmlinux" || ! -f "${ASSETS_DIR}/zpool.raw" || "${CURRENT_MARKER}" != "${EXPECTED_MARKER}" ]]; then
    build_guest_rootfs
fi
