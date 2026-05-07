# Changelog

## v1.3.0

- **Never auto-accept clarification questions.** `AskUserQuestion` and `ExitPlanMode` are now classified as user-decision tools and always fall through to the normal permission dialog, regardless of policy. Previously, `*` allow-all (and any policy that broadly approved tool calls) would silently auto-accept agent → user questions like *"Should I use Redis or Kafka?"* — answering them on the user's behalf.
- Three-tier classifier: every tool call is categorized as **user_decision** (defers to user), **execution** (subject to policy), or **read** (subject to policy). The static short-circuit handles built-in user-decision tools; the judge prompt now performs the same classification for unknown/MCP tools, with a defense-in-depth check that overrides the judge if it tags a call as `user_decision`.
- Judge response now includes a `category` field alongside `decision` and `reason`.

## v1.2.1

- Fix empty judge response with thinking-enabled models — `claude -p` returns an empty `result` field when the model uses extended thinking (e.g. haiku 4.5). The judge now uses `stream-json` parsing to extract the actual text content.
- Fix judge prompt leaking into Claude-Tab status bar — unset `CLAUDE_TABS_SESSION_ID` before the judge `claude -p` call so it doesn't trigger hooks back to Claude-Tab under the parent session.
- Fix silent crash on grep fallback — the last-resort JSON extraction could crash the script due to `set -e` + `pipefail` when no JSON was found.
- Add `python3` as a dependency (for parsing streamed judge output).

## v1.2.0

- Allow/ask only model — the judge never denies on its own, it either auto-allows or falls through to the normal permission dialog.
- Allow-all shortcut — write `*` to the policy file to auto-accept everything without a judge call.
- Three session states: Off (empty file), Policy (natural language), Allow All (`*`).

## v1.1.0

- Support `CLAUDE_TABS_SESSION_ID` environment variable for per-session policy file lookup.
- File-based per-session policies at `~/.claude/auto-accept-policies/{session_id}`, enabling mid-session policy changes from external UIs like Claude-Tab.

## v1.0.0

- Initial release.
- LLM-powered judge using `claude -p` to evaluate tool calls against a user-defined policy.
- `<answer>` tag parsing for reliable judge response extraction.
- Configurable via `AUTO_ACCEPT_POLICY`, `AUTO_ACCEPT_MODEL`, and `AUTO_ACCEPT_MODE` environment variables.
