#!/usr/bin/env bash

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
ZFSBOX_STATE_DIR="${ZFSBOX_STATE_DIR:-${PROJECT_DIR}/state}"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

LINUX_QEMU_STATE_DIR="${ZFSBOX_STATE_DIR}/linux-qemu"
LINUX_QEMU_ASSETS_DIR="${LINUX_QEMU_STATE_DIR}/assets"
LINUX_QEMU_CLOUD_DIR="${LINUX_QEMU_STATE_DIR}/cloud"
LINUX_QEMU_PID_FILE="${LINUX_QEMU_STATE_DIR}/qemu.pid"
LINUX_QEMU_SERIAL_LOG="${LINUX_QEMU_STATE_DIR}/serial.log"
LINUX_QEMU_READY_FILE="${LINUX_QEMU_STATE_DIR}/guest-ready"
LINUX_QEMU_GUEST_BOOTSTRAP_MARKER_FILE="${LINUX_QEMU_STATE_DIR}/guest-bootstrap.pid"
LINUX_QEMU_KNOWN_HOSTS="${LINUX_QEMU_STATE_DIR}/known_hosts"
LINUX_QEMU_HOST_KEY="${LINUX_QEMU_STATE_DIR}/id_ed25519"
LINUX_QEMU_HOST_KEY_PUB="${LINUX_QEMU_HOST_KEY}.pub"
LINUX_QEMU_KNOWN_POOL_PATHS_FILE="${LINUX_QEMU_STATE_DIR}/known-pool-paths.tsv"
LINUX_QEMU_ATTACHED_FILES_FILE="${LINUX_QEMU_STATE_DIR}/attached-files.txt"
LINUX_QEMU_BASE_IMAGE="${LINUX_QEMU_ASSETS_DIR}/ubuntu-cloudimg.qcow2"
LINUX_QEMU_SEEDED_BUNDLED_BASE_IMAGE="${PROJECT_DIR}/image-assets/ubuntu-seeded.qcow2"
if [[ -z "${LINUX_QEMU_BUNDLED_BASE_IMAGE:-}" ]]; then
    if [[ -f "${LINUX_QEMU_SEEDED_BUNDLED_BASE_IMAGE}" ]]; then
        LINUX_QEMU_BUNDLED_BASE_IMAGE="${LINUX_QEMU_SEEDED_BUNDLED_BASE_IMAGE}"
    else
        LINUX_QEMU_BUNDLED_BASE_IMAGE="${PROJECT_DIR}/image-assets/ubuntu-cloudimg.qcow2"
    fi
fi
LINUX_QEMU_BASE_IMAGE_KIND="${LINUX_QEMU_BASE_IMAGE_KIND:-generic}"
LINUX_QEMU_BASE_IMAGE_MARKER_FILE="${LINUX_QEMU_ASSETS_DIR}/base-image.marker"
LINUX_QEMU_BUNDLED_KERNEL_IMAGE="${LINUX_QEMU_BUNDLED_KERNEL_IMAGE:-${PROJECT_DIR}/image-assets/guest-vmlinuz}"
LINUX_QEMU_BUNDLED_INITRD_IMAGE="${LINUX_QEMU_BUNDLED_INITRD_IMAGE:-${PROJECT_DIR}/image-assets/guest-initrd.img}"
LINUX_QEMU_BUNDLED_ROOTFS_UUID_FILE="${LINUX_QEMU_BUNDLED_ROOTFS_UUID_FILE:-${PROJECT_DIR}/image-assets/guest-rootfs.uuid}"
LINUX_QEMU_ARM64_EFI_CODE_IMAGE="${LINUX_QEMU_ASSETS_DIR}/arm64-efi-code.img"
LINUX_QEMU_ARM64_EFI_VARS_IMAGE="${LINUX_QEMU_ASSETS_DIR}/arm64-efi-vars.img"
LINUX_QEMU_OVERLAY_IMAGE="${LINUX_QEMU_ASSETS_DIR}/rootfs-overlay.qcow2"
LINUX_QEMU_SEED_IMAGE="${LINUX_QEMU_ASSETS_DIR}/seed.img"
LINUX_QEMU_USER_DATA="${LINUX_QEMU_CLOUD_DIR}/user-data"
LINUX_QEMU_META_DATA="${LINUX_QEMU_CLOUD_DIR}/meta-data"
LINUX_QEMU_MARKER_FILE="${LINUX_QEMU_STATE_DIR}/instance.marker"
LINUX_QEMU_LAYOUT_VERSION="${LINUX_QEMU_LAYOUT_VERSION:-2}"
LINUX_QEMU_VM_NAME="${LINUX_QEMU_VM_NAME:-zfsbox-linux}"
LINUX_QEMU_HOST_SHARE="${LINUX_QEMU_HOST_SHARE:-/}"
LINUX_QEMU_HOST_ROOT_MOUNT="${LINUX_QEMU_HOST_ROOT_MOUNT:-/host}"
VM_SSH_PORT="${VM_SSH_PORT:-12022}"
VM_NFS_PORT="${VM_NFS_PORT:-12049}"
VM_MEMORY_MB="${VM_MEMORY_MB:-2048}"
VM_VCPUS="${VM_VCPUS:-2}"
GUEST_RELEASE="${GUEST_RELEASE:-noble}"
LINUX_QEMU_GUEST_HOST="${LINUX_QEMU_GUEST_HOST:-127.0.0.1}"
LINUX_QEMU_ATTACH_ROOT="${LINUX_QEMU_ATTACH_ROOT:-/data}"

