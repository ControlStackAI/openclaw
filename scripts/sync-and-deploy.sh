#!/usr/bin/env bash
# sync-and-deploy.sh — Sync fork with upstream, rebase ALINA patches, build & deploy
#
# Branch strategy:
#   fork/main  = pure mirror of upstream openclaw/openclaw main
#   fork/alina = upstream main + ALINA-specific patches (rebased on top)
#
# Usage:
#   ./scripts/sync-and-deploy.sh [--dry-run] [--no-deploy]
#
# What it does:
#   1. Fetch upstream (origin) and fork remotes
#   2. Fast-forward fork/main to match upstream main
#   3. Rebase alina branch onto new main
#   4. Force-push both main and alina to fork
#   5. Build patched OpenClaw from alina branch
#   6. Deploy to alina host via deploy-alina.sh
#
# On rebase conflict: stops, alerts, leaves branches untouched

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

DRY_RUN=false
NO_DEPLOY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-deploy) NO_DEPLOY=true ;;
  esac
done

log() { echo "=== $(date +%H:%M:%S) $* ==="; }
die() { echo "❌ ERROR: $*" >&2; exit 1; }

# Save current branch to restore later
ORIG_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)

cleanup() {
  git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
  git rebase --abort 2>/dev/null || true
}
trap cleanup EXIT

# 1. Fetch
log "Fetching upstream and fork"
git fetch origin --quiet
git fetch fork --quiet

UPSTREAM_HEAD=$(git rev-parse origin/main)
FORK_MAIN_HEAD=$(git rev-parse fork/main)
ALINA_HEAD=$(git rev-parse fork/alina 2>/dev/null || echo "none")

log "Upstream: ${UPSTREAM_HEAD:0:10} | Fork main: ${FORK_MAIN_HEAD:0:10} | Alina: ${ALINA_HEAD:0:10}"

# 2. Check if upstream has new commits
if [ "$UPSTREAM_HEAD" = "$FORK_MAIN_HEAD" ]; then
  log "Fork main already up to date with upstream"
  # Still check if alina needs rebase (e.g., new patches added locally)
else
  NEW_COMMITS=$(git rev-list --count "$FORK_MAIN_HEAD".."$UPSTREAM_HEAD")
  log "Upstream has $NEW_COMMITS new commits"
fi

if $DRY_RUN; then
  log "DRY RUN — would sync main and rebase alina"
  exit 0
fi

# 3. Fast-forward main
log "Syncing main"
git checkout main --quiet
git merge origin/main --ff-only --quiet
git push fork main --quiet

# 4. Rebase alina
log "Rebasing alina onto main"
git checkout alina --quiet 2>/dev/null || git checkout -b alina fork/alina --quiet

# Count our patches (commits on alina not in main)
PATCH_COUNT=$(git rev-list --count main..alina)
log "ALINA has $PATCH_COUNT patches to rebase"

if ! git rebase main --quiet 2>/dev/null; then
  git rebase --abort 2>/dev/null || true
  die "Rebase failed! ALINA patches conflict with upstream. Manual resolution needed.

Files in conflict — check with: cd $REPO_DIR && git checkout alina && git rebase main

After resolving: git rebase --continue && git push fork alina --force"
fi

NEW_ALINA_HEAD=$(git rev-parse HEAD)
log "Rebase clean. Alina: ${NEW_ALINA_HEAD:0:10} ($PATCH_COUNT patches)"

# 5. Push
git push fork alina --force --quiet
log "Pushed main + alina to fork"

# 6. Deploy
if $NO_DEPLOY; then
  log "Skipping deploy (--no-deploy)"
else
  log "Building and deploying to alina"
  bash "$SCRIPT_DIR/deploy-alina.sh"
fi

log "Sync complete ✅"
