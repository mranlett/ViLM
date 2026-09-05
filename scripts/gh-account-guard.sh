#!/usr/bin/env sh
# gh-account-guard.sh — assert outbound GitHub work here acts as the PERSONAL account.
#
# ViLM is personal (mranlett). 3Ci work runs as MattR3Ci in parallel sessions on this
# same machine, and they share one global gh state, so this cannot be assumed.
#
# WHAT ACTUALLY DECIDES IDENTITY (measured on gh 2.97, 2026-09-05):
#   • git push  -> the git credential helper, keyed by the username in remote.origin.url.
#   • gh <cmd>  -> gh matches the REPO OWNER against logged-in accounts and uses that
#                  account. Only when no account matches the owner does it fall back to
#                  the globally "active" one.
#
# THEREFORE `gh auth status --active` IS NOT THE CHECK. It reports the fallback, which
# here is routinely MattR3Ci while gh is correctly acting as mranlett. An earlier version
# of this script tested exactly that and produced a FALSE FAILURE, blocking a push that
# was correctly credentialed. Test the things that actually govern the outcome instead.

set -u

EXPECTED_USER="mranlett"
EXPECTED_EMAIL="matt.ranlett@gmail.com"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
FAIL=0

# (1) Commit identity — offline, deterministic, authoritative.
EMAIL="$(git config user.email 2>/dev/null || true)"
if [ "$EMAIL" != "$EXPECTED_EMAIL" ]; then
    echo "❌ gh-account-guard: git user.email is '$EMAIL', expected '$EXPECTED_EMAIL'." >&2
    FAIL=1
fi

# (2) Push credential selection — the username pin in the remote URL is what the
#     credential helper keys on, so an unpinned URL can silently draw the work token.
URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
case "$URL" in
    *"$EXPECTED_USER@github.com/$EXPECTED_USER/"*) ;;
    git@github.com:"$EXPECTED_USER"/*) ;;
    *)
        echo "❌ gh-account-guard: origin is '$URL'." >&2
        echo "   Expected the personal username pin, e.g." >&2
        echo "   https://$EXPECTED_USER@github.com/$EXPECTED_USER/ViLM.git" >&2
        FAIL=1
        ;;
esac

# (3) Raw gh identity as a CHILD PROCESS sees it. Matt's zsh gh() wrapper resolves
#     the repo owner and injects GH_TOKEN, but that function does not exist under sh,
#     so hooks and scripts see the global active account instead — routinely MattR3Ci
#     while 3Ci work runs in parallel. This is a WARNING, not a failure: the push
#     itself is governed by (1) and (2) above, and pre-push exports a personal
#     GH_TOKEN for the gh-shaped work that follows. Failing here would block correct
#     pushes every time a work session held the global.
if command -v gh >/dev/null 2>&1; then
    RAW="$(gh api user --jq .login 2>/dev/null || true)"
    if [ -n "$RAW" ] && [ "$RAW" != "$EXPECTED_USER" ]; then
        echo "⚠  gh-account-guard: bare gh resolves to '$RAW' in child processes." >&2
        echo "   Push identity is unaffected (remote pin + credential helper), and this" >&2
        echo "   hook exports a personal GH_TOKEN. For manual gh work here, use:" >&2
        echo "     scripts/gh-personal.sh <args>" >&2
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    echo "" >&2
    echo "   ViLM is a PERSONAL repo. Acting as the work account cross-pollinates" >&2
    echo "   work and personal contexts (Constitution Art. V). Refusing." >&2
    echo "" >&2
    exit 1
fi

exit 0