linux_qemu_collect_attached_files() {
    local root="${LINUX_QEMU_ATTACH_ROOT}"

    [[ -d "${root}" ]] || return 0

    find "${root}" -mindepth 1 -maxdepth 1 -type f ! -path "${root}/.zfsbox/*" -print 2>/dev/null | sort
}

linux_qemu_prepare_attached_file() {
    local path="$1"

    [[ -f "${path}" ]] || return 0

    if sfdisk -d "${path}" >/dev/null 2>&1; then
        return 0
    fi

    printf 'label: gpt\n,;\n' | sfdisk --quiet "${path}" >/dev/null 2>&1
}

linux_qemu_write_attached_files_manifest() {
    local path

    linux_qemu_init_dirs
    : > "${LINUX_QEMU_ATTACHED_FILES_FILE}"
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        linux_qemu_prepare_attached_file "${path}"
        printf '%s\n' "${path}" >> "${LINUX_QEMU_ATTACHED_FILES_FILE}"
    done < <(linux_qemu_collect_attached_files)
}

linux_qemu_attached_files_signature() {
    if [[ -f "${LINUX_QEMU_ATTACHED_FILES_FILE}" ]]; then
        tr '\n' '|' < "${LINUX_QEMU_ATTACHED_FILES_FILE}"
    fi
}

linux_qemu_guest_device_for_host_path() {
    local host_path="$1"
    local index=0
    local path
    local letter

    if [[ ! -f "${LINUX_QEMU_ATTACHED_FILES_FILE}" ]]; then
        linux_qemu_write_attached_files_manifest
    fi

    [[ -f "${LINUX_QEMU_ATTACHED_FILES_FILE}" ]] || return 1

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        if [[ "${path}" == "${host_path}" ]]; then
            printf '/dev/zfsbox/zfsbox-data-%d-part1\n' "${index}"
            return 0
        fi
        index=$((index + 1))
    done < "${LINUX_QEMU_ATTACHED_FILES_FILE}"

    return 1
}

linux_qemu_log() {
    printf 'zfsbox: %s\n' "$*" >&2
}

linux_qemu_inside_container() {
    [[ -f /.dockerenv ]]
}

linux_qemu_ssh_run() {
    local timeout_seconds="${LINUX_QEMU_SSH_TIMEOUT_SECONDS:-}"

    if [[ -n "${timeout_seconds}" && "${timeout_seconds}" != "0" ]] && command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_seconds}" ssh "$@"
        return
    fi

    ssh "$@"
}

linux_qemu_require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        echo "This backend only runs on Linux." >&2
        exit 1
    fi
}

linux_qemu_detect_arch() {
    case "$(uname -m)" in
        x86_64)
            LINUX_QEMU_QEMU_BIN="${LINUX_QEMU_QEMU_BIN:-qemu-system-x86_64}"
            LINUX_QEMU_ARCH="amd64"
            LINUX_QEMU_MACHINE="q35"
            LINUX_QEMU_CPU="max"
            ;;
        aarch64|arm64)
            LINUX_QEMU_QEMU_BIN="${LINUX_QEMU_QEMU_BIN:-qemu-system-aarch64}"
            LINUX_QEMU_ARCH="arm64"
            LINUX_QEMU_MACHINE="virt"
            LINUX_QEMU_CPU="max"
            LINUX_QEMU_ARM64_UEFI_FD="${LINUX_QEMU_ARM64_UEFI_FD:-/usr/share/qemu-efi-aarch64/QEMU_EFI.fd}"
            ;;
        *)
            echo "Unsupported Linux architecture for the rootless QEMU backend: $(uname -m)" >&2
            exit 1
            ;;
    esac
}

linux_qemu_require_cmd() {
    local name="$1"
    if ! command -v "${name}" >/dev/null 2>&1; then
        echo "Required command not found: ${name}" >&2
        exit 1
    fi
}

linux_qemu_find_seed_builder() {
    if command -v cloud-localds >/dev/null 2>&1; then
        LINUX_QEMU_SEED_BUILDER="cloud-localds"
        return
    fi

    if command -v genisoimage >/dev/null 2>&1; then
        LINUX_QEMU_SEED_BUILDER="genisoimage"
        return
    fi

    if command -v mkisofs >/dev/null 2>&1; then
        LINUX_QEMU_SEED_BUILDER="mkisofs"
        return
    fi

    if command -v xorriso >/dev/null 2>&1; then
        LINUX_QEMU_SEED_BUILDER="xorriso"
        return
    fi

    echo "Need one of: cloud-localds, genisoimage, mkisofs, or xorriso." >&2
    exit 1
}

linux_qemu_require_dependencies() {
    linux_qemu_detect_arch
    linux_qemu_require_cmd curl
    linux_qemu_require_cmd "${LINUX_QEMU_QEMU_BIN}"
    linux_qemu_require_cmd qemu-img
    linux_qemu_require_cmd ssh
    linux_qemu_require_cmd ssh-keygen
}

linux_qemu_init_dirs() {
    mkdir -p "${LINUX_QEMU_STATE_DIR}" "${LINUX_QEMU_ASSETS_DIR}" "${LINUX_QEMU_CLOUD_DIR}"
}

linux_qemu_classify_base_image() {
    local image_path="$1"

    case "${image_path}" in
        *ubuntu-seeded.qcow2|*seeded*.qcow2)
            LINUX_QEMU_BASE_IMAGE_KIND="seeded"
            ;;
        *)
            LINUX_QEMU_BASE_IMAGE_KIND="generic"
            ;;
    esac
}

