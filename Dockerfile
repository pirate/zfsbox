FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG GUEST_RELEASE=noble
ARG TARGETARCH
ARG TARGETPLATFORM

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        cloud-image-utils \
        curl \
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

RUN mkdir -p /opt/zfsbox/image-assets \
    && case "${TARGETARCH}" in \
        amd64) guest_arch=amd64 ;; \
        arm64) guest_arch=arm64 ;; \
        *) echo "Unsupported Docker target architecture: ${TARGETARCH} (${TARGETPLATFORM})" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://cloud-images.ubuntu.com/${GUEST_RELEASE}/current/${GUEST_RELEASE}-server-cloudimg-${guest_arch}.img" \
        -o /opt/zfsbox/image-assets/ubuntu-cloudimg.qcow2

COPY . /opt/zfsbox

RUN chmod +x /opt/zfsbox/bin/* /opt/zfsbox/scripts/*.sh \
    && ln -sf /opt/zfsbox/bin/zfsbox-zpool /usr/local/bin/zpool \
    && ln -sf /opt/zfsbox/bin/zfsbox-zfs /usr/local/bin/zfs

ENV PATH="/opt/zfsbox/bin:${PATH}"
ENV ZFSBOX_STATE_DIR="/data/.zfsbox/state"
WORKDIR /data

ENTRYPOINT ["/opt/zfsbox/scripts/docker-entrypoint.sh"]
CMD ["/bin/bash"]
