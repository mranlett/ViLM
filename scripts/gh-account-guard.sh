#!/usr/bin/env sh
# gh-account-guard.sh — fail closed unless the ACTIVE gh account is the personal one.
#
# ViLM is a personal repo on `mranlett`. The `gh` CLI authenticates per HOST, not
# per repo, so it does not honour the `includeIf` rule in ~/.gitconfig that swaps
# git identity for work remotes. With both accounts logged in and `MattR3Ci`
# active, `gh issue create` / `gh pr create` here would file under the WORK
# account — a Constitution Art. V cross-pollination breach, and a silent one.
#
# Fix when this fires:  gh auth switch --hostname github.com --user mranlett
#
# Wired into .githooks/pre-push. NOTE: .githooks/ is installed by Directive; if a
# future `directive update` rewrites pre-push, re-add the guard line there.

EXPECTED="mranlett"

if ! command -v gh >/dev/null 2>&1; then
    exit 0  # no gh, no hazard
fi

ACTIVE="$(gh auth status --active 2>/dev/null | sed -n 's/.*Logged in to [^ ]* account \([^ ]*\).*/\1/p' | head -1)"

if [ -z "$ACTIVE" ]; then
    echo "gh-account-guard: gh is installed but no active account resolved; not blocking." >&2
    exit 0
fi

if [ "$ACTIVE" != "$EXPECTED" ]; then
    echo "" >&2
    echo "❌ gh-account-guard: active gh account is '$ACTIVE', expected '$EXPECTED'." >&2
    echo "   ViLM is a PERSONAL repo. Pushing or filing issues as the work account" >&2
    echo "   cross-pollinates work and personal contexts (Constitution Art. V)." >&2
    echo "" >&2
    echo "   Fix:  gh auth switch --hostname github.com --user $EXPECTED" >&2
    echo "" >&2
    exit 1
fi

exit 0
