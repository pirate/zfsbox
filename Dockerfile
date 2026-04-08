FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        debootstrap \
        e2fsprogs \
        file \
        iproute2 \
        iptables \
        jq \
        kmod \
        mount \
        nfs-common \
        openssh-client \
        procps \
        rsync \
        sudo \
        tini \
        util-linux \
        wget \
        xz-utils \
        zstd \
    && rm -rf /var/lib/apt/lists/*

COPY scripts /opt/zfsbox/scripts

RUN chmod +x /opt/zfsbox/scripts/*.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/zfsbox/scripts/entrypoint.sh"]

