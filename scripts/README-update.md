# Fork self-update

`update-and-repackage.sh` replaces the built-in Sparkle auto-updater.
Upstream Sparkle would pull **official** builds over this fork and wipe the
quota compat layer, so the packaged app gets a dead feed URL
(`http://127.0.0.1:9/appcast.xml`) and automatic checks disabled. Updates come
from this script instead.

## What it does

1. `git fetch upstream main` and merge into local `main`
   (fast-forward preferred; on conflict it aborts — `billing.ts` is the
   likely culprit, resolve and rerun)
2. `git submodule update --init --recursive` (ACP adapter pins)
3. `pnpm install --frozen-lockfile`, only when `pnpm-lock.yaml` changed
4. Guards the compat layer: greps `billing.ts` for `LODY_QUOTA_LIMITS` and
   runs the billing suite in **stock mode** to catch upstream signature drift
5. `pnpm build` (embedded CLI + Electron renderer) → `package -- --mac` DMG
6. Installs to `/Applications` (quits the running app first), clears the
   quarantine xattr, disables Sparkle auto-check, relaunches

## Usage

```bash
scripts/update-and-repackage.sh               # full flow
scripts/update-and-repackage.sh --no-install  # just build a fresh DMG
scripts/update-and-repackage.sh --no-update   # rebuild current tree only
```

## Scheduled runs

A launchd agent can run it daily. With `LODY_UPDATE_AUTO=1` the script
**never force-quits a running app** — it only leaves the fresh DMG in
`apps/electron/dist/` and exits; the install happens next time the app is
closed and the script runs again (or you run it manually).

```bash
LODY_UPDATE_AUTO=1 scripts/update-and-repackage.sh
```

## Signing notes

Local builds are ad-hoc signed (no Developer ID): Gatekeeper warning on first
launch only, Sparkle notarization is skipped by electron-builder automatically
without `CSC_LINK`/`CSC_NAME`. The script strips the quarantine attribute so
the ad-hoc signature is accepted directly.
