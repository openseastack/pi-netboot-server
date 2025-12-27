# Build stage - compile unfs3
FROM debian:stable-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    flex \
    bison \
    git \
    autoconf \
    automake \
    libtool \
    pkg-config \
    libtirpc-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build unfs3 from source
WORKDIR /tmp
RUN git clone https://github.com/unfs3/unfs3.git && \
    cd unfs3 && \
    ./bootstrap && \
    ./configure && \
    make && \
    make install && \
    cd .. && \
    rm -rf unfs3

# Runtime stage
FROM debian:stable-slim

LABEL maintainer="OpenSeaStack"
LABEL description="Raspberry Pi Netboot Development Server (Debian Slim)"

ENV DEBIAN_FRONTEND=noninteractive

# Install only runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    rpcbind \
    iproute2 \
    net-tools \
    curl \
    rsync \
    python3 \
    python3-pip \
    python3-flask \
    python3-requests \
    libtirpc3 \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages not in Debian repos
RUN pip3 install --break-system-packages --no-cache-dir \
    flask-cors \
    paramiko

# Copy built unfs3 from builder stage
COPY --from=builder /usr/local/sbin/unfsd /usr/local/sbin/unfsd

# Create directories for NFS and TFTP
RUN mkdir -p /nfs/rootfs /tftpboot /var/log/netboot /images

# Copy configuration templates  
COPY docker/configs/dnsmasq.conf /etc/dnsmasq.conf.template
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy Web UI
COPY webui /webui

# Copy pi-service for bootstrap endpoints
COPY pi-service /pi-service

# Expose ports:
# 67/udp  - DHCP
# 69/udp  - TFTP  
# 111     - RPC portmapper
# 2049    - NFS
# 38434   - Web UI
EXPOSE 67/udp 69/udp 111 2049 38434

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep dnsmasq && pgrep rpc.nfsd || exit 1

ENTRYPOINT ["/entrypoint.sh"]
