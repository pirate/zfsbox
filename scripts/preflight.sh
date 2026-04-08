#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "zfsbox requires a Linux runtime with KVM access." >&2
    exit 1
fi

if [[ ! -e /dev/kvm ]]; then
    echo "Missing /dev/kvm. Run this on a Linux host or inside Lima with nested virtualization enabled." >&2
    exit 1
fi

if [[ ! -e /dev/net/tun ]]; then
    echo "Missing /dev/net/tun. The container needs TAP support." >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1 && [[ -n "${INSIDE_LIMA:-}" ]]; then
    echo "Docker is not installed inside the Lima VM." >&2
    exit 1
fi

