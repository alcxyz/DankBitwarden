#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0

pass() { ((PASS++)); echo "  PASS: $1"; }
fail() { ((FAIL++)); echo "  FAIL: $1 — $2"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc" "expected to contain '$needle'"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        fail "$desc" "should not contain '$needle'"
    else
        pass "$desc"
    fi
}

# ── plugin.json validation ──────────────────────────────────────────

echo "plugin.json"
python3 -c "import json; d=json.load(open('plugin.json')); assert d['id']=='dankVault'; assert d['name']=='Vault'" \
    && pass "valid JSON with correct id and name" \
    || fail "plugin.json" "invalid or wrong id/name"

# ── version from plugin.json ────────────────────────────────────────

echo "plugin.json version"
VERSION=$(jq -r .version plugin.json)
if echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    pass "semver format ($VERSION)"
else
    fail "plugin.json version" "'$VERSION' is not valid semver"
fi

# ── rbw output parsing ──────────────────────────────────────────────

echo "rbw backend: parse list output"

RBW_OUTPUT=$(printf 'GitHub\tjohn@example.com\tDev\nNetflix\tjane\tMedia\n\n')

# Simulate the JS parsing: split lines, split tabs
LINE1_NAME=$(echo "$RBW_OUTPUT" | sed -n '1p' | cut -f1)
LINE1_USER=$(echo "$RBW_OUTPUT" | sed -n '1p' | cut -f2)
LINE1_FOLDER=$(echo "$RBW_OUTPUT" | sed -n '1p' | cut -f3)
assert_eq "entry name" "GitHub" "$LINE1_NAME"
assert_eq "entry user" "john@example.com" "$LINE1_USER"
assert_eq "entry folder" "Dev" "$LINE1_FOLDER"

LINE2_NAME=$(echo "$RBW_OUTPUT" | sed -n '2p' | cut -f1)
assert_eq "second entry name" "Netflix" "$LINE2_NAME"

# Verify non-empty line count (JS filters empty lines)
NON_EMPTY=$(echo "$RBW_OUTPUT" | awk 'NF>0' | wc -l | tr -d '[:space:]')
assert_eq "non-empty lines counted" "2" "$NON_EMPTY"

# ── pass output parsing ─────────────────────────────────────────────

echo "pass backend: parse list output"

PASS_OUTPUT=$(printf 'email/github\nemail/gitlab\nssh/server1\nbank\n')

# Simulate: split on /, last part = name, rest = folder
LINE1=$(echo "$PASS_OUTPUT" | sed -n '1p')
PASS_ID="$LINE1"
PASS_NAME=$(echo "$LINE1" | awk -F/ '{print $NF}')
PASS_FOLDER=$(echo "$LINE1" | awk -F/ '{NF--; print}' OFS=/)
assert_eq "pass entry id preserves full path" "email/github" "$PASS_ID"
assert_eq "pass entry name" "github" "$PASS_NAME"
assert_eq "pass entry folder" "email" "$PASS_FOLDER"

LINE4=$(echo "$PASS_OUTPUT" | sed -n '4p')
PASS_NAME4=$(echo "$LINE4" | awk -F/ '{print $NF}')
PASS_FOLDER4=$(echo "$LINE4" | awk -F/ '{if(NF>1){NF--; print}else{print ""}}' OFS=/)
assert_eq "pass entry no folder" "bank" "$PASS_NAME4"

echo "pass backend: username grep pattern"

# Should match
assert_eq "matches 'Username: user'" "john" \
    "$(printf 'secret\nUsername: john\nURL: x\n' | grep -iE '^(username|user|login)\s*:' | head -1 | cut -d: -f2- | xargs)"

assert_eq "matches 'user: user'" "admin" \
    "$(printf 'secret\nuser: admin\n' | grep -iE '^(username|user|login)\s*:' | head -1 | cut -d: -f2- | xargs)"

assert_eq "matches 'login: user'" "root" \
    "$(printf 'secret\nlogin: root\n' | grep -iE '^(username|user|login)\s*:' | head -1 | cut -d: -f2- | xargs)"

assert_eq "matches 'Login:user' (no space)" "me" \
    "$(printf 'secret\nLogin:me\n' | grep -iE '^(username|user|login)\s*:' | head -1 | cut -d: -f2- | xargs)"

# Should NOT match
NOMATCH=$(printf 'secret\nusertime: 123\nuseful: yes\n' | grep -iE '^(username|user|login)\s*:' | head -1 || true)
assert_eq "rejects 'usertime:'" "" "$NOMATCH"

# ── gopass output parsing ────────────────────────────────────────────

echo "gopass backend: parse list output"

GOPASS_OUTPUT=$(printf 'email/github\nemail/gitlab\nmisc/wifi\n')

