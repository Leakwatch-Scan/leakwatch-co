#!/bin/sh
# leakwatch-hook.sh — refuses a commit that carries a secret.
#
# One script, three callers:
#
#   sh leakwatch-hook.sh            git pre-commit hook (.git/hooks/pre-commit)
#   sh leakwatch-hook.sh --claude   Claude Code PreToolUse hook on Bash
#   sh leakwatch-hook.sh --cursor   Cursor beforeShellExecution hook
#
# It posts the lines the commit ADDS to POST /api/v1/scan/content. The content
# is scanned in memory and discarded; nothing but counts is kept server-side.
# Removed lines are not sent: the commit that deletes a key must go through.
#
# Requires: git, curl, jq, awk, and LEAKWATCH_API_KEY in the environment.
#
# When the scan cannot run (no key, no network, daily quota spent), the commit
# is ALLOWED with a warning: a local hook that blocks you offline gets removed
# within a week. Set LEAKWATCH_STRICT=1 to block instead. Either way, keep the
# CI gate — a hook is a convenience, the pipeline is the control.
set -u

MODE=${1:-git}
API=${LEAKWATCH_API:-https://leakwatch.net/api/v1/scan/content}

# ---------------------------------------------------------------- verdicts --
allow() {
  [ "$MODE" = "--cursor" ] && printf '{"permission":"allow"}\n'
  exit 0
}

# $1: message. Same text for the human and for the agent.
deny() {
  case "$MODE" in
    --cursor)
      jq -cn --arg m "$1" '{permission:"deny", user_message:$m, agent_message:$m}' ;;
    --claude)
      # Exit 2 blocks the tool call; stderr is what Claude reads.
      printf '%s\n' "$1" >&2; exit 2 ;;
    *)
      printf '%s\n' "$1" >&2; exit 1 ;;
  esac
  exit 0
}

# The scan could not run. $1: why.
unavailable() {
  if [ "${LEAKWATCH_STRICT:-0}" = "1" ]; then
    deny "LeakWatch: commit blocked, the scan could not run ($1). LEAKWATCH_STRICT=1 is set."
  fi
  printf 'LeakWatch: scan skipped, commit NOT checked (%s).\n' "$1" >&2
  allow
}

for tool in git curl jq awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    # Without jq a Cursor verdict cannot be built: print the allow by hand.
    printf 'LeakWatch: scan skipped, %s is not installed.\n' "$tool" >&2
    [ "$MODE" = "--cursor" ] && printf '{"permission":"allow"}\n'
    [ "${LEAKWATCH_STRICT:-0}" = "1" ] && [ "$MODE" != "--cursor" ] && exit 2
    exit 0
  }
done

# ------------------------------------------------- is this a commit at all --
# WIDE=1 means the index is not yet what will be committed: the command stages
# things itself (`git add … && git commit`, `git commit -a`), so the hook has
# to look at the working tree instead.
WIDE=0
if [ "$MODE" = "--claude" ] || [ "$MODE" = "--cursor" ]; then
  INPUT=$(cat)
  if [ "$MODE" = "--claude" ]; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  else
    CMD=$(printf '%s' "$INPUT" | jq -r '.command // empty' 2>/dev/null)
  fi
  DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  if [ -n "$DIR" ] && [ -d "$DIR" ]; then
    cd "$DIR" || unavailable "cannot enter $DIR"
  fi

  # `git commit`, with optional global options in between (`git -C x commit`).
  printf '%s' "$CMD" | grep -Eq \
    '(^|[^[:alnum:]_./-])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit([[:space:];&|]|$)' \
    || allow

  if printf '%s' "$CMD" | grep -Eq \
    '(^|[^[:alnum:]_./-])git[[:space:]]+([^;&|]*[[:space:]])?(add|stage|rm|mv)([[:space:]]|$)|commit[^;&|]*[[:space:]](-[A-Za-z]*a[A-Za-z]*|--all)([[:space:]]|$)'
  then
    WIDE=1
  fi
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || allow

