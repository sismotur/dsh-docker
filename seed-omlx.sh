#!/bin/sh
# Seed the oMLX cordis.patch.yml into the DSH_HOME volume for both profiles.
# Run via: ./run-dsh.sh seed   (or: docker compose run --rm --entrypoint /usr/local/bin/seed-omlx.sh dsh-headless)
set -e
: "${DSH_HOME:=/data}"
for p in web headless; do
  mkdir -p "$DSH_HOME/profiles/$p"
  cp "/opt/dsh-patches/$p/cordis.patch.yml" "$DSH_HOME/profiles/$p/cordis.patch.yml"
  echo "seeded $DSH_HOME/profiles/$p/cordis.patch.yml"
done
# Seed the global AGENTS.md (user-global agent instructions). The
# dsh-agent-instructions system loads $DSH_HOME/AGENTS.md into every session's
# system prompt as the baseline precedence layer.
command cp -f /opt/dsh-patches/agents-global.md "$DSH_HOME/AGENTS.md"
echo "seeded $DSH_HOME/AGENTS.md"

# pnpm store on the writable volume (rootfs is read-only at runtime).
mkdir -p "${PNPM_HOME:-$DSH_HOME/.pnpm}"

# Set the default model to smart-router (the LiteLLM auto router). A saved
# selection in settings.yaml overrides the cordis patch's agent-default-model,
# so reset it here to avoid a stale model name after switching to the router.
cat > "$DSH_HOME/settings.yaml" << 'EOF'
ui-onboarding:
  welcomeNoticeVersion: 2026-08-13.1
agent-default-model:
  provider: deepseek-official
  model: smart-router
  reasoningEffort: high
EOF
echo "oMLX patches + pnpm store + default model ready."
