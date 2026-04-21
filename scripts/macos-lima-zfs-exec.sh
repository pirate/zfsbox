#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
STATE_ROOT_DIR="${ZFSBOX_STATE_DIR:-${PROJECT_DIR}/state}"
STATE_DIR="${STATE_ROOT_DIR}/macos-vz"
ASSETS_DIR="${STATE_DIR}/assets"
CLOUD_DIR="${STATE_DIR}/cloud"
HELPER_SOURCE="${PROJECT_DIR}/scripts/macos-vz-helper.swift"
HELPER_ENTITLEMENTS="${PROJECT_DIR}/scripts/macos-vz-helper.entitlements"
HELPER_BIN="${STATE_DIR}/zfsbox-vz-helper"
BASE_QCOW2="${ASSETS_DIR}/ubuntu-cloudimg.qcow2"
BASE_RAW="${ASSETS_DIR}/ubuntu-cloudimg.raw"
ROOTFS_RAW="${ASSETS_DIR}/rootfs.raw"
ROOTFS_IMAGE="${ASSETS_DIR}/rootfs.dmg"
SEED_IMAGE="${ASSETS_DIR}/seed.dmg"
KERNEL_IMAGE="${ASSETS_DIR}/vmlinuz"
KERNEL_UNCOMPRESSED_IMAGE="${ASSETS_DIR}/Image"
INITRD_IMAGE="${ASSETS_DIR}/initrd"
HOST_KEY="${STATE_DIR}/id_ed25519"
HOST_KEY_PUB="${HOST_KEY}.pub"
KNOWN_HOSTS="${STATE_DIR}/known_hosts"
PID_FILE="${STATE_DIR}/vz.pid"
HELPER_LOG="${STATE_DIR}/helper.log"
SERIAL_LOG="${STATE_DIR}/serial.log"
GUEST_IP_FILE="${STATE_DIR}/guest-ip"
ATTACHMENTS_FILE="${STATE_DIR}/attachments.txt"
RUN_AS_ROOT_FILE="${STATE_DIR}/run-as-root"
VM_TMUX_SESSION="zfsbox-vz"
HOST_SHARE="/"
VM_MEMORY_MB=2048
VM_VCPUS=2
GUEST_MAC_ADDRESS="${GUEST_MAC_ADDRESS:-02:00:00:00:00:01}"
VM_SSH_TIMEOUT_SECONDS="${VM_SSH_TIMEOUT_SECONDS:-10}"
VM_WAIT_TIMEOUT_SECONDS="${VM_WAIT_TIMEOUT_SECONDS:-600}"
GUEST_RELEASE="${GUEST_RELEASE:-noble}"
GUEST_IMAGE_URL="${GUEST_IMAGE_URL:-https://cloud-images.ubuntu.com/${GUEST_RELEASE}/current/${GUEST_RELEASE}-server-cloudimg-arm64.img}"
KERNEL_URL="${KERNEL_URL:-https://cloud-images.ubuntu.com/${GUEST_RELEASE}/current/unpacked/${GUEST_RELEASE}-server-cloudimg-arm64-vmlinuz-generic}"
INITRD_URL="${INITRD_URL:-https://cloud-images.ubuntu.com/${GUEST_RELEASE}/current/unpacked/${GUEST_RELEASE}-server-cloudimg-arm64-initrd-generic}"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

log() {
    printf 'zfsbox: %s\n' "$*" >&2
}

require_cmd() {
    local name="$1"
    command -v "${name}" >/dev/null 2>&1 || {
        echo "Required command not found: ${name}" >&2
        exit 1
    }
}

host_root_run() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
        return
    fi
    sudo "$@"
}

init_dirs() {
    mkdir -p "${STATE_DIR}" "${ASSETS_DIR}" "${CLOUD_DIR}"
}

ensure_dependencies() {
    require_cmd curl
    require_cmd qemu-img
    require_cmd ssh
    require_cmd ssh-keygen
    require_cmd hdiutil
    require_cmd tmux
    require_cmd swiftc
}

ensure_host_key() {
    if [[ -f "${HOST_KEY}" && -f "${HOST_KEY_PUB}" ]]; then
        return
    fi
    ssh-keygen -q -t ed25519 -N "" -f "${HOST_KEY}" >/dev/null
}

