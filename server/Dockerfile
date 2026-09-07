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
    coreutils rclone tini util-linux \
    && rm -rf /var/lib/apt/lists/*
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
