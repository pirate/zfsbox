#!/usr/bin/env bash
set -Eeuo pipefail

host_uid="${1:-0}"
host_gid="${2:-0}"

mkdir -p /etc/exports.d /srv/zfsbox/exports

tmp_exports="$(mktemp)"
tmp_desired="$(mktemp)"
tmp_lines="$(mktemp)"

printf '%s\n' '/srv/zfsbox/exports *(rw,fsid=0,sync,no_subtree_check,no_root_squash,crossmnt,insecure)' > "${tmp_exports}"

zfs list -H -o name,mountpoint,mounted -t filesystem -d 0 | while IFS=$'\t' read -r name mountpoint mounted; do
    case "${mountpoint}" in
        legacy|none|-|'')
            continue
            ;;
    esac

    if [[ "${mounted}" != "yes" ]]; then
        continue
    fi

    chown "${host_uid}:${host_gid}" "${mountpoint}" 2>/dev/null || true
    chmod 0775 "${mountpoint}" 2>/dev/null || true

    target="/srv/zfsbox/exports/${name}"
    mkdir -p "${target}"

    if ! mountpoint -q "${target}"; then
        mount --bind "${mountpoint}" "${target}"
    fi

    printf '%s\n' "${target}" >> "${tmp_desired}"
    printf '%s\t%s\t%s\n' "${name}" "${mountpoint}" "${mounted}" >> "${tmp_lines}"
    printf '%s\n' "${target} *(rw,sync,no_subtree_check,no_root_squash,insecure)" >> "${tmp_exports}"
done

find /srv/zfsbox/exports -mindepth 1 -maxdepth 1 -type d | while IFS= read -r path; do
    if ! grep -Fxq "${path}" "${tmp_desired}" 2>/dev/null; then
        if mountpoint -q "${path}"; then
            umount "${path}" || true
        fi
        rmdir "${path}" 2>/dev/null || true
    fi
done

mv "${tmp_exports}" /etc/exports.d/zfsbox-hostmounts.exports
/usr/local/sbin/zfsbox-ensure-nfs-server.sh
exportfs -ra
cat "${tmp_lines}"
rm -f "${tmp_desired}" "${tmp_lines}"
