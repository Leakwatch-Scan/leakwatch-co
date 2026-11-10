#!/bin/sh
# leakwatch.sh — fails the build if the incoming diff contains a secret.
#
# Posts the diff to POST /api/v1/scan/content. The content is scanned in
# memory and discarded: nothing but counts is kept server-side (they feed the
# CI/CD tab of your dashboard).
#
# Usage:    sh leakwatch.sh [base]          (default base: origin/main)
# Requires: git, curl, jq, LEAKWATCH_API_KEY in the environment, and a clone
#           deep enough to contain the base. A depth-1 clone has nothing to
#           diff against and would always report zero findings.
#
# Exit codes: 0 no secret, 1 secret(s) found, 2 the scan could not run.
set -eu

: "${LEAKWATCH_API_KEY:?set LEAKWATCH_API_KEY in your CI secrets}"

API=${LEAKWATCH_API:-https://leakwatch.net/api/v1/scan/content}
BASE=${1:-origin/main}

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  echo "LeakWatch: base '$BASE' not found. Fetch full history (fetch-depth: 0 / GIT_DEPTH: 0)." >&2
  exit 2
fi

DIFF=$(git diff --unified=0 --no-color --no-ext-diff "$BASE"...HEAD)

# An empty diff is a green build: no need to spend a quota unit.
if [ -z "$DIFF" ]; then
  echo "LeakWatch: empty diff against $BASE, nothing to scan."
  exit 0
fi

# --fail-with-body is what keeps this honest: without it curl exits 0 on an
# HTTP error, jq reads an empty count, and the build goes green because the
# call failed.
RESPONSE=$(printf '%s' "$DIFF" \
  | jq -Rs '{content: ., filename: "diff"}' \
  | curl -sS --fail-with-body --max-time 30 \
      -X POST "$API" \
      -H "Authorization: Bearer $LEAKWATCH_API_KEY" \
      -H "Content-Type: application/json" \
      --data-binary @-) || {
  echo "LeakWatch: the scan could not run." >&2
  printf '%s\n' "${RESPONSE:-}" >&2
  exit 2
}

COUNT=$(printf '%s' "$RESPONSE" | jq -r '.count' 2>/dev/null || true)

# A body that is not the expected JSON (proxy, error page) must fail the job,
# not pass as "zero secrets".
case "$COUNT" in
  ''|*[!0-9]*)
    echo "LeakWatch: unexpected response from the API." >&2
    printf '%s\n' "$RESPONSE" >&2
    exit 2
    ;;
esac

if [ "$COUNT" -ne 0 ]; then
  # Type, severity and line only. Never the value: this ends up in CI logs.
  FINDINGS=$(printf '%s' "$RESPONSE" | jq -r '.secrets[] | "  \(.type) (\(.severity)) at diff line \(.line)"')
  echo "LeakWatch: $COUNT secret(s) in this diff."
  echo "$FINDINGS"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### LeakWatch: $COUNT secret(s) in this diff"
      echo
      echo '```'
      echo "$FINDINGS"
      echo '```'
      echo
      echo "Remove the value, then rotate the key: https://leakwatch.net/secrets"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

echo "LeakWatch: no secret in this diff."