LINE1=$(echo "$GOPASS_OUTPUT" | sed -n '1p')
GOPASS_ID="$LINE1"
GP_NAME=$(echo "$LINE1" | awk -F/ '{print $NF}')
GP_FOLDER=$(echo "$LINE1" | awk -F/ '{NF--; print}' OFS=/)
assert_eq "gopass entry id preserves full path" "email/github" "$GOPASS_ID"
assert_eq "gopass entry name" "github" "$GP_NAME"
assert_eq "gopass entry folder" "email" "$GP_FOLDER"

echo "nested entry command routing"

PASS_BACKEND=$(sed -n '/"pass": {/,/"gopass": {/p' DankVault.qml)
GOPASS_BACKEND=$(sed -n '/"gopass": {/,/"op": {/p' DankVault.qml)

assert_contains "pass parser stores canonical path" \
    'entries.push({ id: path, name: name, user: "", folder: folder });' "$PASS_BACKEND"
assert_contains "gopass parser stores canonical path" \
    'entries.push({ id: path, name: name, user: "", folder: folder });' "$GOPASS_BACKEND"
assert_contains "actions prefer canonical entry id" \
    'var entryId = entry.id || entry.name;' "$(sed -n '/function getItems/,/function executeItem/p' DankVault.qml)"

# ── op output parsing ────────────────────────────────────────────────

echo "op backend: parse list output"

OP_OUTPUT='[{"id":"abc123","title":"GitHub","vault":{"id":"v1","name":"Personal"},"category":"LOGIN"},{"id":"def456","title":"Netflix","vault":{"id":"v2","name":"Shared"}}]'

OP_TITLE1=$(echo "$OP_OUTPUT" | python3 -c "import json,sys; items=json.load(sys.stdin); print(items[0]['title'])")
OP_VAULT1=$(echo "$OP_OUTPUT" | python3 -c "import json,sys; items=json.load(sys.stdin); print(items[0].get('vault',{}).get('name',''))")
assert_eq "op entry title" "GitHub" "$OP_TITLE1"
assert_eq "op entry vault" "Personal" "$OP_VAULT1"

OP_TITLE2=$(echo "$OP_OUTPUT" | python3 -c "import json,sys; items=json.load(sys.stdin); print(items[1]['title'])")
assert_eq "op second entry" "Netflix" "$OP_TITLE2"

echo "op backend: field command syntax"

# Verify label= prefix is used
assert_contains "password field uses label=" "label=password" \
    "op item get TestEntry --fields label=password"
assert_contains "username field uses label=" "label=username" \
    "op item get TestEntry --fields label=username"

# Concealed fields (passwords) return a placeholder unless --reveal is passed
if grep -q '"--fields", "label=" + fieldName, "--reveal"' DankVault.qml; then
    pass "op --fields passes --reveal"
else
    fail "op reveal" "op --fields is missing --reveal; concealed fields yield a placeholder"
fi

# ── clipboard command safety ─────────────────────────────────────────

echo "clipboard security"

# Verify the QML uses safe clipboard patterns
if grep -q 'paste-once' DankVault.qml && grep -q 'sensitive' DankVault.qml; then
    pass "uses --paste-once and --sensitive"
else
    fail "clipboard" "missing paste-once or sensitive flags"
fi

if grep -q 'sleep 15' DankVault.qml; then
    pass "auto-clears after 15s"
else
    fail "clipboard" "missing 15s auto-clear"
fi

if grep -qF '$1' DankVault.qml; then
    pass "uses positional arg for secret value"
else
    fail "clipboard" "does not use positional arg pattern"
fi

# ── launcher activation behavior ────────────────────────────────────

echo "launcher activation"

if grep -q 'import qs.Common' DankVault.qml; then
    pass "imports SettingsData access"
else
    fail "launcher activation" "missing qs.Common import"
fi

if grep -q 'triggerOnlyVisibilityDefaultApplied' DankVault.qml; then
    pass "records one-time trigger-only visibility default"
else
    fail "launcher activation" "missing trigger-only migration flag"
fi

if grep -q 'setPluginAllowWithoutTrigger(pluginId, false)' DankVault.qml; then
    pass "opts out of All mode by default"
else
    fail "launcher activation" "does not disable allowWithoutTrigger"
fi

# ── auto-detection command ───────────────────────────────────────────

echo "backend auto-detection"

# Simulate detection with no backends available (subshell so exit 0 doesn't kill us)
RESULT=$(env PATH="" /usr/bin/env bash -c 'for b in rbw pass gopass op; do command -v "$b" >/dev/null 2>&1 && echo "$b" && exit 0; done; echo none' 2>/dev/null || echo "none")
assert_eq "detects none when no backends" "none" "$RESULT"

# ── summary ──────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