# ------------------------------------------------------- what gets scanned --
TMP=$(mktemp -d 2>/dev/null) || unavailable "mktemp failed"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Added lines only, raw bytes: no context, colour, external diff or textconv.
# (xargs below cannot call a function, so it repeats these flags.)
gdiff() { git diff --unified=0 --no-color --no-ext-diff --no-textconv "$@"; }
{
  if [ "$WIDE" = "1" ]; then
    # Everything that differs from HEAD, plus files git does not track yet
    # (an `add -A` would take them). Ignored files stay out.
    gdiff HEAD 2>/dev/null || gdiff --cached
    git ls-files --others --exclude-standard -z \
      | xargs -0 -I{} git diff --unified=0 --no-color --no-ext-diff --no-textconv --no-index -- /dev/null {} 2>/dev/null
  else
    gdiff --cached
  fi
} > "$TMP/diff"

# Keep the added lines only, and remember where each one lives: the API
# answers with a line number in what it was sent, which means nothing to
# whoever has to fix the file. Hunk sizes are counted rather than guessed from
# the first characters, so an added line that itself starts with "++ " is not
# mistaken for a file header.
awk -v content="$TMP/content" -v map="$TMP/map" '
  old > 0 || new > 0 {
    c = substr($0, 1, 1)
    if (c == "-") { old--; next }
    if (c == "+") { print substr($0, 2) > content; print file ":" line > map; line++; new--; next }
    if (c == " ") { old--; new--; line++; next }
    next                                    # "\ No newline at end of file"
  }
  /^\+\+\+ / {
    file = substr($0, 5); sub(/\t.*$/, "", file); sub(/^b\//, "", file); next
  }
  /^@@ / {
    split($2, o, ","); split($3, n, ",")
    old = (o[2] == "") ? 1 : o[2] + 0
    new = (n[2] == "") ? 1 : n[2] + 0
    line = substr(n[1], 2) + 0
  }
' "$TMP/diff"

# Nothing added: nothing to leak, and no quota unit spent.
[ -s "$TMP/content" ] || allow

[ -n "${LEAKWATCH_API_KEY:-}" ] || unavailable "LEAKWATCH_API_KEY is not set"

# ---------------------------------------------------------------- the call --
STATUS=$(jq -Rs '{content: ., filename: "pre-commit"}' "$TMP/content" \
  | curl -sS --max-time 20 -o "$TMP/response" -w '%{http_code}' \
      -X POST "$API" \
      -H "Authorization: Bearer $LEAKWATCH_API_KEY" \
      -H "Content-Type: application/json" \
      --data-binary @- 2>"$TMP/curl-error") || unavailable "LeakWatch unreachable"

if [ "$STATUS" != "200" ]; then
  DETAIL=$(jq -r '.detail // empty' "$TMP/response" 2>/dev/null | head -c 200)
  unavailable "HTTP $STATUS${DETAIL:+: $DETAIL}"
fi

COUNT=$(jq -r '.count' "$TMP/response" 2>/dev/null)
case "$COUNT" in
  ''|*[!0-9]*) unavailable "unexpected response from the API" ;;
esac

[ "$COUNT" -eq 0 ] && allow

# Type, severity, place. Never the value: this text ends up in a terminal
# scrollback or in an agent transcript.
jq -r '.secrets[] | "\(.line)\t\(.type) (\(.severity))"' "$TMP/response" > "$TMP/hits"
FINDINGS=$(awk -F '\t' '
  NR == FNR { where[FNR] = $0; next }
  { printf "  %s  %s\n", (($1 in where) ? where[$1] : "line " $1), $2 }
' "$TMP/map" "$TMP/hits")

deny "LeakWatch: commit blocked, $COUNT secret(s) in the lines being added:
$FINDINGS
Take the value out of the file (environment variable or secret manager), then commit again. If it was ever pushed or shared, rotate it. If this is a false positive, say so to the person you work with instead of bypassing the hook."
