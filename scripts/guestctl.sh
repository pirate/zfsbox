#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/state}"
SHARE_ROOT="${STATE_DIR}/mnt/share"
CTL_DIR="${SHARE_ROOT}/.zfsbox-ctl"
REQUESTS_DIR="${CTL_DIR}/requests"
RESPONSES_DIR="${CTL_DIR}/responses"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"

usage() {
    echo "Usage: guestctl.sh wait-ready | exec <command> [args...]" >&2
    exit 1
}

wait_ready() {
    local waited=0

    while (( waited < TIMEOUT_SECONDS )); do
        if [[ -f "${CTL_DIR}/agent.ready" ]]; then
            return 0
        fi

        sleep 1
        ((waited += 1))
    done

    echo "Guest command agent did not become ready within ${TIMEOUT_SECONDS}s." >&2
    return 1
}

exec_command() {
    local request_id request_dir response_dir index file status waited

    [[ $# -gt 0 ]] || usage
    wait_ready

    request_id="$(date +%s%N)-$$-${RANDOM}"
    request_dir="${REQUESTS_DIR}/${request_id}"
    response_dir="${RESPONSES_DIR}/${request_id}"

    mkdir -p "${request_dir}/argv" "${RESPONSES_DIR}"

    index=0
    for arg in "$@"; do
        printf -v file '%s/argv/%04d' "${request_dir}" "${index}"
        printf '%s' "${arg}" > "${file}"
        ((index += 1))
    done

    waited=0
    while (( waited < TIMEOUT_SECONDS )); do
        if [[ -f "${response_dir}/done" ]]; then
            [[ -f "${response_dir}/stdout" ]] && cat "${response_dir}/stdout"
            [[ -f "${response_dir}/stderr" ]] && cat "${response_dir}/stderr" >&2
            status="$(cat "${response_dir}/exit_code" 2>/dev/null || printf '1')"
            rm -rf "${request_dir}" "${response_dir}"
            exit "${status}"
        fi

        sleep 1
        ((waited += 1))
    done

    rm -rf "${request_dir}" "${response_dir}"
    echo "Timed out waiting for guest command response." >&2
    exit 1
}

action="${1:-}"
shift || true

case "${action}" in
    wait-ready)
        wait_ready
        ;;
    exec)
        exec_command "$@"
        ;;
    *)
        usage
        ;;
esac
