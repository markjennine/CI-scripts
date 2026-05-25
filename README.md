# CI-scripts

A collection of useful scripts to manage a CI pipeline.

## Scripts

### `poll-github-issues.sh`

Polls a GitHub repository for updated open issues and runs a command against each one.

**Usage:**
```bash
./poll-github-issues.sh [options] <owner> <repo> <interval_seconds> <command>
```

**Options:**

| Flag | Description |
|------|-------------|
| `--log-file <path>` | Write output to this file as well as stdout. Defaults to `./poll-github-issues.log`. |
| `--no-log` | Disable file logging entirely (stdout only). |
| `--all-on-startup` | Run the command against all currently open issues before entering the poll loop. |

**Examples:**
```bash
# Poll every 10 seconds, run review-issue.sh for each updated issue
./poll-github-issues.sh my-org my-repo 10 "./review-issue.sh"

# Also process all existing open issues on startup
./poll-github-issues.sh --all-on-startup my-org my-repo 10 "./review-issue.sh"

# Custom log file
./poll-github-issues.sh --log-file /var/log/ci.log my-org my-repo 10 "./review-issue.sh"
```

The command is called with the issue number appended, e.g. `./review-issue.sh 42`.

**Requirements:** `gh` CLI (authenticated) and `jq`.

---

## Requirements

- [GitHub CLI (`gh`)](https://cli.github.com) — installed and authenticated
- `jq`