compile_helper() {
    if [[ ! -x "${HELPER_BIN}" || "${HELPER_SOURCE}" -nt "${HELPER_BIN}" || "${HELPER_ENTITLEMENTS}" -nt "${HELPER_BIN}" ]]; then
        log "compiling native macOS VM helper"
        swiftc -framework Virtualization "${HELPER_SOURCE}" -o "${HELPER_BIN}"
        codesign -s - --force --entitlements "${HELPER_ENTITLEMENTS}" "${HELPER_BIN}" >/dev/null
    fi
}

ensure_base_image() {
    if [[ ! -f "${BASE_QCOW2}" ]]; then
        log "downloading Ubuntu cloud image (${GUEST_RELEASE})"
        curl -fsSL "${GUEST_IMAGE_URL}" -o "${BASE_QCOW2}"
    fi

    if [[ ! -f "${BASE_RAW}" || "${BASE_QCOW2}" -nt "${BASE_RAW}" ]]; then
        log "converting Ubuntu cloud image to raw format"
        qemu-img convert -f qcow2 -O raw "${BASE_QCOW2}" "${BASE_RAW}"
    fi

    if [[ ! -f "${ROOTFS_RAW}" ]]; then
        log "seeding writable VM rootfs"
        cp "${BASE_RAW}" "${ROOTFS_RAW}"
    fi

    if [[ ! -f "${ROOTFS_IMAGE}" || "${ROOTFS_RAW}" -nt "${ROOTFS_IMAGE}" ]]; then
        log "rewrapping VM rootfs into VZ-compatible disk image"
        rm -f "${ROOTFS_IMAGE}" "${ROOTFS_IMAGE%.dmg}"
        hdiutil convert \
            "${ROOTFS_RAW}" \
            -srcimagekey diskimage-class=CRawDiskImage \
            -format UDRW \
            -o "${ROOTFS_IMAGE%.dmg}" >/dev/null
    fi

    if [[ ! -f "${KERNEL_IMAGE}" ]]; then
        log "downloading Ubuntu kernel"
        curl -fsSL "${KERNEL_URL}" -o "${KERNEL_IMAGE}"
    fi

    if [[ ! -f "${KERNEL_UNCOMPRESSED_IMAGE}" || "${KERNEL_IMAGE}" -nt "${KERNEL_UNCOMPRESSED_IMAGE}" ]]; then
        log "decompressing Ubuntu kernel for Virtualization.framework"
        gzip -dc "${KERNEL_IMAGE}" > "${KERNEL_UNCOMPRESSED_IMAGE}.tmp"
        mv "${KERNEL_UNCOMPRESSED_IMAGE}.tmp" "${KERNEL_UNCOMPRESSED_IMAGE}"
    fi

    if [[ ! -f "${INITRD_IMAGE}" ]]; then
        log "downloading Ubuntu initrd"
        curl -fsSL "${INITRD_URL}" -o "${INITRD_IMAGE}"
    fi
}

render_cloud_init() {
    local pubkey="$1"

    cat > "${CLOUD_DIR}/meta-data" <<EOF
instance-id: zfsbox-macos-vz
local-hostname: zfsbox
EOF

    cat > "${CLOUD_DIR}/user-data" <<EOF
#cloud-config
package_update: true
package_upgrade: false
ssh_pwauth: false
disable_root: false
packages:
  - openssh-server
  - nfs-kernel-server
  - zfsutils-linux
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
  - path: /etc/netplan/90-zfsbox.yaml
    permissions: "0644"
    owner: root:root
    content: |
      network:
        version: 2
        ethernets:
          enp0s1:
            match:
              macaddress: ${GUEST_MAC_ADDRESS}
            set-name: enp0s1
            dhcp4: true
  - path: /usr/local/sbin/zfsbox-report-ip.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      for _ in \$(seq 1 60); do
        guest_ip=\$(ip -4 -o addr show scope global | awk '{split(\$4, cidr, "/"); print cidr[1]; exit}')
        if [[ -n "\${guest_ip}" ]]; then
          printf 'ZFSBOX_GUEST_IP=%s\n' "\${guest_ip}" > /dev/console
          exit 0
        fi
        sleep 1
      done
      echo 'zfsbox: no guest IPv4 address became available' > /dev/console
      exit 1
  - path: /etc/systemd/system/zfsbox-report-ip.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Write zfsbox guest IP to the serial console
      After=network-online.target ssh.socket
      Wants=network-online.target ssh.socket

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/zfsbox-report-ip.sh

      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable --now zfsbox-report-ip.service
  - modprobe zfs || true
EOF
}

