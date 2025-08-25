#!/usr/bin/env bash
set -euo pipefail

# Load .env if present
if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${DEPLOY_HOST:?Set DEPLOY_HOST in .env}"
: "${DEPLOY_USER:?Set DEPLOY_USER in .env}"
: "${DEPLOY_PATH:?Set DEPLOY_PATH in .env}"

# Create target directory and set permissions (first-time deploy convenience)
ssh "${DEPLOY_USER}@${DEPLOY_HOST}" "mkdir -p '${DEPLOY_PATH}' && test -w '${DEPLOY_PATH}'"

# Sync (fast, deletes removed files, preserves timestamps)
rsync -avz --delete \
  --chmod=Du=rwx,Fu=rw,Fgo=r,Dgo=rx \
  public/ "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/"

echo "Deployed to ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}"
