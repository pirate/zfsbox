#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ZFSBOX_STATE_DIR:-${PROJECT_DIR}/state}"
ENV_FILE="${PROJECT_DIR}/.env"
SKIP_HOST_MOUNTS="${ZFSBOX_SKIP_HOST_MOUNTS:-0}"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

LIMA_INSTANCE_NAME="${LIMA_INSTANCE_NAME:-${INSTANCE_NAME:-zfsbox-zfs}}"
MACOS_VZ_STATE_DIR="${STATE_DIR}/macos-vz"
mkdir -p "${STATE_DIR}"

log() {
    printf 'zfsbox: %s\n' "$*" >&2
}

host_os="$(uname -s)"
mounts_available=1
mounts_unavailable_reason=""

if [[ "${host_os}" == "Linux" && -f "${PROJECT_DIR}/scripts/linux-qemu-common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/scripts/linux-qemu-common.sh"
fi

case "${host_os}" in
    Darwin)
        managed_state_file="${STATE_DIR}/host-mounts.darwin.txt"
        ;;
    Linux)
        managed_state_file="${STATE_DIR}/host-mounts.linux.txt"
        ;;
    *)
        echo "Unsupported host OS: ${host_os}" >&2
        exit 1
        ;;
esac

inside_container() {
    [[ -f /.dockerenv ]]
}