build_seed_image() {
    local pubkey
    local mountpoint
    local device
    pubkey="$(cat "${HOST_KEY_PUB}")"
    render_cloud_init "${pubkey}"

    rm -f "${SEED_IMAGE}"
    hdiutil create -size 16m -fs MS-DOS -volname cidata "${SEED_IMAGE}" >/dev/null

    mountpoint="$(mktemp -d /tmp/zfsbox-seed.XXXXXX)"
    device="$(hdiutil attach -nobrowse -mountpoint "${mountpoint}" "${SEED_IMAGE}" | awk 'NR==1 {print $1}')"
    cp "${CLOUD_DIR}/meta-data" "${mountpoint}/meta-data"
    cp "${CLOUD_DIR}/user-data" "${mountpoint}/user-data"
    sync
    hdiutil detach "${device}" >/dev/null
    rmdir "${mountpoint}"
}

attachment_needs_root() {
    local path="$1"
    [[ "${path}" == /dev/* ]]
}

compute_attachment_set() {
    local arg
    local -a attachments=()

    for arg in "$@"; do
        case "${arg}" in
            /dev/*)
                [[ -e "${arg}" ]] || {
                    echo "Block device does not exist: ${arg}" >&2
                    exit 1
                }
                attachments+=("${arg}")
                ;;
        esac
    done

    printf '%s\n' "${attachments[@]}"
}

translated_device_path() {
    local index="$1"
    local letter
    printf -v letter "\\$(printf '%03o' "$((99 + index))")"
    printf '/dev/vd%s\n' "${letter}"
}

translate_args() {
    local index=0
    local arg
    local -a translated=()

    for arg in "$@"; do
        case "${arg}" in
            /dev/*)
                translated+=("$(translated_device_path "${index}")")
                index=$((index + 1))
                ;;
            /*)
                translated+=("/host${arg}")
                ;;
            *)
                translated+=("${arg}")
                ;;
        esac
    done

    printf '%s\n' "${translated[@]}"
}

vm_running() {
    local run_as_root="0"

    if [[ -f "${RUN_AS_ROOT_FILE}" ]]; then
        run_as_root="$(cat "${RUN_AS_ROOT_FILE}" 2>/dev/null || printf '0')"
    fi

    if [[ "${run_as_root}" == "1" ]]; then
        host_root_run tmux has-session -t "${VM_TMUX_SESSION}" >/dev/null 2>&1
    else
        tmux has-session -t "${VM_TMUX_SESSION}" >/dev/null 2>&1
    fi
}

stop_vm() {
    local run_as_root="0"

    if [[ -f "${RUN_AS_ROOT_FILE}" ]]; then
        run_as_root="$(cat "${RUN_AS_ROOT_FILE}" 2>/dev/null || printf '0')"
    fi

    if [[ "${run_as_root}" == "1" ]]; then
        host_root_run tmux kill-session -t "${VM_TMUX_SESSION}" >/dev/null 2>&1 || true
    else
        tmux kill-session -t "${VM_TMUX_SESSION}" >/dev/null 2>&1 || true
    fi

    for _ in $(seq 1 20); do
        if ! vm_running; then
            rm -f "${PID_FILE}" "${RUN_AS_ROOT_FILE}"
            return 0
        fi
        sleep 1
    done

    rm -f "${PID_FILE}" "${RUN_AS_ROOT_FILE}"
}

attachments_changed() {
    local new_file
    new_file="$(mktemp)"
    printf '%s\n' "$@" > "${new_file}"
    if ! cmp -s "${new_file}" "${ATTACHMENTS_FILE}" 2>/dev/null; then
        mv "${new_file}" "${ATTACHMENTS_FILE}"
        return 0
    fi
    rm -f "${new_file}"
    return 1
}

start_vm() {
    local use_root="$1"
    shift
    local -a attachments=("$@")
    local attempt
    local inner_cmd
    local helper_log_q
    local launcher_cmd
    local -a cmd=(
        "${HELPER_BIN}"
        --kernel "${KERNEL_UNCOMPRESSED_IMAGE}"
        --initrd "${INITRD_IMAGE}"
        --rootfs "${ROOTFS_IMAGE}"
        --seed "${SEED_IMAGE}"
        --state-share "${STATE_DIR}"
        --host-share "${HOST_SHARE}"
        --serial-log "${SERIAL_LOG}"
    )

    rm -f "${GUEST_IP_FILE}" "${HELPER_LOG}" "${SERIAL_LOG}"

    for attachment in "${attachments[@]}"; do
        cmd+=(--attach "${attachment}")
    done

    printf -v helper_log_q '%q' "${HELPER_LOG}"
    printf -v inner_cmd 'cd %q && exec ' "${PROJECT_DIR}"
    printf -v inner_cmd '%s%q ' "${inner_cmd}" "${cmd[0]}"
    for (( attempt = 1; attempt < ${#cmd[@]}; attempt++ )); do
        printf -v inner_cmd '%s%q ' "${inner_cmd}" "${cmd[attempt]}"
    done
    inner_cmd="${inner_cmd} >>${helper_log_q} 2>&1"
    printf -v launcher_cmd 'tmux new-session -d -s %q zsh -lc %q' "${VM_TMUX_SESSION}" "${inner_cmd}"

    for attempt in 1 2 3 4 5; do
        rm -f "${PID_FILE}" "${RUN_AS_ROOT_FILE}"

        if [[ "${use_root}" == "1" ]]; then
            host_root_run zsh -lc "${launcher_cmd}"
        else
            zsh -lc "${launcher_cmd}"
        fi
        printf '%s\n' "${use_root}" > "${RUN_AS_ROOT_FILE}"

        sleep 4
        if vm_running; then
            return 0
        fi

        if grep -Fq 'storage device attachment is invalid' "${HELPER_LOG}" 2>/dev/null; then
            rm -f "${HELPER_LOG}" "${SERIAL_LOG}" "${PID_FILE}" "${RUN_AS_ROOT_FILE}"
            sleep 1
            continue
        fi

        break
    done

    echo "Failed to start native macOS VM. See ${HELPER_LOG}." >&2
    exit 1
}

guest_ip() {
    awk -F= '/ZFSBOX_GUEST_IP=/{value=$2} END{print value}' "${SERIAL_LOG}" 2>/dev/null | tr -d '[:space:]'
}

wait_for_guest_ip() {
    local waited=0
    local guest_ip_value

    while (( waited < VM_WAIT_TIMEOUT_SECONDS )); do
        guest_ip_value="$(guest_ip)"
        if [[ -n "${guest_ip_value}" ]]; then
            printf '%s\n' "${guest_ip_value}"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo "Timed out waiting for guest IP. See ${HELPER_LOG} and ${SERIAL_LOG}." >&2
    exit 1
}

ssh_guest() {
    local guest_ip_value="$1"
    shift
    ssh \
        -F /dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=2 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${KNOWN_HOSTS}" \
        -i "${HOST_KEY}" \
        root@"${guest_ip_value}" \
        "$@"
}

wait_for_ssh() {
    local guest_ip_value="$1"
    local waited=0

    while (( waited < VM_WAIT_TIMEOUT_SECONDS )); do
        if ssh_guest "${guest_ip_value}" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo "Timed out waiting for guest SSH. See ${HELPER_LOG} and ${SERIAL_LOG}." >&2
    exit 1
}

ensure_guest_ready() {
    local guest_ip_value="$1"

    ssh_guest "${guest_ip_value}" "bash -lc '
set -Eeuo pipefail
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait >/dev/null 2>&1 || true
fi
if ! command -v zpool >/dev/null 2>&1; then
  env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1
  env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y zfsutils-linux >/dev/null 2>&1
fi
if ! command -v exportfs >/dev/null 2>&1; then
  env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y nfs-kernel-server >/dev/null 2>&1
fi
modprobe zfs >/dev/null 2>&1 || true
'>" >/dev/null 2>&1
}

ensure_vm() {
    local -a attachments=("$@")
    local attachment
    local needs_root=0

    init_dirs
    ensure_dependencies
    ensure_host_key
    compile_helper
    ensure_base_image
    build_seed_image

    for attachment in "${attachments[@]}"; do
        if attachment_needs_root "${attachment}"; then
            needs_root=1
            break
        fi
    done

    if attachments_changed "${attachments[@]}"; then
        stop_vm
    fi

    if ! vm_running; then
        log "starting native macOS VM"
        start_vm "${needs_root}" "${attachments[@]}"
    fi

    local guest_ip_value
    guest_ip_value="$(wait_for_guest_ip)"
    wait_for_ssh "${guest_ip_value}"
    ensure_guest_ready "${guest_ip_value}"
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $(basename "$0") <command> [args...]" >&2
        exit 1
    fi

    mapfile -t ATTACHMENTS < <(compute_attachment_set "$@")
    mapfile -t TRANSLATED_ARGS < <(translate_args "$@")

    ensure_vm "${ATTACHMENTS[@]}"
    exec ssh_guest "$(wait_for_guest_ip | tr -d '[:space:]')" sudo "${TRANSLATED_ARGS[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
