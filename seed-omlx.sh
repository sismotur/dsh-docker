#!/bin/sh
# Seed cordis patches into the DSH_HOME volume for both profiles.
# Backend path: dsh -> LiteLLM -> TensorFold (host :8421, models in
# ~/models/tensorfold) with optional oMLX (:8000) for non-TF models.
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

# Default model: smart-router -> TensorFold omlx-qwen36. A saved selection in
# settings.yaml overrides cordis agent-default-model, so reset it on seed.
cat > "$DSH_HOME/settings.yaml" << 'EOF'
ui-onboarding:
  welcomeNoticeVersion: 2026-08-13.1
agent-default-model:
  provider: deepseek-official
  model: smart-router
  reasoningEffort: high
EOF
echo "TensorFold/oMLX patches + pnpm store + default model ready."
