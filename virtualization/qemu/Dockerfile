FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      cloud-image-utils \
      curl \
      qemu-efi-aarch64 \
      qemu-system-arm \
      qemu-utils \
      socat \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/franzfon-vm-entrypoint
COPY labctl.sh /usr/local/bin/labctl
COPY cloud-init /opt/franzfon-lab/cloud-init

RUN chmod 0755 /usr/local/bin/franzfon-vm-entrypoint /usr/local/bin/labctl

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/franzfon-vm-entrypoint"]