linux_qemu_use_direct_kernel_boot() {
    [[ -f "${LINUX_QEMU_BUNDLED_KERNEL_IMAGE}" && -f "${LINUX_QEMU_BUNDLED_INITRD_IMAGE}" ]]
}

linux_qemu_use_baked_guest_init() {
    linux_qemu_use_direct_kernel_boot && [[ "${LINUX_QEMU_BASE_IMAGE_KIND}" == "seeded" ]]
}

linux_qemu_kernel_cmdline() {
    local console
    local init_arg=""

    if [[ "${LINUX_QEMU_ARCH}" == "arm64" ]]; then
        console="ttyAMA0"
    else
        console="ttyS0"
    fi

    if linux_qemu_use_baked_guest_init; then
        init_arg=" init=/usr/local/sbin/zfsbox-init"
    fi

    local root_arg="root=/dev/vda"

    if [[ -f "${LINUX_QEMU_BUNDLED_ROOTFS_UUID_FILE}" ]]; then
        root_arg="root=UUID=$(tr -d '[:space:]' < "${LINUX_QEMU_BUNDLED_ROOTFS_UUID_FILE}")"
    fi

    printf '%s rw rootfstype=ext4 console=%s fsck.mode=skip apparmor=0 loglevel=4 systemd.show_status=1 zfsbox.state_dir=%s zfsbox.host_root_mount=%s%s' \
        "${root_arg}" \
        "${console}" \
        "${LINUX_QEMU_STATE_DIR}" \
        "${LINUX_QEMU_HOST_ROOT_MOUNT}" \
        "${init_arg}"
}

