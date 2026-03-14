#!/usr/bin/env bash
# Deploy patched OpenClaw to ALINA v2 (alina NixOS box)
# Usage: ./scripts/deploy-alina.sh
set -euo pipefail

REMOTE="alina"
REMOTE_USER="openclaw"
REMOTE_HOME="/var/lib/openclaw"
REMOTE_PREFIX="${REMOTE_HOME}/.npm-global"

echo "=== Building OpenClaw ==="
cd "$(dirname "$0")/.."

# 1. Bundle JS (tsdown)
pnpm canvas:a2ui:bundle
node scripts/tsdown-build.mjs

# 2. Post-build steps (skip DTS — optional deps cause failures)
node scripts/copy-plugin-sdk-root-alias.mjs
node --import tsx scripts/write-plugin-sdk-entry-dts.ts
node --import tsx scripts/canvas-a2ui-copy.ts
node --import tsx scripts/copy-hook-metadata.ts
node --import tsx scripts/copy-export-html-templates.ts
node --import tsx scripts/write-build-info.ts
node --import tsx scripts/write-cli-startup-metadata.ts
node --import tsx scripts/write-cli-compat.ts

echo "=== Build complete ==="

# 3. Pack tarball (strip prepare script to avoid rebuild on install)
TMPDIR=$(mktemp -d)
cp package.json "${TMPDIR}/package-backup.json"
python3 -c "
import json, sys
p = json.load(open('package.json'))
for k in ['prepare', 'prepublishOnly', 'prepack']:
    p.get('scripts', {}).pop(k, None)
json.dump(p, open('package.json', 'w'), indent=2)
"
TARBALL=$(npm pack --pack-destination "${TMPDIR}" 2>/dev/null | tail -1)
cp "${TMPDIR}/package-backup.json" package.json
TARBALL_PATH="${TMPDIR}/${TARBALL}"
echo "=== Packed: ${TARBALL_PATH} ($(du -h "${TARBALL_PATH}" | cut -f1)) ==="

# 4. Transfer
echo "=== Transferring to ${REMOTE} ==="
scp "${TARBALL_PATH}" "${REMOTE}:/tmp/openclaw-deploy.tgz"

# 5. Install
echo "=== Installing on ${REMOTE} ==="
ssh "${REMOTE}" "sudo -u ${REMOTE_USER} bash -c 'export HOME=${REMOTE_HOME} && export NPM_CONFIG_PREFIX=${REMOTE_PREFIX} && npm --prefix ${REMOTE_PREFIX} install -g /tmp/openclaw-deploy.tgz 2>&1 | tail -5'"

# 6. Get version
VERSION=$(ssh "${REMOTE}" "sudo -u ${REMOTE_USER} bash -c 'export HOME=${REMOTE_HOME} && ${REMOTE_PREFIX}/bin/openclaw --version 2>&1'")
echo "=== Installed: ${VERSION} ==="

# 7. Restart gateway
echo "=== Restarting gateway ==="
ssh "${REMOTE}" "sudo systemctl restart openclaw-gateway"
sleep 4

# 8. Health check
echo "=== Health check ==="
ssh "${REMOTE}" "sudo journalctl -u openclaw-gateway --no-pager -n 5"

# Cleanup
rm -rf "${TMPDIR}"

echo ""
echo "=== Deploy complete ==="
