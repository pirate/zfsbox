#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE_NAME="${LIMA_INSTANCE_NAME:-zfsbox-zfs}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
HOME_MOUNT="${HOME}"
VOLUMES_MOUNT="/Volumes"
STATE_ROOT_DIR="${ZFSBOX_STATE_DIR:-${PROJECT_DIR}/state}"
STATE_DIR="${STATE_ROOT_DIR}/macos-lima"
LIMA_ARGS=(--log-level=error -y)
LIMA_CONFIG_FILE="${HOME}/.lima/${INSTANCE_NAME}/lima.yaml"
LIMA_MARKER_FILE="${STATE_DIR}/${INSTANCE_NAME}.marker"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

VM_MEMORY_MB="${VM_MEMORY_MB:-2048}"
VM_VCPUS="${VM_VCPUS:-2}"
LIMA_VM_RECREATE="${LIMA_VM_RECREATE:-false}"
LIMA_VM_MOUNTS="${LIMA_VM_MOUNTS:-}"

mkdir -p "${STATE_DIR}"

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

require_bool() {
    local name="$1"
    local value="$2"

    case "${value}" in
        true|false)
            ;;
        *)
            echo "${name} must be 'true' or 'false'; got: ${value}" >&2
            exit 1
            ;;
    esac
}

require_bool "LIMA_VM_RECREATE" "${LIMA_VM_RECREATE}"

LIMA_MEMORY_GIB="$(awk -v mb="${VM_MEMORY_MB}" 'BEGIN { printf "%.6g", mb / 1024 }')"
LIMA_MEMORY_REGEX="${LIMA_MEMORY_GIB//./\\.}"

log() {
    printf 'zfsbox: %s\n' "$*" >&2
}

resolve_limactl() {
    if command -v limactl >/dev/null 2>&1; then
        LIMACTL_CMD="$(command -v limactl)"
        return
    fi

    echo "limactl is required on macOS and must be available in PATH." >&2
    exit 1
}

run_limactl() {
    "${LIMACTL_CMD}" "$@"
}

json_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "${value}"
}

default_lima_vm_mounts_json() {
    printf '[{"location":"%s","mountPoint":"%s","writable":true},{"location":"%s","mountPoint":"%s","writable":true}]' \
        "$(json_escape "${HOME_MOUNT}")" \
        "$(json_escape "${HOME_MOUNT}")" \
        "$(json_escape "${VOLUMES_MOUNT}")" \
        "$(json_escape "${VOLUMES_MOUNT}")"
}

load_mount_configuration() {
    local raw_mounts parsed line line_no normalized

    if [[ -n "${LIMA_VM_MOUNTS}" ]]; then
        raw_mounts="${LIMA_VM_MOUNTS}"
    else
        raw_mounts="$(default_lima_vm_mounts_json)"
    fi

    parsed="$(LIMA_VM_MOUNTS_RAW="${raw_mounts}" python3 - <<'EOF'
import json
import os
import sys

raw = os.environ["LIMA_VM_MOUNTS_RAW"]

try:
    mounts = json.loads(raw)
    if not isinstance(mounts, list):
        raise ValueError("LIMA_VM_MOUNTS must be a JSON array of Lima mount objects")

    normalized = []
    for i, mount in enumerate(mounts):
        if not isinstance(mount, dict):
            raise ValueError(f"LIMA_VM_MOUNTS[{i}] must be an object")

        location = mount.get("location")
        if not isinstance(location, str) or not location.startswith("/"):
            raise ValueError(f"LIMA_VM_MOUNTS[{i}].location must be an absolute host path")

        next_mount = dict(mount)
        mount_point = next_mount.get("mountPoint", location)
        if not isinstance(mount_point, str) or not mount_point.startswith("/"):
            raise ValueError(f"LIMA_VM_MOUNTS[{i}].mountPoint must be an absolute guest path")
        if mount_point != location:
            raise ValueError(
                f"LIMA_VM_MOUNTS[{i}].mountPoint must match location so host paths stay valid inside zfsbox"
            )

        next_mount["mountPoint"] = mount_point
        normalized.append(next_mount)

    print(json.dumps(normalized, separators=(",", ":")))
    for mount in normalized:
        print(mount["location"])
except Exception as exc:  # noqa: BLE001
    print(str(exc), file=sys.stderr)
    sys.exit(1)
EOF
)" || exit 1

    LIMA_ALLOWED_PATHS=()
    line_no=0
    while IFS= read -r line; do
        if [[ "${line_no}" -eq 0 ]]; then
            LIMA_VM_MOUNTS_JSON="${line}"
        elif [[ -n "${line}" ]]; then
            normalized="${line%/}"
            if [[ -z "${normalized}" ]]; then
                normalized="/"
            fi
            LIMA_ALLOWED_PATHS+=("${normalized}")
        fi
        line_no=$((line_no + 1))
    done <<< "${parsed}"
}

