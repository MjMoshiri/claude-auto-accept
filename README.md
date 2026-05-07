# auto-accept

A Claude Code plugin that uses an LLM to auto-accept permission requests based on a session policy you define.

## How it works

1. You set a policy via environment variable, per-session policy file, or through [Claude-Tab](https://github.com/MjMoshiri/Claude-Tab)
2. When Claude Code asks for permission, the plugin classifies the request and either:
   - **Defers to you** if the agent is asking *you* a question (clarification, plan approval), or
   - Pipes the tool details + your policy to a fast `claude -p` call to decide **allow** or **ask** (fall through to normal dialog)

The plugin never denies on its own — it either auto-allows or defers to you.

## Request classification

Not every `PreToolUse` / `PermissionRequest` event is a request to *do* something. Some are the agent asking *you* a question. The plugin treats these three categories distinctly:

| Category | Example tools | Behavior |
|---|---|---|
| **User-decision** — the tool **is** the agent → user channel | `AskUserQuestion`, `ExitPlanMode` | **Always** falls through to the normal dialog. Bypasses *every* policy mode, including `*` allow-all. |
| **Execution** — performs an action with side effects | `Bash`, `Edit`, `Write`, `WebFetch`, MCP write tools | Subject to policy. |
| **Read** — retrieves information without modifying state | `Read`, `Grep`, `Glob` | Subject to policy. |

The user-decision short-circuit fires *before* policy resolution, so e.g.

```
"Do you want me to use Redis or Kafka?" (AskUserQuestion)
```

is **never** auto-answered, even when the session is set to `*` allow-all. The dialog is shown to the user.

The judge prompt also does its own classification step for unknown / MCP tools. If the judge tags a call as `user_decision`, the plugin falls through regardless of the judge's `decision` field — defense in depth against MCP servers that expose ask-style tools.

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
| **Allow All** | `*` | All *executable* tool calls auto-accepted (user-decision tools still defer) |

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

**Allow everything (executable tools only — clarification questions still go to you):**
```bash
AUTO_ACCEPT_POLICY="*" claude
```

## License

Copyright (C) 2026 MohammadJavad Moshiri

This project is licensed under the GNU Affero General Public License,
version 3 or later. See [LICENSE](LICENSE) for details.