host_has_cap_sys_admin() {
    local caps_hex

    [[ "${host_os}" == "Linux" ]] || return 1
    caps_hex="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || true)"
    [[ -n "${caps_hex}" ]] || return 1
    (( (16#${caps_hex}) & (1 << 21) ))
}

host_root_run() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
        return
    fi

    sudo "$@"
}

mount_permission_error() {
    local error_text="$1"

    [[ "${error_text}" == *"permission denied"* ]] || \
        [[ "${error_text}" == *"Operation not permitted"* ]] || \
        [[ "${error_text}" == *"operation not permitted"* ]]
}

set_mounts_unavailable() {
    local reason="$1"

    mounts_available=0
    mounts_unavailable_reason="${reason}"
}

print_mount_fallback_notice() {
    local pool="$1"
    local target="$2"

    printf 'Pool created or updated and exposed via NFSv4 at 127.0.0.1:%s:/%s (%s).\n' "${VM_NFS_PORT}" "${pool}" "${target}" >&2

    if inside_container; then
        cat >&2 <<EOF
Automatic mount at ${target} was skipped because this container cannot perform mounts (${mounts_unavailable_reason}).
To use the export, either:

Option A: Mount the NFS export in a context that has mount permission, then bind-mount it into containers.
  \$ docker run -p 127.0.0.1:${VM_NFS_PORT}:${VM_NFS_PORT} <your-image-with-zfsbox> zfsbox-zpool create ${pool} ...
  \$ sudo mkdir -p ${target}
  \$ sudo mount -t nfs4 -o port=${VM_NFS_PORT},proto=tcp,vers=4 127.0.0.1:/${pool} ${target}
  \$ docker run -v ${target}:${target} <any-image> ls ${target}

  Or create a Docker NFS volume instead of a host bind mount:
  \$ export NFS_SERVER=127.0.0.1
  \$ export NFS_OPTS=port=${VM_NFS_PORT},proto=tcp,vers=4
  \$ export NFS_SHARE=/${pool}
  \$ export NFS_VOL_NAME=${pool}
  \$ docker volume create \\
      --driver local \\
      --opt type=nfs \\
      --opt o=addr=\${NFS_SERVER},\${NFS_OPTS} \\
      --opt device=:\${NFS_SHARE} \\
      \${NFS_VOL_NAME}

Option B: Re-run this container with CAP_SYS_ADMIN so zfsbox can auto-mount ${target} inside the container.
  \$ docker run --cap-add SYS_ADMIN <your-image-with-zfsbox> zfsbox-zpool create ${pool} ...
EOF
        return
    fi

    cat >&2 <<EOF
Automatic mount at ${target} was skipped because this environment cannot perform mounts (${mounts_unavailable_reason}).
To mount it in a context that has mount permission, run:
  \$ sudo mkdir -p ${target}
  \$ sudo mount -t nfs4 -o port=${VM_NFS_PORT},proto=tcp,vers=4 127.0.0.1:/${pool} ${target}
EOF
}

guest_exec() {
    local script="$1"

    if [[ "${host_os}" == "Darwin" ]]; then
        "${PROJECT_DIR}/scripts/macos-lima-zfs-exec.sh" bash -lc "${script}"
    else
        linux_qemu_guest_exec bash -lc "${script}"
    fi
}

guest_sudo_exec() {
    local script="$1"

    if [[ "${host_os}" == "Darwin" ]]; then
        "${PROJECT_DIR}/scripts/macos-lima-zfs-exec.sh" bash -lc "${script}"
    else
        guest_exec "${script}"
    fi
}

ensure_guest_exports() {
    local host_client_q="$1"

    if [[ "${host_os}" == "Linux" ]]; then
        guest_sudo_exec "
set -Eeuo pipefail

if command -v apt-get >/dev/null 2>&1 && ! command -v exportfs >/dev/null 2>&1; then
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y nfs-kernel-server >/dev/null 2>&1
fi

mkdir -p /etc/exports.d /srv/zfsbox/exports
tmp_exports=\$(mktemp)
tmp_desired=\$(mktemp)

printf '%s\\n' '/srv/zfsbox/exports *(rw,fsid=0,sync,no_subtree_check,no_root_squash,crossmnt,insecure)' > \"\${tmp_exports}\"

zfs list -H -o name,mountpoint,mounted -t filesystem -d 0 | while IFS=\$'\\t' read -r name mountpoint mounted; do
    case \"\${mountpoint}\" in
        legacy|none|-|'')
            continue
            ;;
    esac

    if [[ \"\${mounted}\" != yes ]]; then
        continue
    fi

    target=\"/srv/zfsbox/exports/\${name}\"
    mkdir -p \"\${target}\"

    if mountpoint -q \"\${target}\"; then
        current_source=\$(findmnt -n -o SOURCE --target \"\${target}\" 2>/dev/null || true)
        if [[ \"\${current_source}\" != \"\${mountpoint}\" ]]; then
            umount \"\${target}\" || true
        fi
    fi

    if ! mountpoint -q \"\${target}\"; then
        mount --bind \"\${mountpoint}\" \"\${target}\"
    fi

    printf '%s\\n' \"\${target}\" >> \"\${tmp_desired}\"
    printf '%s\\n' \"\${target} *(rw,sync,no_subtree_check,no_root_squash,insecure)\" >> \"\${tmp_exports}\"
done

find /srv/zfsbox/exports -mindepth 1 -maxdepth 1 -type d | while IFS= read -r path; do
    if ! grep -Fxq \"\${path}\" \"\${tmp_desired}\"; then
        if mountpoint -q \"\${path}\"; then
            umount \"\${path}\" || true
        fi
        rmdir \"\${path}\" 2>/dev/null || true
    fi
done

mv \"\${tmp_exports}\" /etc/exports.d/zfsbox-hostmounts.exports
rm -f \"\${tmp_desired}\"
systemctl enable --now nfs-server >/dev/null 2>&1 || systemctl enable --now nfs-kernel-server >/dev/null 2>&1 || true
exportfs -ra
"
        return 0
    fi

    guest_sudo_exec "
set -Eeuo pipefail

host_client=${host_client_q}

if command -v apt-get >/dev/null 2>&1 && ! command -v exportfs >/dev/null 2>&1; then
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y nfs-kernel-server >/dev/null 2>&1
fi

mkdir -p /etc/exports.d
tmp_file=\$(mktemp)

zfs list -H -o name,mountpoint,mounted -t filesystem -d 0 | while IFS=\$'\\t' read -r name mountpoint mounted; do
    case \"\${mountpoint}\" in
        legacy|none|-|'')
            continue
            ;;
    esac

    if [[ \"\${mounted}\" != yes ]]; then
        continue
    fi

    printf '%s %s(rw,sync,no_subtree_check,no_root_squash,insecure,crossmnt)\\n' \"\${mountpoint}\" \"\${host_client}\"
done > \"\${tmp_file}\"

mv \"\${tmp_file}\" /etc/exports.d/zfsbox-hostmounts.exports
systemctl enable --now nfs-server >/dev/null 2>&1 || true
exportfs -ra
"
}

ensure_guest_permissions() {
    local host_uid_q="$1"
    local host_gid_q="$2"

    guest_sudo_exec "
set -Eeuo pipefail

host_uid=${host_uid_q}
host_gid=${host_gid_q}

zfs list -H -o mountpoint,mounted -t filesystem | while IFS=\$'\\t' read -r mountpoint mounted; do
    case \"\${mountpoint}\" in
        legacy|none|-|'')
            continue
            ;;
    esac

    if [[ \"\${mounted}\" != yes ]]; then
        continue
    fi

    chown \"\${host_uid}:\${host_gid}\" \"\${mountpoint}\" 2>/dev/null || true
    chmod 0775 \"\${mountpoint}\" 2>/dev/null || true
done
"
}

list_root_pools() {
    guest_sudo_exec "zfs list -H -o name,mountpoint,mounted -t filesystem -d 0"
}

get_host_client_ip() {
    if [[ "${host_os}" == "Darwin" ]]; then
        guest_exec "ip route | awk '/default/ {print \$3; exit}'"
    else
        printf '%s\n' "127.0.0.1"
    fi
}

ensure_mount_target() {
    local target="$1"

    host_root_run mkdir -p "${target}"
}

is_mounted_at() {
    local target="$1"
    mount | grep -F " on ${target} " >/dev/null 2>&1
}

current_mount_source() {
    local target="$1"
    mount | awk -v target="${target}" '$2 == "on" && $3 == target { print $1; exit }'
}

ensure_host_mount_privileges() {
    if [[ "${SKIP_HOST_MOUNTS}" == "1" ]]; then
        return
    fi

    if [[ "${host_os}" == "Linux" && "${EUID}" -eq 0 ]]; then
        if ! host_has_cap_sys_admin; then
            set_mounts_unavailable "CAP_SYS_ADMIN is not available"
        fi
        return
    fi

    log "authorizing host mounts under ${host_os}"

    if ! sudo -n true 2>/dev/null; then
        if ! sudo -v; then
            set_mounts_unavailable "mount permission is not available"
        fi
    fi
}

wait_for_nfs() {
    local guest_ip="$1"

    if [[ "${host_os}" == "Darwin" ]]; then
        nc -G 2 -z "${guest_ip}" 2049 >/dev/null 2>&1
    else
        nc -w 2 -z "${guest_ip}" "${VM_NFS_PORT}" >/dev/null 2>&1
    fi
}

mount_pool() {
    local guest_ip="$1"
    local remote_mount="$2"
    local pool="$3"
    local target
    local source
    local current_source
    local mount_stderr_file
    local mount_error_text

    if [[ "${host_os}" == "Darwin" ]]; then
        target="/Volumes/${pool}"
        source="${guest_ip}:${remote_mount}"
        if [[ "${SKIP_HOST_MOUNTS}" == "1" ]]; then
            echo "dry-run mount ${source} -> ${target}" >&2
            return
        fi
        if ! wait_for_nfs "${guest_ip}"; then
            echo "Guest NFS server at ${guest_ip}:2049 is not reachable from macOS." >&2
            exit 1
        fi
        ensure_mount_target "${target}"

        if is_mounted_at "${target}"; then
            current_source="$(current_mount_source "${target}")"
            if [[ "${current_source}" == "${source}" ]]; then
                return
            fi
            host_root_run umount "${target}"
            ensure_mount_target "${target}"
        fi

        host_root_run /sbin/mount_nfs -o vers=3,tcp,nolocks "${source}" "${target}"
    else
        target="/mnt/${pool}"
        source="${guest_ip}:/${pool}"
        if [[ "${SKIP_HOST_MOUNTS}" == "1" ]]; then
            echo "dry-run mount ${source} -> ${target}" >&2
            return
        fi
        if ! command -v mount.nfs >/dev/null 2>&1 && ! command -v mount.nfs4 >/dev/null 2>&1; then
            echo "nfs-common is required for Linux host mounts." >&2
            exit 1
        fi
        if ! wait_for_nfs "${guest_ip}"; then
            echo "Guest NFS server at ${guest_ip}:${VM_NFS_PORT} is not reachable from the Linux host." >&2
            exit 1
        fi
        host_root_run mkdir -p "${target}"

        if is_mounted_at "${target}"; then
            current_source="$(current_mount_source "${target}")"
            if [[ "${current_source}" == "${source}" ]]; then
                return
            fi
            host_root_run umount "${target}" || true
            host_root_run mkdir -p "${target}"
        fi

        mount_stderr_file="$(mktemp)"
        if ! host_root_run mount -t nfs4 \
            -o "port=${VM_NFS_PORT},proto=tcp,vers=4" \
            "${source}" \
            "${target}" 2>"${mount_stderr_file}"; then
            mount_error_text="$(cat "${mount_stderr_file}")"
            rm -f "${mount_stderr_file}"

            if mount_permission_error "${mount_error_text}"; then
                set_mounts_unavailable "CAP_SYS_ADMIN is not available"
                print_mount_fallback_notice "${pool}" "${target}"
                return 0
            fi

            printf '%s\n' "${mount_error_text}" >&2
            return 1
        fi
        rm -f "${mount_stderr_file}"
    fi
}

unmount_pool_if_managed() {
    local pool="$1"
    local target

    if [[ "${host_os}" == "Darwin" ]]; then
        target="/Volumes/${pool}"
    else
        target="/mnt/${pool}"
    fi

    if [[ "${SKIP_HOST_MOUNTS}" == "1" ]]; then
        echo "dry-run unmount ${target}" >&2
        return
    fi

    if is_mounted_at "${target}"; then
        host_root_run umount "${target}" || true
    fi

    if [[ -d "${target}" ]]; then
        host_root_run rmdir "${target}" 2>/dev/null || true
    fi
}

previous_pools_file="$(mktemp)"
desired_pools_file="$(mktemp)"
trap 'rm -f "${previous_pools_file}" "${desired_pools_file}"' EXIT

if [[ -f "${managed_state_file}" ]]; then
    cp "${managed_state_file}" "${previous_pools_file}"
else
    : > "${previous_pools_file}"
fi

host_client_ip="$(get_host_client_ip | tr -d '[:space:]')"

if [[ -z "${host_client_ip}" ]]; then
    echo "Failed to determine guest or host IP for mount reconciliation." >&2
    exit 1
fi

if [[ "${host_os}" == "Darwin" ]]; then
    guest_ip="${GUEST_FIXED_IP:-192.168.64.254}"
else
    guest_ip="${LINUX_QEMU_GUEST_HOST:-127.0.0.1}"
fi

if [[ -z "${guest_ip}" ]]; then
    echo "Failed to determine guest IP for host mount reconciliation." >&2
    exit 1
fi

printf -v host_client_q '%q' "${host_client_ip}"
printf -v host_uid_q '%q' "$(id -u)"
printf -v host_gid_q '%q' "$(id -g)"
ensure_guest_exports "${host_client_q}"
ensure_guest_permissions "${host_uid_q}" "${host_gid_q}"
ensure_host_mount_privileges

pool_lines="$(list_root_pools || true)"
: > "${desired_pools_file}"

while IFS=$'\t' read -r pool mountpoint mounted; do
    [[ -n "${pool:-}" ]] || continue

    case "${mountpoint}" in
        legacy|none|-|'')
            continue
            ;;
    esac

    if [[ "${mounted}" != "yes" ]]; then
        continue
    fi

    printf '%s\n' "${pool}" >> "${desired_pools_file}"
    if [[ "${mounts_available}" -eq 1 ]]; then
        mount_pool "${guest_ip}" "${mountpoint}" "${pool}"
    else
        if [[ "${host_os}" == "Darwin" ]]; then
            print_mount_fallback_notice "${pool}" "/Volumes/${pool}"
        else
            print_mount_fallback_notice "${pool}" "/mnt/${pool}"
        fi
    fi
done <<< "${pool_lines}"

if [[ "${mounts_available}" -eq 1 ]]; then
    while IFS= read -r pool; do
        [[ -n "${pool}" ]] || continue
        if ! grep -Fxq "${pool}" "${desired_pools_file}"; then
            unmount_pool_if_managed "${pool}"
        fi
    done < "${previous_pools_file}"
fi

sort -u "${desired_pools_file}" > "${managed_state_file}"
