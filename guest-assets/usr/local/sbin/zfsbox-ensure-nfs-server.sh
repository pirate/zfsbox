#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf 'zfsbox-nfs: %s\n' "$*" >&2
}

mkdir -p /proc/fs/nfsd /run/rpcbind /run/sendsigs.omit.d /var/lib/nfs/rpc_pipefs /var/lib/nfs/v4recovery /etc/exports.d

mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /run || mount -t tmpfs tmpfs /run
mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd
mountpoint -q /var/lib/nfs/rpc_pipefs || mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs

if command -v rpcbind >/dev/null 2>&1; then
    pgrep -x rpcbind >/dev/null 2>&1 || rpcbind -w
fi

modprobe nfsd >/dev/null 2>&1 || true

if ! ss -ltn 2>/dev/null | grep -q '[.:]2049[[:space:]]'; then
    rpc.nfsd --no-udp 8 >/run/zfsbox-rpc.nfsd.log 2>&1 || true
fi

if command -v rpc.mountd >/dev/null 2>&1; then
    if ! pgrep -x rpc.mountd >/dev/null 2>&1; then
        nohup rpc.mountd --no-udp --manage-gids \
            >/run/zfsbox-rpc.mountd.log 2>&1 &
    fi
fi

exportfs -ra

for _ in $(seq 1 50); do
    if ss -ltn 2>/dev/null | grep -q '[.:]2049[[:space:]]'; then
        exit 0
    fi
    sleep 0.1
done

log "NFS server did not open port 2049"
if [[ -f /run/zfsbox-rpc.nfsd.log ]]; then
    tail -n 20 /run/zfsbox-rpc.nfsd.log >&2 || true
fi
if [[ -f /run/zfsbox-rpc.mountd.log ]]; then
    tail -n 20 /run/zfsbox-rpc.mountd.log >&2 || true
fi
exit 1
