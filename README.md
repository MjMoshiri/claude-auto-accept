# auto-accept

A Claude Code plugin that uses an LLM to auto-accept or deny permission requests based on a session policy you define.

## How it works

1. You set a policy via environment variable before starting a Claude Code session
2. When Claude Code asks for permission, the plugin pipes the tool details + your policy to a fast `claude -p` call
3. The judge LLM decides: **allow**, **deny**, or **ask** (fall through to normal dialog)

## Install

```bash
claude plugin add https://github.com/MjMoshiri/claude-auto-accept
```

## Usage

```bash
# Set your policy and start a session
AUTO_ACCEPT_POLICY="This is a refactoring session. Accept everything except commits, stashes, or irreversible file deletions." claude

# Use a different judge model
AUTO_ACCEPT_MODEL=sonnet AUTO_ACCEPT_POLICY="Allow all file edits and reads. Deny any network requests." claude

# Gate ALL tool calls (not just permission requests)
AUTO_ACCEPT_MODE=all AUTO_ACCEPT_POLICY="Only allow read operations." claude
```

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AUTO_ACCEPT_POLICY` | Yes | — | Natural language policy for the session |
| `AUTO_ACCEPT_MODEL` | No | `haiku` | Model for the judge call (`haiku`, `sonnet`, `opus`) |
| `AUTO_ACCEPT_MODE` | No | `permission` | `permission` = only PermissionRequest hooks, `all` = PreToolUse + PermissionRequest |

## Modes

- **`permission`** (default): Only intercepts when Claude Code would normally show you a permission dialog. Fast and cheap — the judge only runs when you'd be interrupted anyway.
- **`all`**: Intercepts every tool call before execution. Lets you deny things that would normally be auto-allowed (e.g., blocking reads in sensitive directories). More judge calls = more latency and cost.

## Fallback behavior

If the judge call fails (timeout, API error, bad response), the plugin silently falls through to the normal permission dialog. You're never locked out.

## Requirements

- `claude` CLI (for the `-p` judge call)
- `jq` (for JSON parsing)

## Examples

**Refactoring session:**
```bash
AUTO_ACCEPT_POLICY="This is a code refactoring session. Allow all file reads, edits, writes, glob, and grep operations. Allow running tests and linters. Deny any git commits, stashes, pushes, or destructive file operations like rm -rf." claude
```

**Read-only exploration:**
```bash
AUTO_ACCEPT_MODE=all AUTO_ACCEPT_POLICY="Read-only session. Allow Read, Glob, Grep, and Bash commands that only read (cat, ls, find, git log, git diff). Deny any Write, Edit, or Bash commands that modify files." claude
```

**Testing session:**
```bash
AUTO_ACCEPT_POLICY="Allow running any test commands (npm test, pytest, jest, cargo test). Allow file reads and edits. Deny git push, deploy commands, and anything touching production configs." claude
```
