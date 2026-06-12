# Build the C++ Prism game server and ship it in a minimal runtime image.
# Build context is the repo root (see deploy/docker-compose.yml): we need the
# top CMakeLists plus engine/, server/, cards/. The web client is NOT baked in --
# Caddy serves the exported .web-export as a mounted volume (see compose).

# Stage 1: compile prism_server (Release) against the vendored engine.
FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY CMakeLists.txt ./
COPY engine/ engine/
COPY server/ server/
COPY cards/ cards/
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build --target prism_server -j"$(nproc)"

# Stage 2: just the binary + cards, non-root, writable replays dir.
FROM ubuntu:24.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home /opt/prism --shell /usr/sbin/nologin prism \
 && mkdir -p /opt/prism/cards /opt/prism/replays \
 && chown -R prism:prism /opt/prism
WORKDIR /opt/prism
COPY --from=build /src/build/server/prism_server /opt/prism/prism_server
COPY --from=build /src/cards/sample.json /opt/prism/cards/sample.json
USER prism
EXPOSE 8080
CMD ["/opt/prism/prism_server", "8080", "/opt/prism/cards/sample.json"]
