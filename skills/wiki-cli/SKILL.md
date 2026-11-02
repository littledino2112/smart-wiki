---
name: wiki-cli
description: "Vault transport reference for claude-obsidian. The default transport is the filesystem (Claude's Read/Write/Edit tools) — no Obsidian app, CLI, or plugin required. This skill also wraps the Obsidian CLI (`obsidian-cli`) as an opt-in transport for users who pin it in .vault-meta/transport.json. Triggers on: wiki-cli, obsidian cli, obsidian read, obsidian write, obsidian search, daily note, obsidian create, obsidian append, vault transport, which transport, transport detection, obsidian command line."
allowed-tools: Read Bash
---

# wiki-cli: Transport Layer

Since v1.11, claude-obsidian's default transport is the **filesystem**: Claude's Read/Write/Edit tools on plain Markdown. The vault needs no Obsidian app, CLI, or plugin. The **Obsidian CLI** is an opt-in transport for users who want Obsidian-native search, backlinks, and Bases views; it is used only when pinned in `.vault-meta/transport.json`. This skill is the recipe reference for both.

**Substrate preference (v1.7+)**: This skill is a self-contained fallback. **Prefer `kepano/obsidian-skills`** (by Steph Ango, Obsidian CEO) as the authoritative substrate — its `obsidian-cli` skill is the canonical CLI reference for any Agent-Skills runtime. If you see an `obsidian-cli` skill available without the `claude-obsidian:` namespace, that is kepano's version: use it. The recipes below are provided so claude-obsidian remains functional when kepano's marketplace is not installed. Install kepano: `claude plugin marketplace add kepano/obsidian-skills`.

---

## If you opt in: CLI vs MCP

| Concern | MCP (Options A/B) | Obsidian CLI |
|---|---|---|
| Install | Local REST API plugin + MCP server config | Built into Obsidian 1.12+ |
| Auth | API key + TLS bypass (`NODE_TLS_REJECT_UNAUTHORIZED=0`) | None — direct subprocess |
| Latency | HTTP round-trip per call | In-process binary |
| Failure mode | Plugin disabled → silent breakage | Binary missing → loud `command -v` failure |
| Reentrancy | Self-MCP-calls inside Claude session can deadlock | Pure subprocess, safe |
| Mobile / headless | Limited | Limited (CLI is desktop-only too) |

Both lose to the filesystem default on setup: they only work where Obsidian (CLI) or an MCP server is installed and configured. On headless servers, mobile, or any machine without Obsidian, stay on filesystem.

---

## Detection

Optionally, at vault setup, run:

```bash
bash scripts/detect-transport.sh
```

This writes `.vault-meta/transport.json` with the schema:

```json
{
  "schema_version": 2,
  "manual_override": false,
  "preferred": "filesystem",
  "fallback_chain": ["filesystem"],
  "available": {
    "cli": {"present": false, "binary": "", "version_string": ""},
    "filesystem": {"present": true},
    "mcp_obsidian": {"present": null, "detection": "deferred"},
    "mcpvault": {"present": null, "detection": "deferred"}
  }
}
```

`preferred` is always `filesystem` unless the user has set `manual_override`. Detection reports whether `obsidian-cli` is installed but never prefers it, and never executes the `obsidian` desktop binary (on Linux, `obsidian --version` launches the app).

**Read this file before any non-trivial vault mutation.** If it is missing, use filesystem — do not run detection mid-task just to pick a transport. The decision tree lives at `wiki/references/transport-fallback.md`.

### Opting in to the CLI

Edit `.vault-meta/transport.json` and set:

```json
{
  "manual_override": true,
  "preferred": "cli",
  "fallback_chain": ["cli", "filesystem"]
}
```

Detection preserves these fields on every refresh. Delete `manual_override` (or set it to `false`) to return to filesystem.

---

## Recipes (filesystem default; CLI form for opt-in users)

Each recipe shows the filesystem form first — use it unless `preferred` is `cli`. If a CLI call fails, fall back to the filesystem form. Variable substitution: `$VAULT` is the absolute vault root; `$NOTE` is a vault-relative path like `wiki/concepts/Foo.md`.

### Read a note
```bash
# Filesystem: Claude's Read tool with absolute path
# Read $VAULT/$NOTE

# CLI (opt-in)
obsidian-cli read "$VAULT" "$NOTE"
```

### Create or overwrite a note
```bash
# Filesystem: Claude's Write tool with absolute path
# Write $VAULT/$NOTE with the desired content string

# CLI (opt-in)
obsidian-cli write "$VAULT" "$NOTE" < /path/to/content.md
```

