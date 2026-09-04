# syntax=docker/dockerfile:1
# Hardened dsh container.
# Builder carries build tools for any native addon (node-addon-require-builtin);
# they do NOT ship in the runtime image.

FROM node:25-slim AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
RUN npm i -g @deepseek-ai/dsh@0.1.1-rc.2

FROM node:25-slim AS runtime
# Container-variant oMLX patches (host.docker.internal baseURL), baked read-only.
COPY patches/web/cordis.patch.yml      /opt/dsh-patches/web/cordis.patch.yml
COPY patches/headless/cordis.patch.yml /opt/dsh-patches/headless/cordis.patch.yml
COPY seed-omlx.sh /usr/local/bin/seed-omlx.sh
RUN chmod +x /usr/local/bin/seed-omlx.sh
# dsh global install from builder. Recreate the npm symlink so ESM module
# resolution stays relative to the real package path.
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh
# Writable DSH_HOME owned by the unprivileged user (named volume inherits this).
RUN mkdir -p /data && chown -R 1000:1000 /data
# node:25-slim already ships a non-root `node` user at uid 1000; reuse it.
ENV DSH_HOME=/data
WORKDIR /workspace
USER node
# dsh's HMR plugin requires --expose-internals, which NODE_OPTIONS rejects,
# so invoke node explicitly with the flag.
ENTRYPOINT ["node", "--expose-internals", "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"]
