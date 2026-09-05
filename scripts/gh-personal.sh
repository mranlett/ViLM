#!/usr/bin/env sh
# gh-personal.sh — run `gh` pinned to the PERSONAL account, whatever is globally active.
#
# WHY THIS EXISTS
# `gh` stores ONE active account per host in ~/.config/gh/hosts.yml. It is global
# mutable state shared by every shell and every session on this machine. Work in a
# 3Ci repo running as MattR3Ci flips it, and any `gh` command here silently acts as
# the work account — a Constitution Art. V breach with no error to notice.
# This is not hypothetical: it happened mid-session on 2026-09-05, between an
# explicit `gh auth switch` and the very next push.
#
# `gh auth switch` is the wrong remedy: it fights the other session for the same
# global, and whoever ran last wins. Instead this resolves the personal account's
# OWN token from the keyring per invocation and passes it via GH_TOKEN, which takes
# precedence over the active account. The global is never read and never written,
# so the work session is left completely undisturbed.
#
# USAGE
#   scripts/gh-personal.sh issue list
#   scripts/gh-personal.sh pr view 81
#   scripts/gh-personal.sh whoami          # local verb: print the acting login
#
# The token is resolved fresh each call and never written to disk, history or env
# beyond the child process.

set -eu

EXPECTED="mranlett"
HOST="github.com"

if ! command -v gh >/dev/null 2>&1; then
    echo "gh-personal: gh is not installed." >&2
    exit 127
fi

TOKEN="$(gh auth token --hostname "$HOST" --user "$EXPECTED" 2>/dev/null || true)"

if [ -z "$TOKEN" ]; then
    echo "" >&2
    echo "❌ gh-personal: no stored token for '$EXPECTED' on $HOST." >&2
    echo "   Log in once (this does NOT disturb the active account):" >&2
    echo "     gh auth login --hostname $HOST" >&2
    echo "" >&2
    exit 1
fi

# Local verb: prove which identity the token actually resolves to.
if [ "${1:-}" = "whoami" ]; then
    ACTING="$(GH_TOKEN="$TOKEN" gh api user --jq .login 2>/dev/null || true)"
    if [ "$ACTING" != "$EXPECTED" ]; then
        echo "❌ gh-personal: token for '$EXPECTED' resolves to '$ACTING'. Refusing." >&2
        exit 1
    fi
    echo "$ACTING"
    exit 0
fi

GH_TOKEN="$TOKEN" exec gh "$@"
