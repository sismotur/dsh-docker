# syntax=docker/dockerfile:1
# Hardened dsh container.
# Builder carries build tools for any native addon (node-addon-require-builtin);
# they do NOT ship in the runtime image.

FROM node:25-slim AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
# Install the global tools (dsh, pnpm, MCP memory server) from a committed,
# integrity-verified lockfile. `npm ci` fetches every tarball by the sha512
# hash recorded in global-tools/package-lock.json instead of resolving "latest"
# at build time, so the supply-chain tree is reproducible and auditable (no
# silent version drift, no unverified tarball). The tree installs into a local
# node_modules; the runtime stage copies it to the global location, producing
# the same flat layout `npm i -g` would have.
WORKDIR /opt/global-tools
COPY global-tools/package.json global-tools/package-lock.json ./
RUN npm ci
# Pre-compile node-pty's Linux native addon from a committed, integrity-verified
# lockfile. node-pty (a dependency of dsh-better-sidebar) ships prebuilds for
# darwin/win32 but not linux, so it must be compiled from source. The runtime
# image has no build tools (kept minimal for hardening), so the 81 KB pty.node
# is compiled here and copied to runtime; enable-terminal.sh injects it into
# the plugin's node-pty at install time. node-pty uses N-API (ABI-stable), so
# the binary loads across Node.js versions. `npm ci` verifies the node-pty
# tarball by integrity hash before running its build script to compile it.
WORKDIR /opt/pty-build
COPY pty-build/package.json pty-build/package-lock.json ./
RUN npm ci

FROM node:25-slim AS runtime
# socat: TCP proxy so Docker can publish the web port. dsh refuses --host
# 0.0.0.0 (RCE safety), binding only to 127.0.0.1 inside the container, which
# Docker port forwarding cannot reach. socat bridges 0.0.0.0:8080 -> 127.0.0.1:8090.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       socat git ca-certificates curl jq less ripgrep openssh-client \
       vim bat \
    && rm -rf /var/lib/apt/lists/*
# Debian's bat package installs the binary as `batcat` (name conflict), so
# symlink it to `bat` for parity with the host alias `alias bat="bat -p"`.
RUN ln -s /usr/bin/batcat /usr/local/bin/bat
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
COPY agents/public/               /opt/dsh-patches/agents/public/
COPY agents/private.example/      /opt/dsh-patches/agents/private.example/
COPY LICENSE NOTICE.md                 /opt/dsh-patches/
# Local dsh plugins (composer git branch dock, etc.)
COPY plugins/ /opt/dsh-plugins/
COPY seed-omlx.sh /usr/local/bin/seed-omlx.sh
COPY register-workspace.sh /usr/local/bin/register-workspace.sh
COPY web-entrypoint.sh /usr/local/bin/web-entrypoint.sh
COPY enable-terminal.sh /usr/local/bin/enable-terminal.sh
RUN chmod +x /usr/local/bin/seed-omlx.sh /usr/local/bin/register-workspace.sh /usr/local/bin/web-entrypoint.sh /usr/local/bin/enable-terminal.sh
# Terminal aliases for the dsh-better-sidebar terminal tab. Sourced by
# /etc/profile -> /etc/profile.d/*.sh for bash login shells (the terminal
# spawns `bash -l`); not sourced by dsh's non-login bash tool, so they only
# apply to the interactive terminal.
COPY dsh-aliases.sh /etc/profile.d/dsh-aliases.sh
# Prebuilt node-pty binary from the builder stage. Injected into the
# dsh-better-sidebar plugin's node-pty by enable-terminal.sh.
COPY --from=builder /opt/pty-build/node_modules/node-pty/build/Release/pty.node /opt/prebuilds/node-pty/pty.node
# dsh global install from builder. Recreate the npm symlink so ESM module
# resolution stays relative to the real package path.
COPY --from=builder /opt/global-tools/node_modules /usr/local/lib/node_modules
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
