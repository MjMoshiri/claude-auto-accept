# auto-accept

A Claude Code plugin that uses an LLM to auto-accept permission requests based on a session policy you define.

## How it works

1. You set a policy via environment variable, per-session policy file, or through [Claude-Tab](https://github.com/MjMoshiri/Claude-Tab)
2. When Claude Code asks for permission, the plugin pipes the tool details + your policy to a fast `claude -p` call
3. The judge LLM decides: **allow** or **ask** (fall through to normal dialog)

The plugin never denies on its own — it either auto-allows or defers to you.

## Install

```bash
/plugin marketplace add MjMoshiri/claude-auto-accept
/plugin install auto-accept@auto-accept
```

## Modes

The plugin supports three states per session:

| State | Policy file content | Behavior |
|-------|-------------------|----------|
| **Off** | empty | Normal permission dialogs (plugin is a no-op) |
| **Policy** | natural language text | Judge LLM evaluates each request against your policy |
| **Allow All** | `*` | All tool calls auto-accepted, no judge call |

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AUTO_ACCEPT_POLICY` | No | — | Natural language policy (global fallback) |
| `AUTO_ACCEPT_MODEL` | No | `haiku` | Model for the judge call (`haiku`, `sonnet`, `opus`) |
| `AUTO_ACCEPT_MODE` | No | `permission` | `permission` = only permission dialogs, `all` = every tool call |
| `CLAUDE_TABS_SESSION_ID` | No | — | Override session ID for policy file lookup (set automatically by Claude-Tab) |

### File-based policy (per-session)

Policy files live at:

```
~/.claude/auto-accept-policies/{session_id}
```

This enables [Claude-Tab](https://github.com/MjMoshiri/Claude-Tab) to set and change policies mid-session. The file content determines the mode:

- **Empty file** — off (normal ask cycle)
- **`*`** — allow all
- **Any other text** — used as the policy for the judge

**Priority:** file-based policy > `AUTO_ACCEPT_POLICY` env var. If neither exists, the plugin is a no-op.

## Claude-Tab Integration

When used with [Claude-Tab](https://github.com/MjMoshiri/Claude-Tab):

- Policy files are created automatically for each session
- Toggle between Off / Policy / Allow All from the badge or right-click menu
- Profiles can have a default auto-accept policy
- Each session is isolated via `CLAUDE_TABS_SESSION_ID`

## Fallback behavior

If the judge call fails (timeout, API error, bad response), the plugin silently falls through to the normal permission dialog. You're never locked out.

## Requirements

- `claude` CLI (for the `-p` judge call)
- `jq` (for JSON parsing)
- `python3` (for parsing streamed judge output)

## Examples

**Refactoring session:**
```bash
AUTO_ACCEPT_POLICY="Allow all file reads, edits, writes, glob, and grep. Allow running tests and linters. Ask for git commits, pushes, or destructive operations." claude
```

**Read-only exploration:**
```bash
AUTO_ACCEPT_MODE=all AUTO_ACCEPT_POLICY="Allow Read, Glob, Grep, and read-only Bash commands. Ask for anything that modifies files." claude
```

**Allow everything:**
```bash
AUTO_ACCEPT_POLICY="*" claude
```
