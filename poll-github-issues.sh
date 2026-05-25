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

if [[ "$LOG_ENABLED" == true ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Logging to $LOG_FILE"
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

    if $COMMAND "$NUMBER"; then
      log "[$label] ✓ Command succeeded for #$NUMBER"
    else
      log "[$label] ✗ Command failed for #$NUMBER (exit $?)"
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
