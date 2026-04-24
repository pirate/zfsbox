FROM ubuntu:24.04 AS guest-rootfs

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-lc"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        initramfs-tools \
        iproute2 \
        kmod \
        linux-image-virtual \
        nfs-kernel-server \
        openssh-server \
        systemd-sysv \
        udev \
        zfsutils-linux \
    && rm -rf /var/lib/apt/lists/*

COPY guest-assets/ /

RUN set -Eeuo pipefail \
    && mkdir -p \
        /etc/exports.d \
        /etc/systemd/system/basic.target.wants \
        /etc/systemd/system/multi-user.target.wants \
        /etc/systemd/system/zfsbox.target.wants \
        /root/.ssh \
        /run/sshd \
        /srv/zfsbox/exports \
    && chmod 0700 /root/.ssh \
    && chmod 0755 \
        /usr/local/sbin/zfsbox-ensure-nfs-server.sh \
        /usr/local/sbin/zfsbox-mount-hostroot.sh \
        /usr/local/sbin/zfsbox-guest-init.sh \
        /usr/local/sbin/zfsbox-init \
        /usr/local/sbin/zfsbox-sync-exports.sh \
        /usr/local/sbin/zfsbox-write-ready.sh \
    && ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/zfsbox.target.wants/systemd-networkd.service \
    && ln -sf /usr/lib/systemd/system/ssh.socket /etc/systemd/system/zfsbox.target.wants/ssh.socket \
    && ln -sf /etc/systemd/system/zfsbox-hostroot.service /etc/systemd/system/basic.target.wants/zfsbox-hostroot.service \
    && ln -sf /etc/systemd/system/zfsbox-guest-init.service /etc/systemd/system/zfsbox.target.wants/zfsbox-guest-init.service \
    && rm -f /etc/systemd/system/multi-user.target.wants/nfs-client.target \
    && rm -f /etc/systemd/system/remote-fs.target.wants/nfs-client.target \
    && rm -f /etc/systemd/system/multi-user.target.wants/nfs-server.service \
    && rm -f /etc/systemd/system/multi-user.target.wants/rpcbind.service \
    && rm -f /etc/systemd/system/sockets.target.wants/rpcbind.socket \
    && rm -f /etc/systemd/system/nfs-client.target.wants/nfs-blkmap.service \
    && truncate -s 0 /etc/machine-id \
    && rm -f /var/lib/dbus/machine-id \
    && ln -sf /dev/null /etc/systemd/system/apt-daily.service \
    && ln -sf /dev/null /etc/systemd/system/apt-daily.timer \
    && ln -sf /dev/null /etc/systemd/system/apt-daily-upgrade.service \
    && ln -sf /dev/null /etc/systemd/system/apt-daily-upgrade.timer \
    && ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service \
    && ln -sf /dev/null /etc/systemd/system/systemd-udev-settle.service \
    && ln -sf /dev/null /etc/systemd/system/zfs-import-cache.service \
    && ln -sf /dev/null /etc/systemd/system/zfs-mount.service \
    && ln -sf /dev/null /etc/systemd/system/zfs-share.service \
    && ln -sf /dev/null /etc/systemd/system/zfs-volume-wait.service \
    && ln -sf /dev/null /etc/systemd/system/zfs.target \
    && update-initramfs -c -k all

FROM ubuntu:24.04 AS seed-builder

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-lc"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        e2fsprogs \
        qemu-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/zfsbox

COPY . /opt/zfsbox
COPY --from=guest-rootfs / /tmp/guest-rootfs

RUN chmod +x /opt/zfsbox/bin/* /opt/zfsbox/scripts/*.sh \
    && rm -rf /tmp/guest-rootfs/proc/* /tmp/guest-rootfs/sys/* /tmp/guest-rootfs/dev/* /tmp/guest-rootfs/run/* \
    && mkdir -p /tmp/guest-rootfs/proc /tmp/guest-rootfs/sys /tmp/guest-rootfs/dev /tmp/guest-rootfs/run \
    && /opt/zfsbox/scripts/build-seeded-linux-qemu-image.sh \
        /tmp/guest-rootfs \
        /opt/zfsbox/image-assets/ubuntu-seeded.qcow2 \
        /opt/zfsbox/image-assets/guest-vmlinuz \
        /opt/zfsbox/image-assets/guest-initrd.img

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-lc"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        fdisk \
        git \
        iproute2 \
        netcat-openbsd \
        nfs-common \
        openssh-client \
        qemu-efi-aarch64 \
        qemu-system-arm \
        qemu-system-x86 \
        qemu-utils \
        sudo \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/zfsbox

COPY --from=seed-builder /opt/zfsbox/image-assets/ubuntu-seeded.qcow2 /opt/zfsbox/image-assets/ubuntu-seeded.qcow2
COPY --from=seed-builder /opt/zfsbox/image-assets/guest-vmlinuz /opt/zfsbox/image-assets/guest-vmlinuz
COPY --from=seed-builder /opt/zfsbox/image-assets/guest-initrd.img /opt/zfsbox/image-assets/guest-initrd.img
COPY --from=seed-builder /opt/zfsbox/image-assets/guest-rootfs.uuid /opt/zfsbox/image-assets/guest-rootfs.uuid
COPY . /opt/zfsbox

RUN chmod +x /opt/zfsbox/bin/* /opt/zfsbox/scripts/*.sh \
    && ln -sf /opt/zfsbox/bin/zfsbox-zpool /usr/local/bin/zpool \
    && ln -sf /opt/zfsbox/bin/zfsbox-zfs /usr/local/bin/zfs

ENV PATH="/opt/zfsbox/bin:${PATH}"
ENV ZFSBOX_STATE_DIR="/data/.zfsbox/state"
WORKDIR /data

ENTRYPOINT ["/opt/zfsbox/scripts/docker-entrypoint.sh"]
CMD ["/bin/bash"]
