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
RUN chown -R 1000:1000 /app

# The graph store (the incident, the roster, learned source trust) lives under
# JAC_CACHE_HOME; mount it, with outputs and fetched data, to survive restarts.
ENV JAC_CACHE_HOME=/var/lib/resqmesh/jac
RUN mkdir -p /var/lib/resqmesh/jac /app/outputs /app/data && chown -R 1000:1000 /var/lib/resqmesh /app/outputs /app/data
USER 1000
VOLUME ["/var/lib/resqmesh/jac", "/app/outputs", "/app/data"]

EXPOSE 8000

# RESQMESH_DEMO=1 (set by docker-compose) opens the synthetic incident at start, so a
# running system is there to look at. Remove it to start with a blank incident.
CMD ["jac", "run", "--no-dev", "--port", "8000", "main.jac"]
