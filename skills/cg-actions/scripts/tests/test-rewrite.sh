#!/bin/sh
# Fixture tests for rewrite_workflows.py's line-targeted replacement.
#
# rewrite_workflows.py promises a minimal diff: "It only ever changes the action
# reference. It never touches `with:` inputs, `env`, permissions, or anything
# else." These cases hold it to that, and cover the matching rules the mapping
# relies on: version-qualified keys beating bare names, version gaps left alone,
# the hardened namespace never rewritten twice, and local actions skipped.
#
# Dependencies: sh, python3 (override with PYTHON=), grep. No network, no gh.

set -u
PY="${PYTHON:-python3}"

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
failcount=0
ok() { pass=$((pass + 1)); echo "ok - $1"; }
fail() { failcount=$((failcount + 1)); echo "FAIL - $1"; }

SHA=0123456789abcdef0123456789abcdef01234567

cat > "$tmp/map.json" <<'EOF'
{
  "actions/checkout@v4": "chainguard-actions/actions-checkout@v4.2.2",
  "actions/setup-node": "chainguard-actions/actions-setup-node@v6.0.0",
  "docker/build-push-action": "chainguard-actions/build-push-action@v6.10.0"
}
EOF

# rewrite WORKFLOW_BODY -> rewritten file at $tmp/out/.github/workflows/ci.yml
rewrite() {
  rm -rf "$tmp/repo" "$tmp/out"
  mkdir -p "$tmp/repo/.github/workflows"
  printf '%s' "$1" > "$tmp/repo/.github/workflows/ci.yml"
  "$PY" "$SCRIPTS/rewrite_workflows.py" --mapping "$tmp/map.json" \
    --out-dir "$tmp/out" --repo "$tmp/repo" > "$tmp/rw.out" 2> "$tmp/rw.err"
  echo $? > "$tmp/rw.rc"
}

got() { cat "$tmp/out/.github/workflows/ci.yml" 2>/dev/null; }

# --- the matching rules -----------------------------------------------------

rewrite 'jobs:
  b:
    steps:
      - uses: actions/checkout@v4
'
if got | grep -q 'uses: chainguard-actions/actions-checkout@v4.2.2'; then
  ok "version-qualified key rewrites the matching version"
else fail "version-qualified key did not rewrite"; fi

rewrite 'jobs:
  b:
    steps:
      - uses: actions/checkout@v3
'
if got | grep -q 'uses: actions/checkout@v3'; then
  ok "version gap left alone (only @v4 is mapped)"
else fail "rewrote a version the mapping does not cover"; fi

rewrite 'jobs:
  b:
    steps:
      - uses: actions/setup-node@v4
      - uses: actions/setup-node@v2
'
if [ "$(got | grep -c 'chainguard-actions/actions-setup-node')" -eq 2 ]; then
  ok "bare-name key rewrites every version"
else fail "bare-name key did not rewrite every version"; fi

rewrite 'jobs:
  b:
    steps:
      - uses: chainguard-actions/actions-setup-node@v6.0.0
'
if got | grep -q 'uses: chainguard-actions/actions-setup-node@v6.0.0'; then
  ok "already-hardened reference is not rewritten again"
else fail "rewrote a reference already in the hardened namespace"; fi

rewrite 'jobs:
  b:
    steps:
      - uses: ./.github/actions/local
      - uses: ./actions/setup-node
'
if ! got | grep -q 'chainguard-actions'; then
  ok "local action paths are never rewritten"
else fail "rewrote a local action path"; fi

rewrite 'jobs:
  b:
    env:
      ACTIONS_STEP_DEBUG: true
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - run: echo uses: actions/checkout@v4
'
if got | grep -q 'fetch-depth: 0' && got | grep -q 'ACTIONS_STEP_DEBUG' \
   && got | grep -q 'run: echo uses: actions/checkout@v4'; then
  ok "with:, env:, and a uses: inside a run: string are untouched"
else fail "touched something other than the action reference"; fi

# --- "only ever changes the action reference" -------------------------------

rewrite 'jobs:
  b:
    steps:
      - uses: actions/checkout@v4  # required for fork PRs
'
if got | grep -q 'required for fork PRs'; then
  ok "a trailing comment survives the rewrite"
else fail "a trailing comment was deleted (only the reference should change)"; fi

rewrite 'jobs:
  b:
    steps:
      - uses: "actions/checkout@v4"
'
if got | grep -q '"chainguard-actions/actions-checkout@v4.2.2"'; then
  ok "quoting style is preserved"
else fail "dropped the quotes around the value"; fi

printf 'jobs:\r\n  b:\r\n    steps:\r\n      - uses: actions/checkout@v4\r\n      - run: make\r\n' > "$tmp/crlf.yml"
rm -rf "$tmp/repo" "$tmp/out"
mkdir -p "$tmp/repo/.github/workflows"
cp "$tmp/crlf.yml" "$tmp/repo/.github/workflows/ci.yml"
"$PY" "$SCRIPTS/rewrite_workflows.py" --mapping "$tmp/map.json" \
  --out-dir "$tmp/out" --repo "$tmp/repo" > "$tmp/rw.out" 2> "$tmp/rw.err"
if [ "$(got | grep -c "$(printf '\r$')")" -eq 5 ]; then
  ok "CRLF line endings are preserved on the rewritten line"
else fail "rewritten line lost its CR: the file now has mixed line endings"; fi

# A version comment describes the SHA it is pinned beside. Replace the SHA and
# the comment is stale: it must not survive pointing at the old version.
rewrite "jobs:
  b:
    steps:
      - uses: actions/setup-node@$SHA  # v4.0.0
"
if got | grep -q 'chainguard-actions/actions-setup-node' && ! got | grep -q 'v4\.0\.0'; then
  ok "a stale version comment does not survive a SHA-pin rewrite"
else fail "kept a version comment describing the replaced SHA"; fi

echo "$pass passed, $failcount failed"
[ "$failcount" -eq 0 ]
