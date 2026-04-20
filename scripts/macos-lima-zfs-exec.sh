#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE_NAME="${LIMA_INSTANCE_NAME:-zfsbox-zfs}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
HOME_MOUNT="${HOME}"
VOLUMES_MOUNT="/Volumes"
LIMA_ARGS=(--log-level=error -y)
LIMA_CONFIG_FILE="${HOME}/.lima/${INSTANCE_NAME}/lima.yaml"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

VM_MEMORY_MB="${VM_MEMORY_MB:-2048}"
VM_VCPUS="${VM_VCPUS:-2}"

require_positive_int() {
    local name="$1"
    local value="$2"

    if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        echo "${name} must be a positive integer; got: ${value}" >&2
        exit 1
    fi
}

require_positive_int "VM_MEMORY_MB" "${VM_MEMORY_MB}"
require_positive_int "VM_VCPUS" "${VM_VCPUS}"

LIMA_MEMORY_GIB="$(awk -v mb="${VM_MEMORY_MB}" 'BEGIN { printf "%.6g", mb / 1024 }')"
LIMA_MEMORY_REGEX="${LIMA_MEMORY_GIB//./\\.}"

log() {
    printf 'zfsbox: %s\n' "$*" >&2
}

if ! command -v limactl >/dev/null 2>&1; then
    echo "limactl is required on macOS. Install Lima first: brew install lima" >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") <command> [args...]" >&2
    exit 1
fi

validate_visible_paths() {
    local arg

    for arg in "$@"; do
        case "${arg}" in
            /*)
                if [[ "${arg}" != "${HOME_MOUNT}"* && "${arg}" != "${VOLUMES_MOUNT}"* ]]; then
                    echo "Absolute path ${arg} is not visible inside the Lima guest. Use a path under ${HOME_MOUNT} or ${VOLUMES_MOUNT}." >&2
                    exit 1
                fi
                ;;
        esac
    done
}

instance_needs_resource_update() {
    [[ -f "${LIMA_CONFIG_FILE}" ]] || return 1

    if ! grep -Eq "^[[:space:]]*cpus:[[:space:]]*${VM_VCPUS}[[:space:]]*$" "${LIMA_CONFIG_FILE}"; then
        return 0
    fi

    if ! grep -Eq "^[[:space:]]*memory:[[:space:]]*\"?${LIMA_MEMORY_REGEX}(GiB)?\"?[[:space:]]*$" "${LIMA_CONFIG_FILE}"; then
        return 0
    fi

    return 1
}

update_instance_resources_if_needed() {
    if ! instance_needs_resource_update; then
        return
    fi

    log "updating Lima instance ${INSTANCE_NAME} resources (cpus=${VM_VCPUS}, memory=${VM_MEMORY_MB}MiB)"
    limactl "${LIMA_ARGS[@]}" stop "${INSTANCE_NAME}" >/dev/null 2>&1 || true
    limactl "${LIMA_ARGS[@]}" edit \
        --cpus="${VM_VCPUS}" \
        --memory="${LIMA_MEMORY_GIB}" \
        "${INSTANCE_NAME}" >/dev/null
}

ensure_instance() {
    if [[ -f "${LIMA_CONFIG_FILE}" ]] && ! grep -Eq '^[[:space:]]*-[[:space:]]*vzNAT:[[:space:]]*true[[:space:]]*$' "${LIMA_CONFIG_FILE}"; then
        log "recreating Lima instance ${INSTANCE_NAME} with host-reachable vzNAT networking"
        limactl "${LIMA_ARGS[@]}" delete -f "${INSTANCE_NAME}" >/dev/null 2>&1 || true
    fi

    if limactl list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "${INSTANCE_NAME}"; then
        update_instance_resources_if_needed
        log "starting Lima instance ${INSTANCE_NAME}"
        limactl "${LIMA_ARGS[@]}" start "${INSTANCE_NAME}" >/dev/null 2>&1 || true
        return
    fi

    log "creating Lima instance ${INSTANCE_NAME}"
    limactl "${LIMA_ARGS[@]}" start \
        --name="${INSTANCE_NAME}" \
        --vm-type=vz \
        --network=vzNAT \
        --containerd=none \
        --mount-type=virtiofs \
        --mount-writable \
        --mount-only="${HOME_MOUNT}" \
        --mount-only="${VOLUMES_MOUNT}" \
        --cpus="${VM_VCPUS}" \
        --memory="${LIMA_MEMORY_GIB}" \
        template:default >/dev/null
}

ensure_zfs() {
    log "ensuring ZFS tooling is installed in the Lima guest"
    limactl "${LIMA_ARGS[@]}" shell "${INSTANCE_NAME}" bash -lc '
set -Eeuo pipefail

if ! command -v zpool >/dev/null 2>&1; then
    sudo env NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y zfsutils-linux >/dev/null 2>&1
fi

if ! command -v exportfs >/dev/null 2>&1; then
    sudo env NEEDRESTART_MODE=a apt-get update >/dev/null 2>&1
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y nfs-kernel-server >/dev/null 2>&1
fi

sudo modprobe zfs >/dev/null 2>&1 || true
' >/dev/null
}

validate_visible_paths "$@"
ensure_instance
ensure_zfs

exec limactl "${LIMA_ARGS[@]}" shell "${INSTANCE_NAME}" sudo "$@"
