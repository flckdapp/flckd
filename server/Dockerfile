FROM oven/bun:1.3.11 AS web
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY frontend/ frontend/
COPY shared/ shared/
COPY vite.config.ts tsconfig.json ./
RUN bun run build && bun install --frozen-lockfile --production

FROM ghcr.io/valhalla/valhalla:3.6.3
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    osmium-tool python3-pyosmium python3-shapely curl ca-certificates jq \
    coreutils unzip tini util-linux \
    && rm -rf /var/lib/apt/lists/*

# Not the distro rclone. Ubuntu 24.04 ships 1.60, which always sends
# x-amz-acl; Cloudflare R2 does not implement that header on PutObject and
# now rejects it with 501 instead of ignoring it, so every upload fails.
ARG TARGETARCH
ARG RCLONE_VERSION=v1.75.1
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) sha=982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab ;; \
      arm64) sha=03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9 ;; \
      *) echo "no rclone build for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/rclone.zip \
      "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-${TARGETARCH}.zip"; \
    echo "${sha}  /tmp/rclone.zip" | sha256sum -c -; \
    unzip -j /tmp/rclone.zip "*/rclone" -d /usr/local/bin; \
    chmod +x /usr/local/bin/rclone; \
    rm /tmp/rclone.zip; \
    rclone version | head -1
COPY --from=web /usr/local/bin/bun /usr/local/bin/bun
WORKDIR /opt/flckd
COPY --from=web /app/node_modules ./node_modules
COPY --from=web /app/dist ./frontend
COPY backend/ ./backend/
COPY shared/ ./shared/
COPY builder/bin/ ./bin/
COPY builder/lib/ ./lib/
COPY builder/regions/ ./regions/
COPY origin/www/ ./site/
COPY runtime/ ./runtime/
RUN chmod +x bin/*.sh bin/*.py runtime/*.sh \
    && mkdir -p /data /site \
    && chown -R 568:568 /data /site
ENV PATH="/opt/flckd/bin:/usr/lib/python3-pyosmium:${PATH}" \
    DATA_DIR=/data DOCROOT=/site BUILDER_BIND=0.0.0.0
EXPOSE 8642 8080
USER 568:568
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/flckd/runtime/start.sh"]
CMD ["serve"]
