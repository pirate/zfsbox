#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE_NAME="${INSTANCE_NAME:-zfsbox}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v limactl >/dev/null 2>&1; then
    echo "limactl is required on macOS. Install Lima first: brew install lima" >&2
    exit 1
fi

if limactl list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "${INSTANCE_NAME}"; then
    limactl start "${INSTANCE_NAME}" >/dev/null
else
    limactl start \
        --name="${INSTANCE_NAME}" \
        --vm-type=vz \
        --mount-writable \
        --mount="${PROJECT_DIR}" \
        --cpus=4 \
        --memory=8 \
        --disk=80 \
        --nested-virt \
        template://default >/dev/null
fi

limactl shell "${INSTANCE_NAME}" bash -lc '
set -Eeuo pipefail

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "${USER}"
  sudo systemctl enable --now docker
fi
'

quote_args() {
    local out=""
    local arg

    for arg in "$@"; do
        printf -v out '%s %q' "${out}" "${arg}"
    done

    printf '%s' "${out}"
}

if [[ $# -eq 0 ]]; then
    set -- docker compose up -d --build
fi

remote_cmd="$(quote_args "$@")"
project_dir_q="$(printf '%q' "${PROJECT_DIR}")"

limactl shell "${INSTANCE_NAME}" bash -lc "cd ${project_dir_q}; cp -n .env.example .env >/dev/null 2>&1 || true; if docker info >/dev/null 2>&1; then ${remote_cmd}; else sudo ${remote_cmd}; fi"
