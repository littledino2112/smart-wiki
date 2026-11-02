#!/usr/bin/env bash
# detect-transport.sh — discover which vault-mutation transports are available
# on this machine, write a normalized JSON snapshot to .vault-meta/transport.json,
# and pick a preferred transport.
#
# Default (v1.11+): preferred is always `filesystem` — direct Read/Write/Edit tools.
# The vault needs no Obsidian app, CLI, or plugin. Other transports are opt-in:
#   - cli          — Obsidian CLI binary (`obsidian-cli`). Reported when found, never auto-preferred.
#   - mcp-obsidian — REST-API-backed MCP server (Local REST API plugin required).
#   - mcpvault     — Filesystem-backed MCP server (BM25 search; no Obsidian plugin).
# To opt in, set "manual_override": true plus "preferred" / "fallback_chain" in
# transport.json (see wiki/references/transport-fallback.md §Manual override).
#
# Detection never executes the `obsidian` desktop binary: on Linux `obsidian --version`
# launches the Electron app instead of printing a version. MCP servers are not
# auto-detected (calling `claude mcp list` from inside a running claude session has
# reentrancy concerns); their fields stay `{"present": null, "detection": "deferred"}`.
#
# Usage:
#   ./scripts/detect-transport.sh             # detect and write .vault-meta/transport.json
#   ./scripts/detect-transport.sh --peek      # print result to stdout without writing
#   ./scripts/detect-transport.sh --force     # refresh even if existing snapshot is fresh (<7d)
#   ./scripts/detect-transport.sh --quiet     # suppress informational stderr output
#
# Exit codes:
#   0 — success (transport.json written or peeked)
#   2 — vault-meta/ missing and cannot be created
#   3 — unrecognized flag

set -euo pipefail

VAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META_DIR="${VAULT_ROOT}/.vault-meta"
OUTPUT_FILE="${META_DIR}/transport.json"
STALE_AFTER_DAYS=7

MODE="write"
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --peek)  MODE="peek" ;;
    --force) MODE="force" ;;
    --quiet) QUIET=true ;;
    -h|--help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERR: unknown flag: $1" >&2
      exit 3
      ;;
  esac
  shift
done

log() { $QUIET || echo "$@" >&2; }

# json_escape: read stdin and emit a JSON-encoded string (including the
# surrounding double quotes). Used for any untrusted value that lands in the
# transport.json heredoc — newlines, backslashes, control chars in upstream
# binaries (obsidian-cli --version) would otherwise break the JSON.
json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()), end="")'
}

mkdir -p "$META_DIR" || {
  echo "ERR: cannot create .vault-meta/ at $META_DIR" >&2
  exit 2
}

# ── 0. Honor manual_override from existing transport.json ────────────────────
# Users can pin a non-detected transport (mcp-obsidian, mcpvault, or any custom
# value) by editing transport.json to set:
#     "manual_override": true
#     "preferred": "<their-choice>"
#     "fallback_chain": [...]
# Auto-detection still runs (to refresh CLI/Obsidian-running flags for visibility),
# but PREFERRED and CHAIN are preserved from the existing file across both the
# normal write path AND --force runs. Documented at
# wiki/references/transport-fallback.md §Manual override.
MANUAL_OVERRIDE_FLAG=false
MANUAL_OVERRIDE_PREFERRED=""
MANUAL_OVERRIDE_CHAIN=""
if [ -f "$OUTPUT_FILE" ]; then
  MANUAL_PARSE="$(python3 - "$OUTPUT_FILE" 2>/dev/null <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    if data.get("manual_override") is True:
        pref = data.get("preferred", "")
        chain = data.get("fallback_chain", [])
        # Output: line 1 = preferred; line 2 = comma-separated quoted chain entries.
        print(pref)
        print(",".join('"' + str(c) + '"' for c in chain))
except Exception:
    pass
PYEOF
)" || MANUAL_PARSE=""
  if [ -n "${MANUAL_PARSE:-}" ]; then
    MANUAL_OVERRIDE_FLAG=true
    MANUAL_OVERRIDE_PREFERRED="$(printf '%s\n' "$MANUAL_PARSE" | sed -n '1p')"
    MANUAL_OVERRIDE_CHAIN="$(printf '%s\n' "$MANUAL_PARSE" | sed -n '2p')"
    log "manual_override=true; preserving preferred=${MANUAL_OVERRIDE_PREFERRED}"
  fi
fi

# ── Freshness check: skip detection if snapshot is recent ────────────────────
# Snapshots older than schema_version 2 were written when the CLI was
# auto-preferred, so they are always refreshed regardless of age.
SNAPSHOT_SCHEMA=0
if [ -f "$OUTPUT_FILE" ]; then
  SNAPSHOT_SCHEMA="$(python3 - "$OUTPUT_FILE" 2>/dev/null <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(int(json.load(fh).get("schema_version", 0)))
except Exception:
    print(0)
