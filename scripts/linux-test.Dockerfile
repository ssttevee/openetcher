# Linux environment for scripts/test-targets.sh.
#
# `zig build test` executes foreign-architecture binaries through qemu-user
# and Windows binaries through Wine, but only on a Linux host. This image
# provides that host: a Linux Zig, qemu-user for the cross targets, Wine for
# Windows binaries of the image's own architecture, and bzip2 for the codec
# tests. Debian packages Wine for arm64, which Alpine does not.

FROM debian:trixie-slim

ARG TARGETARCH
ARG ZIG_VERSION=0.17.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends bzip2 ca-certificates curl qemu-user wine xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Checksums from https://ziglang.org/download/index.json.
RUN case "$TARGETARCH" in \
        amd64) arch=x86_64 sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;; \
        arm64) arch=aarch64 sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz" \
    && echo "$sum  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ENV PATH=/opt/zig:$PATH

# Create the Wine prefix once here: test binaries run in parallel, and two
# of them initializing a fresh prefix at the same time fail.
ENV WINEPREFIX=/opt/wine WINEDEBUG=-all XDG_RUNTIME_DIR=/run/user/0
RUN mkdir -p -m 700 /run/user/0 && wineboot --init && wineserver --wait