linux_qemu_record_known_pool_paths() {
    local pool="$1"
    shift

    local existing_file new_file path

    [[ -n "${pool}" ]] || return 0

    linux_qemu_init_dirs
    existing_file="$(mktemp)"
    new_file="$(mktemp)"

    if [[ -f "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}" ]]; then
        grep -Fv "$(printf '%s\t' "${pool}")" "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}" > "${existing_file}" || true
    else
        : > "${existing_file}"
    fi

    cp "${existing_file}" "${new_file}"

    for path in "$@"; do
        [[ "${path}" == /* ]] || continue
        [[ -e "${path}" ]] || continue
        printf '%s\t%s\n' "${pool}" "${path}" >> "${new_file}"
    done

    sort -u "${new_file}" > "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}"
    rm -f "${existing_file}" "${new_file}"
}

linux_qemu_forget_known_pool() {
    local pool="$1"
    local tmp_file

    [[ -n "${pool}" ]] || return 0
    [[ -f "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}" ]] || return 0

    tmp_file="$(mktemp)"
    grep -Fv "$(printf '%s\t' "${pool}")" "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}" > "${tmp_file}" || true
    sort -u "${tmp_file}" > "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}"
    rm -f "${tmp_file}"
}

linux_qemu_rename_known_pool() {
    local old_pool="$1"
    local new_pool="$2"
    local tmp_file

    [[ -n "${old_pool}" && -n "${new_pool}" ]] || return 0
    [[ -f "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}" ]] || return 0

    tmp_file="$(mktemp)"

    awk -F '\t' -v old_pool="${old_pool}" -v new_pool="${new_pool}" '
        BEGIN { OFS = "\t" }
        $1 == old_pool { $1 = new_pool }
        { print }
    ' "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}" | sort -u > "${tmp_file}"

    mv "${tmp_file}" "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}"
}

linux_qemu_prepare_arch_assets() {
    if [[ "${LINUX_QEMU_ARCH}" != "arm64" ]]; then
        return
    fi

    if [[ ! -r "${LINUX_QEMU_ARM64_UEFI_FD}" ]]; then
        echo "ARM64 UEFI firmware not found: ${LINUX_QEMU_ARM64_UEFI_FD}" >&2
        exit 1
    fi

    if [[ ! -f "${LINUX_QEMU_ARM64_EFI_CODE_IMAGE}" ]]; then
        truncate -s 64M "${LINUX_QEMU_ARM64_EFI_CODE_IMAGE}"
        dd if="${LINUX_QEMU_ARM64_UEFI_FD}" of="${LINUX_QEMU_ARM64_EFI_CODE_IMAGE}" conv=notrunc status=none
    fi

    if [[ ! -f "${LINUX_QEMU_ARM64_EFI_VARS_IMAGE}" ]]; then
        truncate -s 64M "${LINUX_QEMU_ARM64_EFI_VARS_IMAGE}"
    fi
}

linux_qemu_guest_image_url() {
    printf 'https://cloud-images.ubuntu.com/%s/current/%s-server-cloudimg-%s.img\n' \
        "${GUEST_RELEASE}" "${GUEST_RELEASE}" "${LINUX_QEMU_ARCH}"
}

linux_qemu_download_base_image() {
    local url expected current

    expected="$(cat <<EOF
LINUX_QEMU_ARCH=${LINUX_QEMU_ARCH}
GUEST_RELEASE=${GUEST_RELEASE}
LINUX_QEMU_BUNDLED_BASE_IMAGE=${LINUX_QEMU_BUNDLED_BASE_IMAGE}
EOF
)"
    current="$(cat "${LINUX_QEMU_BASE_IMAGE_MARKER_FILE}" 2>/dev/null || true)"

    if [[ -f "${LINUX_QEMU_BASE_IMAGE}" && "${current}" == "${expected}" ]]; then
        if [[ -f "${LINUX_QEMU_BUNDLED_BASE_IMAGE}" ]]; then
            linux_qemu_classify_base_image "${LINUX_QEMU_BUNDLED_BASE_IMAGE}"
        else
            linux_qemu_classify_base_image "${LINUX_QEMU_BASE_IMAGE}"
        fi
        return
    fi

    rm -f "${LINUX_QEMU_BASE_IMAGE}"

    if [[ -f "${LINUX_QEMU_BUNDLED_BASE_IMAGE}" ]]; then
        linux_qemu_classify_base_image "${LINUX_QEMU_BUNDLED_BASE_IMAGE}"
        linux_qemu_log "using bundled seeded guest image (${GUEST_RELEASE})"
        cp "${LINUX_QEMU_BUNDLED_BASE_IMAGE}" "${LINUX_QEMU_BASE_IMAGE}"
        printf '%s\n' "${expected}" > "${LINUX_QEMU_BASE_IMAGE_MARKER_FILE}"
        return
    fi

    LINUX_QEMU_BASE_IMAGE_KIND="generic"
    url="$(linux_qemu_guest_image_url)"
    linux_qemu_log "downloading Ubuntu cloud image (${GUEST_RELEASE})"
    curl -fsSL "${url}" -o "${LINUX_QEMU_BASE_IMAGE}"
    printf '%s\n' "${expected}" > "${LINUX_QEMU_BASE_IMAGE_MARKER_FILE}"
}

linux_qemu_ensure_host_key() {
    if [[ -f "${LINUX_QEMU_HOST_KEY}" && -f "${LINUX_QEMU_HOST_KEY_PUB}" ]]; then
        return
    fi

    ssh-keygen -q -t ed25519 -N "" -f "${LINUX_QEMU_HOST_KEY}" >/dev/null
}

linux_qemu_render_cloud_init() {
    local pubkey
    local package_update_line package_block

    pubkey="$(cat "${LINUX_QEMU_HOST_KEY_PUB}")"
    linux_qemu_classify_base_image "${LINUX_QEMU_BUNDLED_BASE_IMAGE}"

    if [[ "${LINUX_QEMU_BASE_IMAGE_KIND}" == "seeded" ]]; then
        package_update_line="package_update: false"
        package_block=""
    else
        package_update_line="package_update: true"
        package_block="$(cat <<'EOF'
packages:
  - openssh-server
  - nfs-kernel-server
  - zfsutils-linux
EOF
)"
    fi

    cat > "${LINUX_QEMU_META_DATA}" <<EOF
instance-id: ${LINUX_QEMU_VM_NAME}
local-hostname: zfsbox
EOF

    cat > "${LINUX_QEMU_USER_DATA}" <<EOF
#cloud-config
${package_update_line}
package_upgrade: false
ssh_pwauth: false
disable_root: false
${package_block}
write_files:
  - path: /root/.ssh/authorized_keys
    permissions: "0600"
    owner: root:root
    content: |
      ${pubkey}
  - path: /etc/ssh/sshd_config.d/zfsbox.conf
    permissions: "0644"
    owner: root:root
    content: |
      PermitRootLogin yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
  - path: /usr/local/sbin/zfsbox-mount-hostroot.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      mkdir -p ${LINUX_QEMU_HOST_ROOT_MOUNT}
      if mountpoint -q ${LINUX_QEMU_HOST_ROOT_MOUNT}; then
          exit 0
      fi
      mount -t virtiofs hostroot ${LINUX_QEMU_HOST_ROOT_MOUNT} >/dev/null 2>&1 && exit 0
      mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,cache=mmap,access=client hostroot ${LINUX_QEMU_HOST_ROOT_MOUNT}
  - path: /etc/systemd/system/zfsbox-hostroot.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Mount host root inside zfsbox guest
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/zfsbox-mount-hostroot.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable --now zfsbox-hostroot.service
  - modprobe zfs || true
EOF
}

linux_qemu_build_seed_image() {
    linux_qemu_find_seed_builder
    rm -f "${LINUX_QEMU_SEED_IMAGE}"

    case "${LINUX_QEMU_SEED_BUILDER}" in
        cloud-localds)
            cloud-localds "${LINUX_QEMU_SEED_IMAGE}" "${LINUX_QEMU_USER_DATA}" "${LINUX_QEMU_META_DATA}"
            ;;
        genisoimage|mkisofs)
            "${LINUX_QEMU_SEED_BUILDER}" -output "${LINUX_QEMU_SEED_IMAGE}" -volid cidata -joliet -rock \
                "${LINUX_QEMU_USER_DATA}" "${LINUX_QEMU_META_DATA}" >/dev/null 2>&1
            ;;
        xorriso)
            xorriso -as mkisofs -output "${LINUX_QEMU_SEED_IMAGE}" -volid cidata -joliet -rock \
                "${LINUX_QEMU_USER_DATA}" "${LINUX_QEMU_META_DATA}" >/dev/null 2>&1
            ;;
    esac
}

linux_qemu_expected_marker() {
    cat <<EOF
LINUX_QEMU_LAYOUT_VERSION=${LINUX_QEMU_LAYOUT_VERSION}
LINUX_QEMU_ARCH=${LINUX_QEMU_ARCH}
GUEST_RELEASE=${GUEST_RELEASE}
LINUX_QEMU_HOST_ROOT_MOUNT=${LINUX_QEMU_HOST_ROOT_MOUNT}
LINUX_QEMU_HOST_SHARE=${LINUX_QEMU_HOST_SHARE}
VM_MEMORY_MB=${VM_MEMORY_MB}
VM_VCPUS=${VM_VCPUS}
VM_SSH_PORT=${VM_SSH_PORT}
VM_NFS_PORT=${VM_NFS_PORT}
LINUX_QEMU_BUNDLED_KERNEL_IMAGE=${LINUX_QEMU_BUNDLED_KERNEL_IMAGE}
LINUX_QEMU_BUNDLED_INITRD_IMAGE=${LINUX_QEMU_BUNDLED_INITRD_IMAGE}
LINUX_QEMU_STATE_DIR=${LINUX_QEMU_STATE_DIR}
LINUX_QEMU_ATTACHED_FILES=$(linux_qemu_attached_files_signature)
EOF
}

linux_qemu_reset_instance_if_needed() {
    local expected current

    linux_qemu_write_attached_files_manifest
    expected="$(linux_qemu_expected_marker)"
    current="$(cat "${LINUX_QEMU_MARKER_FILE}" 2>/dev/null || true)"

    if linux_qemu_use_baked_guest_init; then
        if [[ "${current}" == "${expected}" && -f "${LINUX_QEMU_OVERLAY_IMAGE}" ]]; then
            return
        fi
    elif [[ "${current}" == "${expected}" && -f "${LINUX_QEMU_OVERLAY_IMAGE}" && -f "${LINUX_QEMU_SEED_IMAGE}" ]]; then
        return
    fi

    rm -f "${LINUX_QEMU_OVERLAY_IMAGE}" "${LINUX_QEMU_SEED_IMAGE}" "${LINUX_QEMU_KNOWN_HOSTS}" "${LINUX_QEMU_READY_FILE}" "${LINUX_QEMU_GUEST_BOOTSTRAP_MARKER_FILE}"
    qemu-img create -f qcow2 -F qcow2 -b "${LINUX_QEMU_BASE_IMAGE}" "${LINUX_QEMU_OVERLAY_IMAGE}" >/dev/null
    if ! linux_qemu_use_baked_guest_init; then
        linux_qemu_render_cloud_init
        linux_qemu_build_seed_image
    fi
    printf '%s\n' "${expected}" > "${LINUX_QEMU_MARKER_FILE}"
}

linux_qemu_is_running() {
    local pid

    if [[ ! -f "${LINUX_QEMU_PID_FILE}" ]]; then
        return 1
    fi

    pid="$(cat "${LINUX_QEMU_PID_FILE}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] || return 1
    kill -0 "${pid}" 2>/dev/null
}

linux_qemu_current_pid() {
    cat "${LINUX_QEMU_PID_FILE}" 2>/dev/null || true
}

linux_qemu_bootstrap_complete_for_current_vm() {
    local current_pid

    current_pid="$(linux_qemu_current_pid)"
    [[ -n "${current_pid}" ]] || return 1
    [[ -f "${LINUX_QEMU_GUEST_BOOTSTRAP_MARKER_FILE}" ]] || return 1
    [[ "$(cat "${LINUX_QEMU_GUEST_BOOTSTRAP_MARKER_FILE}" 2>/dev/null || true)" == "${current_pid}" ]]
}

linux_qemu_mark_bootstrap_complete() {
    local current_pid

    current_pid="$(linux_qemu_current_pid)"
    [[ -n "${current_pid}" ]] || return 0
    printf '%s\n' "${current_pid}" > "${LINUX_QEMU_GUEST_BOOTSTRAP_MARKER_FILE}"
}

linux_qemu_start_vm() {
    local accel
    local stderr_file status=0
    local -a extra_x86_drive_args=()
    local -a extra_arm_drive_args=()
    local attached_path=""
    local attached_index=0

    stderr_file="$(mktemp)"

    accel="tcg"
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        accel="kvm:tcg"
        if [[ "${LINUX_QEMU_ARCH}" == "arm64" ]]; then
            LINUX_QEMU_CPU="host"
        fi
    fi

    rm -f "${LINUX_QEMU_PID_FILE}" "${LINUX_QEMU_READY_FILE}"
    : > "${LINUX_QEMU_SERIAL_LOG}"

    if [[ -f "${LINUX_QEMU_ATTACHED_FILES_FILE}" ]]; then
        while IFS= read -r attached_path; do
            [[ -n "${attached_path}" ]] || continue
            if [[ "${LINUX_QEMU_ARCH}" == "arm64" ]]; then
                extra_arm_drive_args+=(
                    -drive "if=none,format=raw,file=${attached_path},id=datadrive${attached_index}"
                    -device "virtio-blk-device,drive=datadrive${attached_index},serial=zfsbox-data-${attached_index}"
                )
            else
                extra_x86_drive_args+=(
                    -drive "if=none,format=raw,file=${attached_path},id=datadrive${attached_index}"
                    -device "virtio-blk-pci,drive=datadrive${attached_index},serial=zfsbox-data-${attached_index}"
                )
            fi
            attached_index=$((attached_index + 1))
        done < "${LINUX_QEMU_ATTACHED_FILES_FILE}"
    fi

    linux_qemu_log "starting rootless Linux VM"
    if [[ "${LINUX_QEMU_ARCH}" == "arm64" ]]; then
        if linux_qemu_use_direct_kernel_boot; then
            if linux_qemu_use_baked_guest_init; then
                "${LINUX_QEMU_QEMU_BIN}" \
                    -name "${LINUX_QEMU_VM_NAME}" \
                    -machine "${LINUX_QEMU_MACHINE},accel=${accel}" \
                    -cpu "${LINUX_QEMU_CPU}" \
                    -smp "${VM_VCPUS}" \
                    -m "${VM_MEMORY_MB}" \
                    -display none \
                    -serial "file:${LINUX_QEMU_SERIAL_LOG}" \
                    -daemonize \
                    -pidfile "${LINUX_QEMU_PID_FILE}" \
                    -device virtio-rng-device \
                    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${VM_NFS_PORT}-:2049" \
                    -device virtio-net-device,netdev=net0 \
                    -kernel "${LINUX_QEMU_BUNDLED_KERNEL_IMAGE}" \
                    -initrd "${LINUX_QEMU_BUNDLED_INITRD_IMAGE}" \
                    -append "$(linux_qemu_kernel_cmdline)" \
                    -drive "if=none,format=qcow2,file=${LINUX_QEMU_OVERLAY_IMAGE},id=rootfs" \
                    -device virtio-blk-device,drive=rootfs \
                    "${extra_arm_drive_args[@]}" \
                    -virtfs "local,id=hostroot,path=${LINUX_QEMU_HOST_SHARE},mount_tag=hostroot,security_model=none,multidevs=remap" \
                    2>"${stderr_file}" || status=$?
            else
                "${LINUX_QEMU_QEMU_BIN}" \
                    -name "${LINUX_QEMU_VM_NAME}" \
                    -machine "${LINUX_QEMU_MACHINE},accel=${accel}" \
                    -cpu "${LINUX_QEMU_CPU}" \
                    -smp "${VM_VCPUS}" \
                    -m "${VM_MEMORY_MB}" \
                    -display none \
                    -serial "file:${LINUX_QEMU_SERIAL_LOG}" \
                    -daemonize \
                    -pidfile "${LINUX_QEMU_PID_FILE}" \
                    -device virtio-rng-device \
                    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${VM_NFS_PORT}-:2049" \
                    -device virtio-net-device,netdev=net0 \
                    -kernel "${LINUX_QEMU_BUNDLED_KERNEL_IMAGE}" \
                    -initrd "${LINUX_QEMU_BUNDLED_INITRD_IMAGE}" \
                    -append "$(linux_qemu_kernel_cmdline)" \
                    -drive "if=none,format=qcow2,file=${LINUX_QEMU_OVERLAY_IMAGE},id=rootfs" \
                    -device virtio-blk-device,drive=rootfs \
                    "${extra_arm_drive_args[@]}" \
                    -drive "if=none,format=raw,file=${LINUX_QEMU_SEED_IMAGE},id=seed" \
                    -device virtio-blk-device,drive=seed \
                    -virtfs "local,id=hostroot,path=${LINUX_QEMU_HOST_SHARE},mount_tag=hostroot,security_model=none,multidevs=remap" \
                    2>"${stderr_file}" || status=$?
            fi
        else
            "${LINUX_QEMU_QEMU_BIN}" \
                -name "${LINUX_QEMU_VM_NAME}" \
                -machine "${LINUX_QEMU_MACHINE},accel=${accel}" \
                -cpu "${LINUX_QEMU_CPU}" \
                -smp "${VM_VCPUS}" \
                -m "${VM_MEMORY_MB}" \
                -display none \
                -serial "file:${LINUX_QEMU_SERIAL_LOG}" \
                -daemonize \
                -pidfile "${LINUX_QEMU_PID_FILE}" \
                -device virtio-rng-device \
                -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${VM_NFS_PORT}-:2049" \
                -device virtio-net-device,netdev=net0 \
                -drive "if=pflash,format=raw,unit=0,readonly=on,file=${LINUX_QEMU_ARM64_EFI_CODE_IMAGE}" \
                -drive "if=pflash,format=raw,unit=1,file=${LINUX_QEMU_ARM64_EFI_VARS_IMAGE}" \
                -drive "if=none,format=qcow2,file=${LINUX_QEMU_OVERLAY_IMAGE},id=rootfs" \
                -device virtio-blk-device,drive=rootfs \
                "${extra_arm_drive_args[@]}" \
                -drive "if=none,format=raw,file=${LINUX_QEMU_SEED_IMAGE},id=seed" \
                -device virtio-blk-device,drive=seed \
                -virtfs "local,id=hostroot,path=${LINUX_QEMU_HOST_SHARE},mount_tag=hostroot,security_model=none,multidevs=remap" \
                2>"${stderr_file}" || status=$?
        fi
    else
        if linux_qemu_use_direct_kernel_boot; then
            if linux_qemu_use_baked_guest_init; then
                "${LINUX_QEMU_QEMU_BIN}" \
                    -name "${LINUX_QEMU_VM_NAME}" \
                    -machine "${LINUX_QEMU_MACHINE},accel=${accel}" \
                    -cpu "${LINUX_QEMU_CPU}" \
                    -smp "${VM_VCPUS}" \
                    -m "${VM_MEMORY_MB}" \
                    -display none \
                    -serial "file:${LINUX_QEMU_SERIAL_LOG}" \
                    -daemonize \
                    -pidfile "${LINUX_QEMU_PID_FILE}" \
                    -device virtio-rng-pci \
                    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${VM_NFS_PORT}-:2049" \
                    -kernel "${LINUX_QEMU_BUNDLED_KERNEL_IMAGE}" \
                    -initrd "${LINUX_QEMU_BUNDLED_INITRD_IMAGE}" \
                    -append "$(linux_qemu_kernel_cmdline)" \
                    -drive "if=virtio,format=qcow2,file=${LINUX_QEMU_OVERLAY_IMAGE}" \
                    "${extra_x86_drive_args[@]}" \
                    -virtfs "local,id=hostroot,path=${LINUX_QEMU_HOST_SHARE},mount_tag=hostroot,security_model=none,multidevs=remap" \
                    2>"${stderr_file}" || status=$?
            else
                "${LINUX_QEMU_QEMU_BIN}" \
                    -name "${LINUX_QEMU_VM_NAME}" \
                    -machine "${LINUX_QEMU_MACHINE},accel=${accel}" \
                    -cpu "${LINUX_QEMU_CPU}" \
                    -smp "${VM_VCPUS}" \
                    -m "${VM_MEMORY_MB}" \
                    -display none \
                    -serial "file:${LINUX_QEMU_SERIAL_LOG}" \
                    -daemonize \
                    -pidfile "${LINUX_QEMU_PID_FILE}" \
                    -device virtio-rng-pci \
                    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${VM_NFS_PORT}-:2049" \
                    -kernel "${LINUX_QEMU_BUNDLED_KERNEL_IMAGE}" \
                    -initrd "${LINUX_QEMU_BUNDLED_INITRD_IMAGE}" \
                    -append "$(linux_qemu_kernel_cmdline)" \
                    -drive "if=virtio,format=qcow2,file=${LINUX_QEMU_OVERLAY_IMAGE}" \
                    "${extra_x86_drive_args[@]}" \
                    -drive "if=virtio,format=raw,media=cdrom,file=${LINUX_QEMU_SEED_IMAGE}" \
                    -virtfs "local,id=hostroot,path=${LINUX_QEMU_HOST_SHARE},mount_tag=hostroot,security_model=none,multidevs=remap" \
                    2>"${stderr_file}" || status=$?
            fi
        else
            "${LINUX_QEMU_QEMU_BIN}" \
                -name "${LINUX_QEMU_VM_NAME}" \
                -machine "${LINUX_QEMU_MACHINE},accel=${accel}" \
                -cpu "${LINUX_QEMU_CPU}" \
                -smp "${VM_VCPUS}" \
                -m "${VM_MEMORY_MB}" \
                -display none \
                -serial "file:${LINUX_QEMU_SERIAL_LOG}" \
                -daemonize \
                -pidfile "${LINUX_QEMU_PID_FILE}" \
                -device virtio-rng-pci \
                -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${VM_NFS_PORT}-:2049" \
                -drive "if=virtio,format=qcow2,file=${LINUX_QEMU_OVERLAY_IMAGE}" \
                "${extra_x86_drive_args[@]}" \
                -drive "if=virtio,format=raw,media=cdrom,file=${LINUX_QEMU_SEED_IMAGE}" \
                -virtfs "local,id=hostroot,path=${LINUX_QEMU_HOST_SHARE},mount_tag=hostroot,security_model=none,multidevs=remap" \
                2>"${stderr_file}" || status=$?
        fi
    fi

    if [[ "${status}" -ne 0 ]]; then
        if grep -Fq 'Failed to get "write" lock' "${stderr_file}"; then
            if linux_qemu_try_use_shared_vm; then
                return 0
            fi

            cat >&2 <<EOF
zfsbox: this VM state is already in use by another container.
If a background service is already running, reuse it with:
  docker compose exec zfsbox ...
Otherwise stop the other container before starting a new VM.
EOF
            return 1
        fi

        cat "${stderr_file}" >&2
        rm -f "${stderr_file}"
        return "${status}"
    fi

    rm -f "${stderr_file}"
}

linux_qemu_try_use_shared_vm() {
    local candidate_host="host.docker.internal"

    linux_qemu_inside_container || return 1

    if ! getent hosts "${candidate_host}" >/dev/null 2>&1; then
        return 1
    fi

    if ssh \
        -F /dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=2 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${LINUX_QEMU_KNOWN_HOSTS}" \
        -i "${LINUX_QEMU_HOST_KEY}" \
        -p "${VM_SSH_PORT}" \
        root@"${candidate_host}" \
        "mountpoint -q ${LINUX_QEMU_HOST_ROOT_MOUNT} && command -v zpool >/dev/null 2>&1" \
        >/dev/null 2>&1; then
        LINUX_QEMU_GUEST_HOST="${candidate_host}"
        return 0
    fi

    return 1
}

linux_qemu_wait_for_guest() {
    local waited=0
    local timeout="${LINUX_QEMU_WAIT_TIMEOUT:-600}"

    while (( waited < timeout )); do
        if linux_qemu_use_baked_guest_init && [[ -s "${LINUX_QEMU_READY_FILE}" ]]; then
            return 0
        fi

        if linux_qemu_ssh_run \
            -F /dev/null \
            -o BatchMode=yes \
            -o ConnectTimeout=2 \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${LINUX_QEMU_KNOWN_HOSTS}" \
            -i "${LINUX_QEMU_HOST_KEY}" \
            -p "${VM_SSH_PORT}" \
            root@"${LINUX_QEMU_GUEST_HOST}" \
            "mountpoint -q ${LINUX_QEMU_HOST_ROOT_MOUNT}" \
            >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
        waited=$((waited + 2))
    done

    echo "Linux VM did not become ready within ${timeout}s. See ${LINUX_QEMU_SERIAL_LOG}" >&2
    tail -n 40 "${LINUX_QEMU_SERIAL_LOG}" >&2 || true
    exit 1
}

linux_qemu_ensure_guest_tools() {
    if linux_qemu_use_baked_guest_init; then
        LINUX_QEMU_SSH_TIMEOUT_SECONDS="${LINUX_QEMU_GUEST_SETUP_TIMEOUT_SECONDS:-120}" linux_qemu_ssh_run \
            -F /dev/null \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${LINUX_QEMU_KNOWN_HOSTS}" \
            -i "${LINUX_QEMU_HOST_KEY}" \
            -p "${VM_SSH_PORT}" \
            root@"${LINUX_QEMU_GUEST_HOST}" \
            "bash -lc 'set -Eeuo pipefail; command -v zpool >/dev/null 2>&1; command -v exportfs >/dev/null 2>&1; modprobe zfs >/dev/null 2>&1 || true'" \
            >/dev/null
        return
    fi

    LINUX_QEMU_SSH_TIMEOUT_SECONDS="${LINUX_QEMU_GUEST_SETUP_TIMEOUT_SECONDS:-900}" linux_qemu_ssh_run \
        -F /dev/null \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${LINUX_QEMU_KNOWN_HOSTS}" \
        -i "${LINUX_QEMU_HOST_KEY}" \
        -p "${VM_SSH_PORT}" \
        root@"${LINUX_QEMU_GUEST_HOST}" \
        "bash -lc '
set -Eeuo pipefail

if command -v zpool >/dev/null 2>&1 && command -v exportfs >/dev/null 2>&1; then
    modprobe zfs >/dev/null 2>&1 || true
    exit 0
fi

if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait >/dev/null 2>&1 || true
fi

if ! command -v zpool >/dev/null 2>&1; then
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y zfsutils-linux >/dev/null 2>&1
fi

if ! command -v exportfs >/dev/null 2>&1; then
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y nfs-kernel-server >/dev/null 2>&1
fi

modprobe zfs >/dev/null 2>&1 || true
'"
}

linux_qemu_ensure_vm_running() {
    local lock_fd=""

    linux_qemu_require_linux
    linux_qemu_init_dirs
    linux_qemu_require_dependencies
    linux_qemu_prepare_arch_assets
    linux_qemu_download_base_image
    linux_qemu_ensure_host_key

    if command -v flock >/dev/null 2>&1; then
        exec {lock_fd}>"${LINUX_QEMU_STATE_DIR}/vm.lock"
        flock "${lock_fd}"
    fi

    if linux_qemu_try_use_shared_vm; then
        if [[ -n "${lock_fd}" ]]; then
            flock -u "${lock_fd}" || true
            eval "exec ${lock_fd}>&-"
        fi
        return
    fi

    linux_qemu_reset_instance_if_needed

    if ! linux_qemu_is_running; then
        linux_qemu_start_vm || exit 1
    fi

    if ! linux_qemu_bootstrap_complete_for_current_vm; then
        linux_qemu_wait_for_guest
        linux_qemu_ensure_guest_tools
        linux_qemu_import_known_pools
        linux_qemu_mark_bootstrap_complete
    fi

    if [[ -n "${lock_fd}" ]]; then
        flock -u "${lock_fd}" || true
        eval "exec ${lock_fd}>&-"
    fi
}

linux_qemu_guest_exec_raw() {
    local remote_args=""

    linux_qemu_ensure_vm_running
    printf -v remote_args ' %q' "$@"

    linux_qemu_ssh_run \
        -F /dev/null \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${LINUX_QEMU_KNOWN_HOSTS}" \
        -i "${LINUX_QEMU_HOST_KEY}" \
        -p "${VM_SSH_PORT}" \
        root@"${LINUX_QEMU_GUEST_HOST}" \
        "set -Eeuo pipefail; set --${remote_args}; exec \"\$@\""
}

linux_qemu_import_known_pools() {
    local pool host_path guest_path import_path

    [[ -f "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}" ]] || return 0

    while IFS=$'\t' read -r pool host_path; do
        [[ -n "${pool:-}" && -n "${host_path:-}" ]] || continue
        [[ -e "${host_path}" ]] || continue

        guest_path="${LINUX_QEMU_HOST_ROOT_MOUNT}${host_path}"
        if guest_path="$(linux_qemu_guest_device_for_host_path "${host_path}")"; then
            import_path="${guest_path}"
        else
            guest_path="${LINUX_QEMU_HOST_ROOT_MOUNT}${host_path}"
            import_path="${guest_path}"
            if [[ ! -b "${host_path}" && ! -c "${host_path}" ]]; then
                import_path="$(dirname "${guest_path}")"
            fi
        fi

        linux_qemu_guest_exec_raw bash -lc "
set -Eeuo pipefail

if zpool list -H -o name '${pool}' >/dev/null 2>&1; then
    exit 0
fi

if [[ ! -e '${guest_path}' ]]; then
    exit 0
fi

zpool import -f -d '${import_path}' '${pool}' >/dev/null 2>&1 || exit 0
zfs mount -a >/dev/null 2>&1 || true
" || true
    done < "${LINUX_QEMU_KNOWN_POOL_PATHS_FILE}"
}

linux_qemu_guest_exec() {
    linux_qemu_ensure_vm_running
    linux_qemu_guest_exec_raw "$@"
}
