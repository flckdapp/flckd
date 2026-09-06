# FLCKD tile builder.
#
# Pinned to Valhalla 3.6.3 because rallista/valhalla-mobile 0.6.3 embeds
# valhalla submodule SHA e2f017b == upstream tag 3.6.3 exactly. Valhalla tiles
# are mmapped binary structs; the reader and the writer must agree on layout.
# Do not float this to :latest. See server/README.md.
FROM ghcr.io/valhalla/valhalla:3.6.3

# The base image ships the valhalla_* binaries but not the OSM clipping tools
# or the replication client used to keep the PBF current.
#   osmium-tool      -> osmium extract / merge  (clip PBFs by .poly)
#   python3-pyosmium -> pyosmium-up-to-date     (apply Geofabrik daily diffs)
#   rclone           -> push-r2.sh               (publish to Cloudflare R2)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        osmium-tool \
        python3-pyosmium \
        python3-shapely \
        curl \
        ca-certificates \
        jq \
        coreutils \
        rclone \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /data
COPY bin/  /opt/flckd/bin/
COPY lib/  /opt/flckd/lib/
COPY regions/ /opt/flckd/regions/
RUN chmod +x /opt/flckd/bin/*.sh /opt/flckd/bin/*.py

# Ubuntu 24.04's python3-pyosmium ships its CLI tools (pyosmium-up-to-date,
# pyosmium-get-changes) in /usr/lib/python3-pyosmium, not on PATH.
ENV PATH="/opt/flckd/bin:/usr/lib/python3-pyosmium:${PATH}"
ENTRYPOINT ["/bin/bash"]
