#!/usr/bin/env bash
set -Eeuo pipefail

SHARE_EXPORT="${SHARE_EXPORT:-/tank/share}"

/opt/zfsbox/scripts/guestctl.sh wait-ready
/opt/zfsbox/scripts/guestctl.sh exec sh -lc "printf '%s\n' 'zfsbox ready' > '${SHARE_EXPORT}/.zfsbox-ready'"
