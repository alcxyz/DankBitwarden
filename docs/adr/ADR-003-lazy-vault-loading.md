# ADR-003: Lazy vault loading

**Status:** Accepted
**Date:** 2026-04-23
**Applies to:** `DankVault.qml`

## Context

DankVault called `refreshEntries()` during component initialization (`Component.onCompleted` → `_resolveBackend()`), which runs the backend's list command (e.g. `rbw list`). If the vault is locked, this triggers a password/PIN prompt immediately on DMS startup, before the user has opened the launcher.

This is poor UX — the shell blocks on a password prompt the user didn't ask for.

DMS can also ask launcher plugins for items in "All" mode without the plugin trigger. For cheap launchers that is useful, but for a password vault it can still run `rbw list` before the user types `@`.

## Decision

Defer `refreshEntries()` until `getItems()` is first called. Backend detection still runs on init (it's lightweight — just `command -v` checks), but the vault query is lazy.

A `_needsRefresh` flag is set during backend resolution and consumed on the first `getItems()` call.

DankVault also opts out of DMS launcher "All" mode once on plugin load by setting `allowWithoutTrigger` to `false` when no explicit visibility choice exists yet. Triggered use still works because DMS strips the trigger and passes the remaining query to `getItems()`. The opt-out is recorded with `triggerOnlyVisibilityDefaultApplied` so a user can intentionally re-enable "All" mode later without the plugin resetting their choice every restart.

## Alternatives Considered

- **Increase `lock_timeout`** — reduces frequency but doesn't eliminate the problem. Also an rbw config concern, not a plugin concern.
- **Background unlock check before listing** — adds complexity; the user still gets prompted, just with a different flow.
- **Disable auto-load entirely, require manual refresh** — too much friction for normal use.

## Consequences

- No vault-related prompts on DMS startup or normal launcher open.
- First use of the plugin after launch shows a brief "Loading vault..." state.
- If the vault is locked, the PIN/password prompt appears when the user actually wants to use the vault, not before.
- `refreshEntries()` is still callable for manual refresh (e.g. retry on error).
- Users who intentionally re-enable "All" mode can still make DankVault searchable without typing the trigger.
