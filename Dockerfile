# syntax=docker/dockerfile:1
FROM alpine:3.22 AS build

ARG ZIG_VERSION=0.16.0
ENV ZIG_GLOBAL_CACHE_DIR=/zig-cache/global \
    ZIG_LOCAL_CACHE_DIR=/zig-cache/local

RUN apk add --no-cache \
        curl tar xz \
        build-base linux-headers gcompat pkgconf \
        openssl-dev

RUN --mount=type=cache,id=teknap-zig-dist,target=/var/cache/zig-dist \
    set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) zarch=x86_64 ;; \
        aarch64) zarch=aarch64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    tarball="/var/cache/zig-dist/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz"; \
    if [ ! -s "$tarball" ]; then \
        curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" \
            -o "$tarball"; \
    fi; \
    mkdir -p /opt/zig; \
    tar -xJf "$tarball" -C /opt/zig --strip-components=1

WORKDIR /src
COPY build.zig build.zig.zon ./
RUN --mount=type=cache,id=teknap-zig-global,target=/zig-cache/global \
    --mount=type=cache,id=teknap-zig-local,target=/zig-cache/local \
    /opt/zig/zig build --fetch

COPY src ./src
ARG ZIG_TARGET=
ARG BUILD_ID=dev
RUN --mount=type=cache,id=teknap-zig-global,target=/zig-cache/global \
    --mount=type=cache,id=teknap-zig-local,target=/zig-cache/local \
    set -eux; \
    if [ -n "$ZIG_TARGET" ]; then ztarget="$ZIG_TARGET"; \
    else \
        case "$(uname -m)" in \
            x86_64) ztarget=x86_64-linux-musl ;; \
            aarch64) ztarget=aarch64-linux-musl ;; \
            *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
        esac; \
    fi; \
    /opt/zig/zig build -Doptimize=ReleaseSafe -Dtarget="$ztarget" -Dcpu=baseline; \
    mkdir -p /export; \
    cp /src/zig-out/bin/teknap /export/; \
    echo "$BUILD_ID $ztarget baseline" > /export/build-id

FROM alpine:3.22

RUN apk add --no-cache libssl3 ca-certificates gnupg

COPY --from=build /export/teknap /usr/local/bin/teknap
COPY --from=build /export/build-id /usr/local/share/teknap-build-id

ENTRYPOINT ["teknap"]
