#!/usr/bin/env bash

_zfsbox_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

alias zfsbox-zfs="${_zfsbox_root}/bin/zfsbox-zfs"
alias zfsbox-zpool="${_zfsbox_root}/bin/zfsbox-zpool"

zfs() {
    "${_zfsbox_root}/bin/zfsbox-zfs" "$@"
}

zpool() {
    "${_zfsbox_root}/bin/zfsbox-zpool" "$@"
}

