ARG JAC_VERSION=0.37.25
FROM jaseci/jaclang:${JAC_VERSION}

# The image ships the toolchain and the embedded graph database. curl backs the
# container healthcheck.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first, so a code-only change reuses this layer.
COPY jac.toml jac.lock ./
RUN jac install

COPY . .

# Seal the application here, at build time. Starting from source compiles every module
# and bundles the client on each start, which peaks at 2 GB or more of memory; the sealed
# bundle starts in well under 1 GB. The build itself needs that headroom, so give the
# build host at least 3 GB.
RUN jac build -o /app/dist

RUN chown -R 1000:1000 /app

# The graph store (the incident, the roster, learned source trust) lives under
# JAC_CACHE_HOME; mount it, with outputs and fetched data, to survive restarts. The
# embedded database refuses to run as root, hence the unprivileged user.
ENV JAC_CACHE_HOME=/var/lib/resqmesh/jac \
    RESQMESH_DATA_DIR=/app/data \
    RESQMESH_OUTPUTS_DIR=/app/outputs
RUN mkdir -p /var/lib/resqmesh/jac /app/outputs /app/data && chown -R 1000:1000 /var/lib/resqmesh /app/outputs /app/data
USER 1000
VOLUME ["/var/lib/resqmesh/jac", "/app/outputs", "/app/data"]

EXPOSE 8000

# There is deliberately no HEALTHCHECK here. A platform that sees one does a rolling update,
# starting the new container while the old one still runs, and the two would then have
# the same embedded database directory open at once, which corrupts it. This service must
# stop the old container before the new one starts. docker-compose.yml keeps a healthcheck,
# which is safe there. The first start unpacks the runtime into JAC_CACHE_HOME and starts
# the database, so it takes a little longer than the ones after it.

# The base image's entrypoint is already `jac`, so the command is its arguments only.
# RESQMESH_DEMO=1 (set by docker-compose) opens the synthetic incident at start, so a
# running system is there to look at. Remove it to start with a blank incident.
CMD ["run", "--no-dev", "--host", "0.0.0.0", "--port", "8000", "dist/resqmesh.jab"]
