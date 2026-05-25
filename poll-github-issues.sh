#!/usr/bin/env bash
# poll-github-issues.sh
# Polls GitHub for updated issues and runs a command against each one.
#
# Usage:
#   ./poll-github-issues.sh [options] <owner> <repo> <interval_seconds> <command>
#
# Options:
#   --log-file <path>   Write all log output to this file as well as stdout.
#                       Defaults to ./poll-github-issues.log if not specified.
#   --no-log            Disable file logging entirely (stdout only).
#   --all-on-startup    Run the command against ALL currently open issues before
#                       entering the normal poll loop.
#
# The command is called with the issue number as the last argument. E.g.:
#   ./poll-github-issues.sh my-org parkrun-mcp-v2 10 "./review-issue.sh"
#   → runs: ./review-issue.sh 42
#
# Output files (when logging is enabled):
#   <log-file>               Plain-text human-readable log (default: ./poll-github-issues.log)
#   <log-file>.results.jsonl One JSON object per line for each command run, containing
#                            the raw output plus issue metadata. Query with jq or jless:
#                              jq 'select(.issue_number == 17)' poll-github-issues.log.results.jsonl
#                              jq -s '.' poll-github-issues.log.results.jsonl | jless
#
# Requirements:
#   - gh CLI installed and authenticated (https://cli.github.com)
#   - jq installed

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────────────────────

LOG_FILE="./poll-github-issues.log"  # default
LOG_ENABLED=true
ALL_ON_STARTUP=false

# Parse optional flags before positional args
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --log-file)
      LOG_FILE="${2:?--log-file requires a path}"
      shift 2
      ;;
    --no-log)
      LOG_ENABLED=false
      shift
      ;;
    --all-on-startup)
      ALL_ON_STARTUP=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

OWNER="${1:-}"
REPO="${2:-}"
INTERVAL="${3:-10}"
COMMAND="${4:-}"

if [[ -z "$OWNER" || -z "$REPO" || -z "$COMMAND" ]]; then
  echo "Usage: $0 [--log-file <path>] [--no-log] [--all-on-startup] <owner> <repo> <interval_seconds> <command>"
  echo "  <command> will be called with the issue number appended, e.g.:"
  echo "  $0 my-org my-repo 10 \"./handle-issue.sh\""
  exit 1
fi

# ── Logging setup ─────────────────────────────────────────────────────────────
# Tee all stdout+stderr to the log file if enabled.
# Command output (JSON blobs) is captured separately into a .results.jsonl sidecar.

RESULTS_FILE=""
if [[ "$LOG_ENABLED" == true ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  RESULTS_FILE="${LOG_FILE}.results.jsonl"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Logging to $LOG_FILE"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Command results → $RESULTS_FILE"
fi

# ── State file ────────────────────────────────────────────────────────────────
# Stores the ISO-8601 timestamp of the last successful poll so we only process
# issues updated since then.

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/poll-github-issues"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/${OWNER}_${REPO}.last_checked"

if [[ ! -f "$STATE_FILE" ]]; then
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STATE_FILE"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [init] No previous state found. Starting watermark from now."
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

# Run the command, capture its stdout, append to the results file (if enabled),
# and log a compact one-line summary to the main log.
run_command_for_issues() {
  local issues="$1"
  local label="$2"

  if [[ -z "$issues" ]]; then
    log "[$label] No issues to process."
    return
  fi

  while IFS= read -r ISSUE; do
    NUMBER=$(echo "$ISSUE" | jq -r '.number')
    TITLE=$(echo  "$ISSUE" | jq -r '.title')
    UPDATED=$(echo "$ISSUE" | jq -r '.updatedAt')

    log "[$label] Issue #$NUMBER updated at $UPDATED — \"$TITLE\""
    log "[$label] Running: $COMMAND $NUMBER"

    # Capture command output; keep stderr visible in the main log.
    CMD_OUTPUT=$($COMMAND "$NUMBER" 2>&1) && CMD_EXIT=0 || CMD_EXIT=$?

    if [[ "$CMD_EXIT" -eq 0 ]]; then
      log "[$label] ✓ Command succeeded for #$NUMBER"
    else
      log "[$label] ✗ Command failed for #$NUMBER (exit $CMD_EXIT)"
    fi

    # If the output looks like a JSON object, log a summary line and append the
    # full payload (augmented with issue metadata) to the results file.
    # If it isn't JSON, echo it directly so nothing is silently swallowed.
    if echo "$CMD_OUTPUT" | jq -e . > /dev/null 2>&1; then
      # Extract a few useful fields for the summary line (tolerate missing keys).
      SUMMARY=$(echo "$CMD_OUTPUT" | jq -r '
        [ "subtype=\(.subtype // "?")",
          "turns=\(.num_turns // "?")",
          "duration=\(if .duration_ms then "\(.duration_ms)ms" else "?" end)",
          "cost=$\(.total_cost_usd // "?")"
        ] | join(" ")
      ')
      log "[$label] ↳ $SUMMARY"

      if [[ -n "$RESULTS_FILE" ]]; then
        # Merge issue metadata into the result object before appending.
        echo "$CMD_OUTPUT" | jq -c \
          --arg phase   "$label" \
          --argjson num "$NUMBER" \
          --arg title  "$TITLE" \
          --arg logged_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
          '. + {issue_number: $num, issue_title: $title, phase: $phase, logged_at: $logged_at}' \
          >> "$RESULTS_FILE"
      fi
    else
      # Plain-text output — print it so it appears in the main log.
      echo "$CMD_OUTPUT"
    fi

  done <<< "$issues"
}

# ── Startup: process all open issues ─────────────────────────────────────────

if [[ "$ALL_ON_STARTUP" == true ]]; then
  log "Fetching all open issues for $OWNER/$REPO …"

  ALL_ISSUES=$(
    gh issue list \
      --repo "$OWNER/$REPO" \
      --state open \
      --json number,title,updatedAt \
      --limit 100 \
      --jq 'sort_by(.updatedAt) | .[]'
  ) || { log "ERROR: Failed to fetch issues on startup. Continuing to poll loop."; ALL_ISSUES=""; }

  COUNT=$(echo "$ALL_ISSUES" | grep -c '"number"' || true)
  log "Found $COUNT open issue(s) — processing all before entering poll loop."
  run_command_for_issues "$ALL_ISSUES" "startup"
fi

# ── Main loop ─────────────────────────────────────────────────────────────────

log "Polling $OWNER/$REPO every ${INTERVAL}s. Press Ctrl-C to stop."

while true; do
  SINCE=$(cat "$STATE_FILE")
  NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  log "Checking for open issues updated since $SINCE …"

  ISSUES=$(
    gh issue list \
      --repo "$OWNER/$REPO" \
      --state open \
      --json number,title,updatedAt \
      --limit 100 \
      --search "is:open updated:>=${SINCE}" \
      --jq 'sort_by(.updatedAt) | .[]'
  ) || { log "ERROR: gh issue list failed. Retrying next cycle."; sleep "$INTERVAL"; continue; }

  run_command_for_issues "$ISSUES" "poll"

  # Advance the watermark so we don't re-process the same issues.
  echo "$NOW" > "$STATE_FILE"

  sleep "$INTERVAL"
done
