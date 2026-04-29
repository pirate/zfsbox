#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE_NAME="${LIMA_INSTANCE_NAME:-zfsbox-zfs}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
HOME_MOUNT="${HOME}"
VOLUMES_MOUNT="/Volumes"
STATE_ROOT_DIR="${ZFSBOX_STATE_DIR:-${PROJECT_DIR}/state}"
STATE_DIR="${STATE_ROOT_DIR}/macos-lima"
KNOWN_POOL_PATHS_FILE="${STATE_DIR}/known-pool-paths.tsv"
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

require_bool() {
    local name="$1"
    local value="$2"

    case "${value}" in
        true|false) ;;
        *)
            echo "${name} must be 'true' or 'false'; got: ${value}" >&2
            exit 1
            ;;
    esac
}

log() {
    printf 'zfsbox: %s\n' "$*" >&2
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

    parsed="$(LIMA_VM_MOUNTS_RAW="${raw_mounts}" osascript -l JavaScript 2>&1 <<'EOF'
ObjC.import('Foundation');
ObjC.import('stdlib');

const env = $.NSProcessInfo.processInfo.environment;
const raw = ObjC.unwrap(env.objectForKey('LIMA_VM_MOUNTS_RAW'));

try {
  const mounts = JSON.parse(raw);
  if (!Array.isArray(mounts)) {
    throw new Error("LIMA_VM_MOUNTS must be a JSON array of Lima mount objects");
  }

  const normalized = [];
  for (let i = 0; i < mounts.length; i += 1) {
    const mount = mounts[i];
    if (mount === null || Array.isArray(mount) || typeof mount !== "object") {
      throw new Error(`LIMA_VM_MOUNTS[${i}] must be an object`);
    }
    if (typeof mount.location !== "string" || !mount.location.startsWith("/")) {
      throw new Error(`LIMA_VM_MOUNTS[${i}].location must be an absolute host path`);
    }
    const nextMount = { ...mount };
    if (!Object.prototype.hasOwnProperty.call(nextMount, "mountPoint")) {
      nextMount.mountPoint = nextMount.location;
    } else {
      if (typeof nextMount.mountPoint !== "string" || !nextMount.mountPoint.startsWith("/")) {
        throw new Error(`LIMA_VM_MOUNTS[${i}].mountPoint must be an absolute guest path`);
      }
      if (nextMount.mountPoint !== nextMount.location) {
        throw new Error(`LIMA_VM_MOUNTS[${i}].mountPoint must match location so host paths stay valid inside zfsbox`);
      }
    }

    normalized.push(nextMount);
  }

  console.log(JSON.stringify(normalized));
  for (const mount of normalized) {
    console.log(mount.location);
  }
} catch (error) {
  console.error(String(error.message || error));
  $.exit(1);
}
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

if ! command -v limactl >/dev/null 2>&1; then
    echo "limactl is required on macOS. Install Lima first: brew install lima" >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") <command> [args...]" >&2
    exit 1
fi

require_positive_int "VM_MEMORY_MB" "${VM_MEMORY_MB}"
require_positive_int "VM_VCPUS" "${VM_VCPUS}"
require_bool "LIMA_VM_RECREATE" "${LIMA_VM_RECREATE}"

LIMA_MEMORY_GIB="$(awk -v mb="${VM_MEMORY_MB}" 'BEGIN { printf "%.6g", mb / 1024 }')"
LIMA_MEMORY_REGEX="${LIMA_MEMORY_GIB//./\\.}"

known_block_devices() {
    [[ -f "${KNOWN_POOL_PATHS_FILE}" ]] || return 0
    awk -F'\t' 'NF >= 2 && $2 ~ "^/dev/" {print $2}' "${KNOWN_POOL_PATHS_FILE}" | awk 'NF && !seen[$0]++ {print $0}'
}

collect_requested_block_devices() {
    local arg

    REQUESTED_BLOCK_DEVICES=()
    for arg in "$@"; do
        case "${arg}" in
            /dev/*)
                REQUESTED_BLOCK_DEVICES+=("${arg}")
                ;;
        esac
    done
}

load_block_device_configuration() {
    local path
    local serialized=""
    local -a combined=()

    collect_requested_block_devices "$@"

    for path in "${REQUESTED_BLOCK_DEVICES[@]}"; do
        combined+=("${path}")
    done

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        combined+=("${path}")
    done < <(known_block_devices)

    LIMA_BLOCK_DEVICES=()
    for path in "${combined[@]}"; do
        [[ -n "${path}" ]] || continue
        [[ -e "${path}" ]] || continue
        if [[ ! " ${LIMA_BLOCK_DEVICES[*]} " =~ " ${path} " ]]; then
            LIMA_BLOCK_DEVICES+=("${path}")
        fi
    done

    if (( ${#LIMA_BLOCK_DEVICES[@]} == 0 )); then
        LIMA_BLOCK_DEVICES_JSON='[]'
        return
    fi

    for path in "${LIMA_BLOCK_DEVICES[@]}"; do
        if [[ -n "${serialized}" ]]; then
            serialized+=","
        fi
        serialized+="\"$(json_escape "${path}")\""
    done
    LIMA_BLOCK_DEVICES_JSON="[${serialized}]"
}

validate_visible_paths() {
    local arg visible_root

    for arg in "$@"; do
        case "${arg}" in
            /dev/*)
                continue
                ;;
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

guest_block_device_path() {
    local host_path="$1"
    local base

    base="$(basename "${host_path}")"
    printf '/dev/disk/by-id/virtio-%s\n' "${base//[^A-Za-z0-9._-]/-}"
}

translate_guest_args() {
    local arg

    GUEST_ARGS=()
    for arg in "$@"; do
        case "${arg}" in
            /dev/*)
                GUEST_ARGS+=("$(guest_block_device_path "${arg}")")
                ;;
            *)
                GUEST_ARGS+=("${arg}")
                ;;
        esac
    done
}

lima_expected_marker() {
    cat <<EOF
LIMA_VM_MOUNTS_JSON=${LIMA_VM_MOUNTS_JSON}
LIMA_BLOCK_DEVICES_JSON=${LIMA_BLOCK_DEVICES_JSON}
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

block_device_set_expr() {
    printf '.vmOpts.vz.blockDevices = %s' "${LIMA_BLOCK_DEVICES_JSON}"
}

apply_instance_config_if_needed() {
    local needs_resource_update=0
    local needs_mount_update=0
    local edit_args=()

    if instance_needs_resource_update; then
        needs_resource_update=1
        edit_args+=(
            --cpus="${VM_VCPUS}"
            --memory="${LIMA_MEMORY_GIB}"
        )
    fi

    if instance_needs_mount_update; then
        needs_mount_update=1
        edit_args+=(
            --set
            ".mounts = ${LIMA_VM_MOUNTS_JSON}"
            --set
            "$(block_device_set_expr)"
        )
    fi

    if [[ "${#edit_args[@]}" -eq 0 ]]; then
        return
    fi

    if [[ "${needs_resource_update}" -eq 1 && "${needs_mount_update}" -eq 1 ]]; then
        log "updating Lima instance ${INSTANCE_NAME} resources, mounts, and block devices"
    elif [[ "${needs_resource_update}" -eq 1 ]]; then
        log "updating Lima instance ${INSTANCE_NAME} resources (cpus=${VM_VCPUS}, memory=${VM_MEMORY_MB}MiB)"
    else
        log "updating Lima instance ${INSTANCE_NAME} mounts and block devices"
    fi

    limactl "${LIMA_ARGS[@]}" stop "${INSTANCE_NAME}" >/dev/null 2>&1 || true
    limactl "${LIMA_ARGS[@]}" edit "${edit_args[@]}" "${INSTANCE_NAME}" >/dev/null
    write_lima_marker
}

ensure_instance() {
    if [[ "${LIMA_VM_RECREATE}" == "true" ]]; then
        log "recreating Lima instance ${INSTANCE_NAME} because LIMA_VM_RECREATE=true"
        limactl "${LIMA_ARGS[@]}" delete -f "${INSTANCE_NAME}" >/dev/null 2>&1 || true
        rm -f "${LIMA_MARKER_FILE}"
    elif [[ -f "${LIMA_CONFIG_FILE}" ]] && ! grep -Eq '^[[:space:]]*-[[:space:]]*vzNAT:[[:space:]]*true[[:space:]]*$' "${LIMA_CONFIG_FILE}"; then
        log "recreating Lima instance ${INSTANCE_NAME} with host-reachable vzNAT networking"
        limactl "${LIMA_ARGS[@]}" delete -f "${INSTANCE_NAME}" >/dev/null 2>&1 || true
        rm -f "${LIMA_MARKER_FILE}"
    fi

    if limactl list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "${INSTANCE_NAME}"; then
        apply_instance_config_if_needed
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
        --cpus="${VM_VCPUS}" \
        --memory="${LIMA_MEMORY_GIB}" \
        --set ".mounts = ${LIMA_VM_MOUNTS_JSON}" \
        --set "$(block_device_set_expr)" \
        template:default >/dev/null
    write_lima_marker
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

load_mount_configuration
load_block_device_configuration "$@"
validate_visible_paths "$@"
translate_guest_args "$@"
ensure_instance
ensure_zfs

exec limactl "${LIMA_ARGS[@]}" shell "${INSTANCE_NAME}" sudo "${GUEST_ARGS[@]}"
