#!/usr/bin/env bash
set -euo pipefail

for tool in gpg pass gopass; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing $tool; run with:" >&2
        echo "  nix-shell -p gnupg pass gopass --run ./test-integration.sh" >&2
        exit 1
    fi
done

TEST_ROOT=$(mktemp -d -t dankvault-test.XXXXXXXX)
TEST_GNUPG="$TEST_ROOT/gnupg"
TEST_STORE="$TEST_ROOT/password-store"
TEST_CONFIG="$TEST_ROOT/config"
TEST_DATA="$TEST_ROOT/data"
TEST_CACHE="$TEST_ROOT/cache"

cleanup() {
    chmod -R u+w "$TEST_ROOT" 2>/dev/null || true
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -m 700 "$TEST_GNUPG"
mkdir -p "$TEST_CONFIG" "$TEST_DATA" "$TEST_CACHE"

export GNUPGHOME="$TEST_GNUPG"
export PASSWORD_STORE_DIR="$TEST_STORE"
export XDG_CONFIG_HOME="$TEST_CONFIG"
export XDG_DATA_HOME="$TEST_DATA"
export XDG_CACHE_HOME="$TEST_CACHE"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GOPASS_NO_REMINDER=true

TEST_IDENTITY="DankVault Integration Test <dankvault-test@example.invalid>"
gpg --batch --passphrase '' --quick-generate-key "$TEST_IDENTITY" default default never >/dev/null 2>&1
TEST_FINGERPRINT=$(gpg --batch --with-colons --list-secret-keys "$TEST_IDENTITY" \
    | awk -F: '$1 == "fpr" { print $10; exit }')

pass init "$TEST_FINGERPRINT" >/dev/null
printf '%s\n' \
    'nested-pass-secret' \
    'username: nested-user' \
    'otpauth://totp/DankVault:test?secret=JBSWY3DPEHPK3PXP&issuer=DankVault' \
    | pass insert --multiline 'work/email/github' >/dev/null

LIST_OUTPUT=$(find "$PASSWORD_STORE_DIR" -name '*.gpg' -printf '%P\n' \
    | sed 's/\.gpg$//' \
    | sort)
if [ "$LIST_OUTPUT" != 'work/email/github' ]; then
    echo "FAIL: pass list did not preserve the nested path: $LIST_OUTPUT" >&2
    exit 1
fi

PASS_PASSWORD=$(pass show 'work/email/github' | head -1)
PASS_USERNAME=$(pass show 'work/email/github' \
    | grep -iE '^(username|user|login)\s*:' \
    | head -1 \
    | cut -d: -f2- \
    | xargs)
if [ "$PASS_PASSWORD" != 'nested-pass-secret' ] || [ "$PASS_USERNAME" != 'nested-user' ]; then
    echo "FAIL: pass could not retrieve fields using the nested path" >&2
    exit 1
fi
if pass show 'github' >/dev/null 2>&1; then
    echo "FAIL: pass unexpectedly resolved the basename-only lookup" >&2
    exit 1
fi

GOPASS_LIST=$(gopass ls --flat)
if ! printf '%s\n' "$GOPASS_LIST" | grep -qxF 'work/email/github'; then
    echo "FAIL: gopass list did not preserve the nested path: $GOPASS_LIST" >&2
    exit 1
fi

GOPASS_PASSWORD=$(gopass show -o 'work/email/github')
GOPASS_USERNAME=$(gopass show 'work/email/github' username)
GOPASS_OTP=$(gopass otp 'work/email/github')
if [ "$GOPASS_PASSWORD" != 'nested-pass-secret' ]; then
    echo "FAIL: gopass could not retrieve the password using the nested path" >&2
    exit 1
fi
if [ "$GOPASS_USERNAME" != 'nested-user' ]; then
    echo "FAIL: gopass could not retrieve the username using the nested path" >&2
    exit 1
fi
if ! printf '%s\n' "$GOPASS_OTP" | grep -qE '^[0-9]{6}$'; then
    echo "FAIL: gopass could not retrieve TOTP using the nested path" >&2
    exit 1
fi
if gopass show -o 'github' >/dev/null 2>&1; then
    echo "FAIL: gopass unexpectedly resolved the basename-only lookup" >&2
    exit 1
fi

echo "PASS: isolated pass and gopass nested-path integration"