build_lima_mount_flags() {
    LIMA_MOUNT_FLAGS=(--mount-writable)
    local visible_root

    for visible_root in "${LIMA_ALLOWED_PATHS[@]}"; do
        LIMA_MOUNT_FLAGS+=(--mount-only "${visible_root}")
    done
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") <command> [args...]" >&2
    exit 1
fi

validate_visible_paths() {
    local arg visible_root

    for arg in "$@"; do
        case "${arg}" in
            /*)
                visible_root=""
                for visible_root in "${LIMA_ALLOWED_PATHS[@]}"; do
                    if [[ "${visible_root}" == "/" || "${arg}" == "${visible_root}" || "${arg}" == "${visible_root}/"* ]]; then
                        break
                    fi
                    visible_root=""
                done

                if [[ -z "${visible_root}" ]]; then
                    echo "Absolute path ${arg} is not visible inside the Lima guest. Update LIMA_VM_MOUNTS to include its host path." >&2
                    exit 1
                fi
                ;;
        esac
    done
}

lima_expected_marker() {
    cat <<EOF
LIMA_VM_MOUNTS_JSON=${LIMA_VM_MOUNTS_JSON}
EOF
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

instance_needs_mount_update() {
    local expected current

    expected="$(lima_expected_marker)"
    current="$(cat "${LIMA_MARKER_FILE}" 2>/dev/null || true)"
    [[ "${current}" != "${expected}" ]]
}

write_lima_marker() {
    printf '%s\n' "$(lima_expected_marker)" > "${LIMA_MARKER_FILE}"
}

apply_instance_config_if_needed() {
    local needs_resource_update=0
    local edit_args=()

    if instance_needs_resource_update; then
        needs_resource_update=1
        edit_args+=(
            --cpus="${VM_VCPUS}"
            --memory="${LIMA_MEMORY_GIB}"
        )
    fi

    if instance_needs_mount_update; then
        log "recreating Lima instance ${INSTANCE_NAME} because mount configuration changed"
        run_limactl "${LIMA_ARGS[@]}" delete -f "${INSTANCE_NAME}" >/dev/null 2>&1 || true
        rm -f "${LIMA_MARKER_FILE}"
        ensure_instance
        return
    fi

    if [[ "${#edit_args[@]}" -eq 0 ]]; then
        return
    fi

    if [[ "${needs_resource_update}" -eq 1 ]]; then
        log "updating Lima instance ${INSTANCE_NAME} resources (cpus=${VM_VCPUS}, memory=${VM_MEMORY_MB}MiB)"
    fi

    run_limactl "${LIMA_ARGS[@]}" stop "${INSTANCE_NAME}" >/dev/null 2>&1 || true
    run_limactl "${LIMA_ARGS[@]}" edit "${edit_args[@]}" "${INSTANCE_NAME}" >/dev/null
    write_lima_marker
}

ensure_instance() {
    if [[ "${LIMA_VM_RECREATE}" == "true" ]]; then
        log "recreating Lima instance ${INSTANCE_NAME} because LIMA_VM_RECREATE=true"
        run_limactl "${LIMA_ARGS[@]}" delete -f "${INSTANCE_NAME}" >/dev/null 2>&1 || true
        rm -f "${LIMA_MARKER_FILE}"
    elif [[ -f "${LIMA_CONFIG_FILE}" ]] && ! grep -Eq '^[[:space:]]*-[[:space:]]*vzNAT:[[:space:]]*true[[:space:]]*$' "${LIMA_CONFIG_FILE}"; then
        log "recreating Lima instance ${INSTANCE_NAME} with host-reachable vzNAT networking"
        run_limactl "${LIMA_ARGS[@]}" delete -f "${INSTANCE_NAME}" >/dev/null 2>&1 || true
        rm -f "${LIMA_MARKER_FILE}"
    fi

    if run_limactl list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "${INSTANCE_NAME}"; then
        apply_instance_config_if_needed
        log "starting Lima instance ${INSTANCE_NAME}"
        run_limactl "${LIMA_ARGS[@]}" start "${INSTANCE_NAME}" >/dev/null 2>&1 || true
        return
    fi

    log "creating Lima instance ${INSTANCE_NAME}"
    run_limactl "${LIMA_ARGS[@]}" start \
        --name="${INSTANCE_NAME}" \
        --vm-type=vz \
        --network=vzNAT \
        --containerd=none \
        --mount-type=virtiofs \
        --cpus="${VM_VCPUS}" \
        --memory="${LIMA_MEMORY_GIB}" \
        "${LIMA_MOUNT_FLAGS[@]}" \
        template:default >/dev/null
    write_lima_marker
}

ensure_zfs() {
    log "ensuring ZFS tooling is installed in the Lima guest"
    run_limactl "${LIMA_ARGS[@]}" shell "${INSTANCE_NAME}" bash -lc '
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

resolve_limactl
load_mount_configuration
build_lima_mount_flags
validate_visible_paths "$@"
ensure_instance
ensure_zfs

exec "${LIMACTL_CMD}" "${LIMA_ARGS[@]}" shell "${INSTANCE_NAME}" sudo "$@"
