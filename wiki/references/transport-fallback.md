---
type: reference
title: "Transport Fallback Decision Tree"
status: evergreen
related:
  - "[[wiki-cli]]"
  - "[[mcp-setup]]"
updated: 2026-11-02
---

# Transport Fallback Decision Tree

claude-obsidian supports four ways to read and mutate vault notes. This document is the canonical decision tree skills consult when picking one.

**Since v1.11, Obsidian is optional.** The default transport is `filesystem` — Claude's own Read/Write/Edit tools on plain Markdown. A vault works with no Obsidian app, CLI, or plugin installed. The Obsidian CLI and the MCP servers are opt-in: they are used only when the user pins one in `transport.json`.

## Quick reference

```
                  ┌─────────────────────────┐
                  │ I need to read/write    │
                  │ a wiki note             │
                  └────────────┬────────────┘
                               │
                               ▼
         ┌─────────────────────────────────────────────┐
         │ Read .vault-meta/transport.json             │
         │ (missing or unreadable → use filesystem)    │
         └─────────────────────────────────────────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
   preferred = "filesystem"          preferred = "cli" / MCP
   (default)                         (opt-in: manual_override)
              │                                 │
              ▼                                 ▼
   ┌────────────────────┐            ┌──────────────────────┐
   │ Read/Write/Edit    │            │ obsidian-cli <op>    │
   │ tools with absolute│            │ or MCP tool call     │
   │ vault paths        │            │                      │
   │                    │            │ Falls through on any │
   │ Always works.      │            │ error to filesystem. │
   └────────────────────┘            └──────────────────────┘
```

## The transports

| # | Transport | When used | Strengths | Weaknesses |
|---|-----------|-----------|-----------|------------|
| 1 | **`filesystem`** | **Default.** Always available; used unless the user opts into something else. | Zero setup. Works on any machine with the repo — no Obsidian required. | No Obsidian-aware features (no resolved Bases, no daily-note logic, no backlink graph). |
| 2 | **`cli`** | Opt-in. User has `obsidian-cli` installed and pins it via `manual_override`. Detection reports the binary but never prefers it. | No MCP, no TLS, no plugins. Obsidian-native search and backlinks. | Desktop-only. Single-vault per invocation. Requires Obsidian. |
| 3 | **`mcp-obsidian`** | Opt-in. User has the Local REST API plugin + an MCP server configured and pins it via `manual_override`. Not auto-detected. | Persistent connection; rich tools (`mcp__obsidian-vault__*`); patch_note primitives. | Requires plugin install + TLS bypass for self-signed cert; reentrancy risk in self-MCP-calls. |
| 4 | **`mcpvault`** | Opt-in. User has `@bitbonsai/mcpvault` configured and pins it via `manual_override`. Not auto-detected. | No Obsidian plugin needed; BM25 search built in. | Filesystem-based — no Obsidian-native features (live render, hot reload). |

## When skills should consult this tree

Any skill that mutates a vault file should follow this pattern at the top:

```python
# Pseudocode for any vault-mutating skill
transport = read_json_or_none(".vault-meta/transport.json")
preferred = transport["preferred"] if transport else "filesystem"
match preferred:
    case "cli":
        result = bash(f'obsidian-cli {operation} "{vault_root}" "{path}"')  # on error → filesystem
    case "mcp-obsidian" | "mcpvault":
        result = mcp_call(operation, path)                                   # on error → filesystem
    case "filesystem" | _:
        result = read_or_write_tool(absolute_path)
```

A missing `transport.json` is not an error and is not a reason to run detection mid-task: it means `filesystem`.

Skills covered by this policy:
- `wiki-ingest` — page creation, frontmatter mutation, manifest updates
- `wiki-query` — page reads (when standard or deep mode pulls full text)
- `wiki-lint` — bulk reads for orphan/link analysis
- `wiki-fold` — fold-page writes
- `save` — session-note writes
- `autoresearch` — source + concept page writes during the research loop

Skills that explicitly bypass the tree (always use direct filesystem):
- `wiki-cli` — this skill IS the CLI wrapper; recursion is meaningless
- `defuddle` — operates on HTTP-fetched content, not vault state
- `obsidian-markdown` / `obsidian-bases` / `canvas` — reference skills, do not mutate the vault

## Detection and refresh

`scripts/detect-transport.sh` writes `.vault-meta/transport.json`. It always sets `preferred: "filesystem"` unless a manual override is present. It reports whether `obsidian-cli` is installed (informational only) and never executes the `obsidian` desktop binary — on Linux, `obsidian --version` launches the app instead of printing a version.

The snapshot is rewritten only if it is older than 7 days (`STALE_AFTER_DAYS=7`), or if it predates schema version 2 (snapshots from v1.10 and earlier, which could auto-prefer `cli`). To force a refresh:

```bash
bash scripts/detect-transport.sh --force
```

## Manual override (opting in)

To use the Obsidian CLI or an MCP transport instead of the filesystem default:

1. Open `.vault-meta/transport.json` in any editor (run `bash scripts/detect-transport.sh` first if it does not exist).
2. Set `"preferred": "cli"` (or `"mcp-obsidian"`, `"mcpvault"`, or any custom value).
3. Set `"fallback_chain": ["cli", "filesystem"]` (or your preferred order — keep `filesystem` last).
4. Add a `"manual_override": true` field at the top level so the detection script knows not to clobber your `preferred` + `fallback_chain` on next run.

The detection script parses the existing transport.json BEFORE running auto-detection. When `manual_override` is `true`, the script re-runs auto-detection only to refresh `available.cli.*` and `available.cli.obsidian_app_running` (so the human log line stays accurate), but preserves the user's `preferred` and `fallback_chain` choices across every cycle — including `--force` runs and post-staleness refreshes. The `manual_override` field itself round-trips through the snapshot, so the override survives indefinitely.

To go back to the default, edit the file and either set `"manual_override": false` or delete the field; then run `bash scripts/detect-transport.sh --force` to reset `preferred` to `filesystem` right away (otherwise the old `preferred` stays in the file — and is honoured by skills — until the 7-day refresh).

## See also

- Detection script: [`scripts/detect-transport.sh`](../../scripts/detect-transport.sh)
- CLI recipe reference: [`skills/wiki-cli/SKILL.md`](../../skills/wiki-cli/SKILL.md)
- Legacy 4-option MCP setup: [`skills/wiki/references/mcp-setup.md`](../../skills/wiki/references/mcp-setup.md) (still authoritative for MCP configuration steps)
