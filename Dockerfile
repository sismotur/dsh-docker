# syntax=docker/dockerfile:1
# Hardened dsh container.
# Builder carries build tools for any native addon (node-addon-require-builtin);
# they do NOT ship in the runtime image.

FROM node:25-slim AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
RUN npm i -g @deepseek-ai/dsh@0.1.2-rc.1 pnpm @modelcontextprotocol/server-memory

FROM node:25-slim AS runtime
# socat: TCP proxy so Docker can publish the web port. dsh refuses --host
# 0.0.0.0 (RCE safety), binding only to 127.0.0.1 inside the container, which
# Docker port forwarding cannot reach. socat bridges 0.0.0.0:8080 -> 127.0.0.1:8090.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       socat git ca-certificates curl jq less ripgrep openssh-client \
    && rm -rf /var/lib/apt/lists/*
# No-op xdg-open: a fallback for any residual native file-open gesture.
# Containers cannot reach the host GUI, so a real opener is impossible. With
# dsh 0.1.2+ and dsh-better-sidebar's interceptOpenPath (on by default), chat
# file links open in the sidebar editor client-side and never reach this shim;
# it remains as a harmless exit-0 fallback instead of raising spawn ENOENT.
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/xdg-open && chmod +x /usr/local/bin/xdg-open
# System gitconfig baked at build time. Bind-mounted repos under /workspace
# are owned by the host uid, not the container's uid 1000, so git's
# safe.directory check would reject them. The rootfs is read-only at RUNTIME,
# but this write happens during the build. dsh's command-spawn credential
# scrub (dsh-subprocess) strips env-var names matching /KEY|PASSWORD|SECRET|
# TOKEN/i, so the GIT_CONFIG_COUNT/KEY_0/VALUE_0 env-var trio broke (COUNT
# survived the scrub, KEY_0 was stripped -> "missing config key GIT_CONFIG_KEY_0").
# A baked system gitconfig read via GIT_CONFIG_SYSTEM (which survives the scrub)
# fixes git for both direct and dsh-spawned invocations.
RUN printf '[safe]\n\tdirectory = /workspace\n' > /etc/gitconfig
# Container-variant oMLX patches (host.docker.internal baseURL), baked read-only.
COPY patches/web/cordis.patch.yml      /opt/dsh-patches/web/cordis.patch.yml
COPY patches/headless/cordis.patch.yml /opt/dsh-patches/headless/cordis.patch.yml
COPY agents-global.md            /opt/dsh-patches/agents-global.md
COPY seed-omlx.sh /usr/local/bin/seed-omlx.sh
COPY register-workspace.sh /usr/local/bin/register-workspace.sh
COPY web-entrypoint.sh /usr/local/bin/web-entrypoint.sh
RUN chmod +x /usr/local/bin/seed-omlx.sh /usr/local/bin/register-workspace.sh /usr/local/bin/web-entrypoint.sh
# dsh global install from builder. Recreate the npm symlink so ESM module
# resolution stays relative to the real package path.
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh
# pnpm for dsh plugin management. Store + global bin live on the writable
# DSH_HOME volume (not the read-only rootfs). Postinstall scripts are blocked
# by default to neutralize rogue-plugin supply-chain execution at install time;
# override with --config.ignore-scripts=false for a trusted native-addon build.
RUN ln -s ../lib/node_modules/pnpm/bin/pnpm.mjs /usr/local/bin/pnpm
# Strip setuid/setgid bits from Debian base binaries (su, passwd, mount, etc).
# They are unnecessary in this container and NoNewPrivs already neutralizes them;
# removing them eliminates the attack surface entirely.
RUN find / -xdev -perm /6000 -type f -exec chmod ug-s {} + 2>/dev/null || true
# Writable DSH_HOME owned by the unprivileged user (named volume inherits this).
RUN mkdir -p /data && chown -R 1000:1000 /data
# node:25-slim already ships a non-root `node` user at uid 1000; reuse it.
ENV DSH_HOME=/data
ENV PNPM_HOME=/data/.pnpm
ENV npm_config_ignore_scripts=true
WORKDIR /workspace
USER node
# dsh's HMR plugin requires --expose-internals, which NODE_OPTIONS rejects,
# so invoke node explicitly with the flag.
ENTRYPOINT ["node", "--expose-internals", "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"]
