# syntax=docker/dockerfile:1.7
# Flutter's Linux x64 toolchain is intentional, even on ARM builders (QEMU).
# Browser output is architecture independent; runtime uses --platform from buildx.
FROM --platform=linux/amd64 ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS builder
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:$PATH \
    PUB_CACHE=/root/.pub-cache
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils python3 libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch 3.47.5 https://github.com/flutter/flutter.git /opt/flutter \
    && test "$(git -C /opt/flutter rev-parse HEAD)" = "6a19cca56475dbfba1478ee68d7bd0c2ef891da1" \
    && flutter config --no-analytics \
    && flutter precache --web
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN --mount=type=cache,id=finance-pub-3.47.5,target=/root/.pub-cache \
    flutter pub get --enforce-lockfile
COPY lib/ lib/
COPY web/ web/
COPY assets/ assets/
COPY deploy/validate_client_config.py deploy/flutter_service_worker.js deploy/
# Secret mounts do not invalidate the cache: the caller MUST pass the file hash.
ARG CLIENT_CONFIG_SHA256
RUN --mount=type=cache,id=finance-pub-3.47.5,target=/root/.pub-cache \
    --mount=type=secret,id=client_config,required=true \
    python3 deploy/validate_client_config.py /run/secrets/client_config "$CLIENT_CONFIG_SHA256" \
    && flutter build web --release --no-pub --no-web-resources-cdn \
       --pwa-strategy=none --dart-define-from-file=/run/secrets/client_config \
    && cp deploy/flutter_service_worker.js build/web/flutter_service_worker.js \
    && find build/web -type f -name '*.map' -delete

FROM caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d AS runtime
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=builder /app/build/web/ /srv/
EXPOSE 80/tcp 443/tcp
# BusyBox sh, test and wget are present in this Alpine-based image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD test -s /srv/index.html && test -s /srv/main.dart.js && \
        wget -q -O /dev/null http://127.0.0.1:8081/healthz || exit 1
