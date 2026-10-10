#!/usr/bin/env bash
#
# update-and-repackage.sh — fork self-updater.
#
# Replaces the app's built-in Sparkle auto-update with this flow:
#   1. git fetch upstream && merge upstream/main (ff preferred, conflict aborts)
#   2. sync ACP submodules to the newly pinned commits
#   3. pnpm install --frozen-lockfile (only when the lockfile changed)
#   4. guard the billing compat layer + run its stock-mode tests
#   5. pnpm build (embedded CLI + Electron) and package a DMG
#   6. install to /Applications and relaunch (skipped while the app is
#      running under LODY_UPDATE_AUTO=1, i.e. scheduled runs)
#
# Usage:
#   scripts/update-and-repackage.sh                 # full flow
#   scripts/update-and-repackage.sh --no-install    # stop after packaging
#   scripts/update-and-repackage.sh --no-update     # skip merge, just rebuild
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DO_INSTALL=1
DO_UPDATE=1
for arg in "$@"; do
  case "$arg" in
    --no-install) DO_INSTALL=0 ;;
    --no-update)  DO_UPDATE=0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m[lody-update]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[lody-update] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

APP_NAME="Lody OSS"
APP_BUNDLE_ID="dev.loro.lody.oss"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
# Point Sparkle at a dead port so the fork never pulls official builds over
# itself (override with LODY_SPARKLE_FEED if you ever want a real feed).
export SPARKLE_APPCAST_URL="${LODY_SPARKLE_FEED:-http://127.0.0.1:9/appcast.xml}"

# --- 0. sanity ----------------------------------------------------------------
git remote get-url upstream >/dev/null 2>&1 || \
  git remote add upstream https://github.com/LodyAI/Lody.git

NODE_OK="$(node -p 'const [a,b]=process.versions.node.split(".").map(Number); (a===22&&b>=14)||(a>23)||(a===23&&b>=6)')"
[ "$NODE_OK" = "true" ] || fail "node $(node -v) violates engines (>=22.14 <23 || >=23.6)"

# --- 1. fetch + merge upstream ------------------------------------------------
if [ "$DO_UPDATE" = 1 ]; then
  BEFORE_HEAD="$(git rev-parse HEAD)"
  log "fetching upstream..."
  git fetch upstream main --tags
  UPSTREAM_HEAD="$(git rev-parse upstream/main)"
  if [ "$BEFORE_HEAD" = "$UPSTREAM_HEAD" ]; then
    log "already up to date with upstream/main"
  else
    log "merging upstream/main ($BEFORE_HEAD -> $UPSTREAM_HEAD)..."
    if ! git merge --ff-only upstream/main 2>/dev/null; then
      if git merge --no-edit upstream/main; then
        log "merged with a merge commit"
        git push origin main 2>/dev/null || log "(could not push to origin; continuing)"
      else
        git merge --abort 2>/dev/null || true
        fail "merge conflict — most likely packages/shared/src/billing.ts. Resolve manually, then rerun."
      fi
    fi
  fi
fi

# --- 2. submodules ------------------------------------------------------------
log "syncing ACP submodules..."
git submodule update --init --recursive

# --- 3. dependencies ----------------------------------------------------------
LOCK_CHANGED="$(git status --porcelain -- pnpm-lock.yaml | wc -l | tr -d ' ')"
if [ "$LOCK_CHANGED" != "0" ] || [ ! -d node_modules ]; then
  log "(re)installing dependencies..."
  pnpm install --frozen-lockfile
else
  log "lockfile unchanged; skipping pnpm install"
fi

# --- 4. compat-layer guard ----------------------------------------------------
grep -q "LODY_QUOTA_LIMITS" packages/shared/src/billing.ts || \
  fail "packages/shared/src/billing.ts lost the compat layer — upstream restructured billing. Re-apply the patch before packaging."
log "compat layer intact; validating evaluator signatures (stock mode)..."
( cd packages/shared && LODY_QUOTA_LIMITS=billing ./node_modules/.bin/vitest run tests/billing.test.ts >/dev/null ) || \
  fail "billing tests failed in stock mode — evaluator signatures drifted upstream; fix billing.ts first"

# --- 5. build + package -------------------------------------------------------
log "building embedded CLI + Electron app (this takes a while)..."
( cd apps/electron && pnpm run build ) || fail "build failed"

log "packaging DMG..."
( cd apps/electron && pnpm run package -- --mac ) || fail "packaging failed"

DMG="$(ls -t apps/electron/dist/LodyOSS-*.dmg 2>/dev/null | head -1)"
[ -n "$DMG" ] || fail "no DMG found in apps/electron/dist"
log "built: $DMG"

if [ "$DO_INSTALL" = 0 ]; then
  log "--no-install given; done."
  exit 0
fi

# --- 6. install ---------------------------------------------------------------
if [ "${LODY_UPDATE_AUTO:-0}" = "1" ] && pgrep -f "$APP_NAME.app/Contents/MacOS" >/dev/null 2>&1; then
  log "$APP_NAME is running; scheduled run leaves the DMG in place. Quit the app and rerun to install."
  exit 0
fi

log "quitting any running instance..."
osascript -e 'tell application id "'"$APP_BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true

MOUNT_POINT="$(mktemp -d /tmp/lody-dmg.XXXXXX)"
log "mounting DMG..."
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null || fail "could not mount $DMG"
trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT

SRC_APP="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$SRC_APP" ] || fail "no .app inside the DMG"

log "installing to $APP_PATH..."
rm -rf "$APP_PATH"
cp -R "$SRC_APP" "$APP_PATH"
hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
trap - EXIT

xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
# Keep Sparkle from ever checking the (dead) feed on its own schedule.
defaults write "$APP_BUNDLE_ID" SUEnableAutomaticChecks -bool false 2>/dev/null || true

log "relaunching $APP_NAME..."
open "$APP_PATH"
log "done. installed $("$APP_PATH/Contents/MacOS/$APP_NAME" --version 2>/dev/null || echo '<unknown>') at $APP_PATH"
