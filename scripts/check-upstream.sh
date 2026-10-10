#!/usr/bin/env bash
#
# check-upstream.sh — lightweight upstream watcher.
#
# Compares origin/main against upstream/main. When new upstream commits
# exist, drops a macOS notification. Never builds, never merges, never
# touches the working tree — safe to run from launchd every few hours.
#
# Usage:
#   scripts/check-upstream.sh            # notify on update (default)
#   scripts/check-upstream.sh --print    # also print status to stdout
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$HOME/Library/Logs/lody-fork-check.log"
PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

say() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
  [ "$PRINT" = 1 ] && printf '%s\n' "$*"
}

# The repo lives on an external volume; if it is not mounted, exit quietly.
[ -d "$REPO_ROOT/.git" ] || exit 0

if ! git -C "$REPO_ROOT" fetch upstream main >/dev/null 2>&1; then
  say "fetch upstream failed (offline?)"
  exit 0
fi
git -C "$REPO_ROOT" fetch origin main >/dev/null 2>&1 || true

LOCAL="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo none)"
REMOTE="$(git -C "$REPO_ROOT" rev-parse upstream/main 2>/dev/null || echo none)"
if [ "$LOCAL" = "none" ] || [ "$REMOTE" = "none" ]; then
  say "could not resolve origin/main or upstream/main"
  exit 0
fi

BEHIND="$(git -C "$REPO_ROOT" rev-list --count "origin/main..upstream/main" 2>/dev/null || echo '?')"
if [ "$LOCAL" = "$REMOTE" ] || [ "$BEHIND" = "0" ]; then
  # hashes differ only because the fork has its own commits on top
  say "no new upstream commits (fork at ${LOCAL:0:8}, behind=0)"
  exit 0
fi
SUBJECT="$(git -C "$REPO_ROOT" log -1 --format='%s' upstream/main 2>/dev/null | head -c 80)"
# sanitize for AppleScript string literal
SUBJECT="${SUBJECT//\\/}"
SUBJECT="${SUBJECT//\"/\'}"

say "update available: $BEHIND new commits (latest: $SUBJECT)"

osascript -e "display notification \"${BEHIND} 个新提交 · ${SUBJECT}\" with title \"Lody fork 可更新\" subtitle \"跑 update-and-repackage.sh 即可\" sound name \"Glass\"" >/dev/null 2>&1 || true