PYEOF
)" || SNAPSHOT_SCHEMA=0
fi
if [ "$MODE" = "write" ] && [ -f "$OUTPUT_FILE" ] && [ "${SNAPSHOT_SCHEMA:-0}" -ge 2 ]; then
  if find "$OUTPUT_FILE" -mtime -${STALE_AFTER_DAYS} -print 2>/dev/null | grep -q .; then
    log "transport.json is fresh (<${STALE_AFTER_DAYS}d). Use --force to refresh."
    cat "$OUTPUT_FILE"
    exit 0
  fi
fi

# ── 1. CLI detection (informational; never changes `preferred`) ──────────────
# Only the dedicated `obsidian-cli` binary counts. The `obsidian` desktop binary
# is deliberately not probed: running it with --version starts the app.
CLI_PRESENT=false
CLI_BINARY=""
CLI_VERSION=""
CLI_VERSION_RAW=""
if command -v obsidian-cli >/dev/null 2>&1; then
  CLI_PRESENT=true
  CLI_BINARY="obsidian-cli"
  # Keep two views of the version: RAW for the human log line, JSON-escaped
  # for the transport.json heredoc. CLI_VERSION below is pre-quoted (includes
  # the surrounding double quotes), so the heredoc emits ${CLI_VERSION}
  # without wrapping quotes.
  CLI_VERSION_RAW="$(obsidian-cli --version 2>/dev/null | head -1 || echo unknown)"
  CLI_VERSION="$(printf '%s' "$CLI_VERSION_RAW" | json_escape || echo '"unknown"')"
fi
# Fallback default when neither binary was found: must still be a valid JSON literal.
if [ -z "$CLI_VERSION" ]; then
  CLI_VERSION='""'
  CLI_VERSION_RAW=""
fi

# ── 2. Obsidian app running? (informational only; CLI works either way) ──────
OBSIDIAN_RUNNING=false
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -if 'obsidian' >/dev/null 2>&1; then
    OBSIDIAN_RUNNING=true
  fi
fi

# ── 3. Compute preferred + fallback chain ────────────────────────────────────
# Filesystem is the default whatever else is installed; cli/MCP are opt-in via
# manual_override (3b).
PREFERRED="filesystem"
CHAIN='"filesystem"'

# ── 3b. Apply manual_override if it was parsed from the existing snapshot ────
# Auto-detected PREFERRED/CHAIN above are overridden so the user's pinned
# transport survives every refresh cycle including --force.
if $MANUAL_OVERRIDE_FLAG; then
  PREFERRED="$MANUAL_OVERRIDE_PREFERRED"
  CHAIN="$MANUAL_OVERRIDE_CHAIN"
fi

# ── 4. Build JSON snapshot ───────────────────────────────────────────────────
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTNAME="$(hostname 2>/dev/null || echo unknown)"

snapshot() {
  cat <<JSON
{
  "schema_version": 2,
  "detected_at": "${TIMESTAMP}",
  "host": "${HOSTNAME}",
  "vault_root": "${VAULT_ROOT}",
  "manual_override": ${MANUAL_OVERRIDE_FLAG},
  "preferred": "${PREFERRED}",
  "fallback_chain": [${CHAIN}],
  "available": {
    "cli": {
      "present": ${CLI_PRESENT},
      "binary": "${CLI_BINARY}",
      "version_string": ${CLI_VERSION},
      "obsidian_app_running": ${OBSIDIAN_RUNNING},
      "note": "opt-in only; set manual_override to prefer it"
    },
    "filesystem": {
      "present": true,
      "vault_root": "${VAULT_ROOT}",
      "note": "default; uses Claude's Read/Write/Edit tools directly"
    },
    "mcp_obsidian": {
      "present": null,
      "detection": "deferred",
      "note": "MCP servers are not auto-detected (opt-in). Configure manually per wiki/references/mcp-setup.md and edit this file by hand if needed."
    },
    "mcpvault": {
      "present": null,
      "detection": "deferred",
      "note": "MCP servers are not auto-detected (opt-in). Configure manually per wiki/references/mcp-setup.md and edit this file by hand if needed."
    }
  }
}
JSON
}

if [ "$MODE" = "peek" ]; then
  snapshot
  exit 0
fi

# Atomic write: stage to .tmp then rename. Avoids partial files if killed mid-write.
TMP="${OUTPUT_FILE}.$$.tmp"
trap 'rm -f "$TMP"' EXIT
snapshot > "$TMP"
mv "$TMP" "$OUTPUT_FILE"
trap - EXIT

log "Wrote: ${OUTPUT_FILE}"
log "Preferred transport: ${PREFERRED}"
log "  Filesystem: default (Read/Write/Edit tools)"
$CLI_PRESENT && log "  CLI:        ${CLI_BINARY} (${CLI_VERSION_RAW}) — opt-in via manual_override"
log "  MCP:        not auto-detected (see wiki/references/mcp-setup.md to configure)"
