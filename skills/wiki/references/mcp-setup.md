# MCP Setup

MCP lets Claude read and write vault notes directly without copy-paste. Four options ordered from simplest to most featureful.

> [!tip] Recommendation
> **None of these are required.** Since v1.11 the plugin's default transport is the filesystem (Claude's Read/Write/Edit tools), which needs no Obsidian app, CLI, or plugin. Set one of these up only if you want Obsidian-native features, then pin it in `.vault-meta/transport.json` with `"manual_override": true` (see `wiki/references/transport-fallback.md` §Manual override). If you do opt in and have **Obsidian v1.12 or newer**, start with **Option D: Obsidian CLI** — no MCP server, no plugins, no TLS workarounds.

---

## Step 1: Install the Local REST API Plugin

You must do this in Obsidian (Claude cannot do it programmatically):

1. Obsidian > Settings > Community Plugins > Turn off Restricted Mode
2. Browse > Search "Local REST API" > Install > Enable
3. Settings > Local REST API > Copy the API key

The plugin runs on `https://127.0.0.1:27124` with a self-signed certificate.

Test it:
```bash
curl -sk -H "Authorization: Bearer <YOUR_KEY>" https://127.0.0.1:27124/
```

You should get a JSON response with vault info.

---

## Option A: mcp-obsidian (REST API based)

Uses MarkusPfundstein's mcp-obsidian. Requires the Local REST API plugin running.

```bash
claude mcp add-json obsidian-vault '{
  "type": "stdio",
  "command": "uvx",
  "args": ["mcp-obsidian"],
  "env": {
    "OBSIDIAN_API_KEY": "<YOUR_KEY>",
    "OBSIDIAN_HOST": "127.0.0.1",
    "OBSIDIAN_PORT": "27124",
    "NODE_TLS_REJECT_UNAUTHORIZED": "0"
  }
}' --scope user
```

> [!warning] Security
> `NODE_TLS_REJECT_UNAUTHORIZED: "0"` **disables TLS certificate verification process-wide** for the MCP server. It is required here because the Local REST API plugin uses a self-signed certificate. This is acceptable for `127.0.0.1` (localhost) connections only. Never use this setting for any non-loopback connection. If you are uncomfortable with the global TLS bypass, prefer **Option D (Obsidian CLI)** or **Option B (filesystem-based)** which avoid this entirely.

Capabilities: read notes, write notes, search, patch frontmatter fields, append under headings.

---

## Option B: MCPVault (filesystem based)

No Obsidian plugin needed. Reads the vault directory directly.

```bash
claude mcp add-json obsidian-vault '{
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "@bitbonsai/mcpvault@latest", "/absolute/path/to/your/vault"]
}' --scope user
```

Replace `/absolute/path/to/your/vault` with the actual vault path.

Tools available: `search_notes` (BM25), `read_note`, `create_note`, `update_note`, `get_frontmatter`, `update_frontmatter`, `list_all_tags`, `read_multiple_notes`.

---

## Option C: Direct REST API via curl

No MCP needed. Use curl in bash throughout the session. See `rest-api.md` for all commands.

---

## Option D: Obsidian CLI (recommended opt-in for v1.12+)

Obsidian shipped a native CLI in v1.12 (2026). It exposes vault operations directly to the terminal. No REST API plugin, no MCP server, no self-signed certs, no TLS workarounds. Claude calls it through the Bash tool.

**Check if available:**
```bash
which obsidian-cli 2>/dev/null && obsidian-cli --version
# Don't probe the desktop app instead (`obsidian --version`, `flatpak run md.obsidian.Obsidian ...`):
# on Linux that launches Obsidian rather than printing a version.
```

**Common operations:**
```bash
# List all notes in a folder
obsidian-cli list /path/to/vault wiki/

# Read a note
obsidian-cli read /path/to/vault wiki/index.md

# Create or update a note
obsidian-cli write /path/to/vault wiki/new-note.md < content.md

# Search notes by content
obsidian-cli search /path/to/vault "query term"
```

**Why choose this (if you opt in)**:
- No community plugin to install (but Obsidian itself must be installed)
- No MCP server process to manage
- No TLS certificate bypass needed
- Survives Obsidian restarts (no persistent connection)
- Desktop only — on headless machines stay on the filesystem default

To use it, pin it in `.vault-meta/transport.json`: `"manual_override": true`, `"preferred": "cli"`, `"fallback_chain": ["cli", "filesystem"]`.

**When to use Options A/B/C instead**: If you need persistent semantic search, frontmatter patching, or are on Obsidian < v1.12.

The `kepano/obsidian-skills` repo includes an `obsidian-cli` skill that wraps these commands as reusable patterns. Install it alongside this plugin for first-class CLI support.

---

## Use `--scope user`

Both MCP options use `--scope user` so the vault is available across all Claude Code projects, not just the one where you ran the command.

---

## Verification

After setup:

```bash
claude mcp list               # confirm the server appears
claude mcp get obsidian-vault # confirm the path or URL is correct
```

In a Claude Code session, type `/mcp` to check connection status.

Then test: "List all notes in my wiki folder."