### Append to a note
```bash
# Filesystem: Read $VAULT/$NOTE, append, Write back (or Edit)

# CLI (opt-in)
echo "additional content" | obsidian-cli append "$VAULT" "$NOTE"
```

### Search note content
```bash
# Filesystem: ripgrep (or Claude's Grep tool)
rg --type=md "<query>" "$VAULT/wiki/"

# CLI (opt-in; uses Obsidian's own search ranking)
obsidian-cli search "$VAULT" "<query>"
```

### Today's daily note (if Daily Notes plugin is enabled)
```bash
# Filesystem: compute the path
NOTE="$VAULT/wiki/daily/$(date +%Y-%m-%d).md"

# CLI (opt-in)
obsidian-cli daily:today "$VAULT"
obsidian-cli daily:append "$VAULT" "captured at $(date)"
```

### Patch a frontmatter property
```bash
# Filesystem: read frontmatter, parse, mutate, rewrite (Edit on the single line is usually enough)
# (use mcp__obsidian-vault__update_frontmatter if an MCP transport is pinned)

# CLI (opt-in)
obsidian-cli property:set "$VAULT" "$NOTE" status "evergreen"
```

### List backlinks for a page
```bash
# Filesystem: ripgrep for wikilink references
rg --type=md "\[\[$(basename "$NOTE" .md)" "$VAULT/wiki/"

# CLI (opt-in)
obsidian-cli backlinks "$VAULT" "$NOTE"
```

### Open a Bases (.base) file's resolved view
```bash
# Filesystem: read the .base file directly; no resolved view is available without Obsidian itself

# CLI (opt-in; returns the resolved row list; supplements obsidian-bases skill which handles the .base file's YAML)
obsidian-cli bases "$VAULT" "$NOTE"
```

### Tags + bookmarks (CLI only)
```bash
obsidian-cli tags "$VAULT"
obsidian-cli bookmarks "$VAULT"
```

---

## When CLI is NOT the right choice (even if opted in)

- **Mobile (iOS Share extension)**: filesystem write into `.raw/` is the only path; CLI is desktop-only.
- **CI / headless ingest jobs**: filesystem with manual frontmatter parsing.
- **Cross-vault operations**: CLI binds to one vault root per invocation; for federation, fall back to filesystem walks.
- **Live edits while Obsidian is mid-save**: rare race; CLI handles it correctly but in pathological cases the v1.7 `wiki-lock.sh` advisory locks (see [skills/wiki-fold/](../wiki-fold/SKILL.md) and `agents/wiki-ingest.md`) should be acquired first.

---

## Cross-reference

- Decision tree: [`wiki/references/transport-fallback.md`](../../wiki/references/transport-fallback.md)
- Legacy MCP options (A/B/C/D): [`skills/wiki/references/mcp-setup.md`](../wiki/references/mcp-setup.md)
- Concurrency policy (v1.7+): [`skills/wiki-ingest/SKILL.md`](../wiki-ingest/SKILL.md) §Concurrency
- Detection script: [`scripts/detect-transport.sh`](../../scripts/detect-transport.sh)

---

## How to think (10-principle mapping)

When working on this skill, apply the 10-principle loop. See [`skills/think/SKILL.md`](../think/SKILL.md) for the canonical framework.

| # | Principle | Application here |
|---|-----------|-------------------|
| 1 | OBSERVE (ext) | Read `.vault-meta/transport.json` if it exists. Check for `obsidian-cli` with `command -v` only — never execute the `obsidian` desktop binary to probe it. |
| 2 | OBSERVE (int) | Don't push the user toward the CLI because it happens to be installed — filesystem is the default; the CLI is their choice to make. |
| 3 | LISTEN | If `manual_override: true` is set in transport.json, the user has spoken — preserve their `preferred` and `fallback_chain`. |
| 4 | THINK | Filesystem unless overridden; freshness check before recomputing. A missing snapshot means filesystem, not an error. |
| 5 | CONNECT (lat) | How does this transport choice affect every other skill's write? Six downstream skills depend on this snapshot. |
| 6 | CONNECT (sys) | Schema stability of transport.json matters more than feature richness — consumers parse the JSON via simple shell idioms. |
| 7 | FEEL | When an opted-in CLI/MCP call fails, say so and fall back to filesystem rather than stopping the task. |
| 8 | ACCEPT | Filesystem is the default, not a degraded mode. Admit when CLI doesn't exist; don't fabricate a binary that isn't there. |
| 9 | CREATE | Write transport.json atomically (temp + rename). Round-trip `manual_override` every cycle. |
| 10 | GROW | As MCP support matures, auto-detection should cover the deferred tiers. Track that as v1.7.x scope. |
