#!/usr/bin/env bash
# Runs once after the dev container is created (as the vscode user).
# Base tools (docker, terraform, helm, gcloud, git, gh, zsh, node, python)
# are installed via the Dockerfile and devcontainer features; this script adds
# the user-level CLIs that have no apt/feature package.
set -euo pipefail

echo "==> Installing npm globals: pnpm, create-next-app, opencode, linear, gws"
# --allow-scripts: opencode-ai, @schpet/linear-cli and @googleworkspace/cli need
# their postinstall scripts to fetch/link their platform binaries (blocked by
# default in npm 11+).
npm install -g --allow-scripts=@schpet/linear-cli,opencode-ai,@googleworkspace/cli \
  pnpm \
  create-next-app \
  opencode-ai \
  @schpet/linear-cli \
  @googleworkspace/cli

echo "==> Installing modal (pipx)"
pipx install modal

echo "==> Installed versions:"
terraform version | head -1
gcloud --version | head -1
jq --version
yq --version
helm version --short
gh --version | head -1
git --version
node --version
pnpm --version
opencode --version
linear --version
gws --version
modal --version

echo "==> post-create complete"
