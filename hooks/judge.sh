#!/usr/bin/env bash
set -euo pipefail

# ── Dependencies ─────────────────────────────────────────────────────
for cmd in jq claude python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "auto-accept: '$cmd' not found, skipping" >&2
    exit 0
  fi
done

# ── Read hook input ──────────────────────────────────────────────────
INPUT=$(cat)

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
SESSION_ID="${CLAUDE_TABS_SESSION_ID:-$(echo "$INPUT" | jq -r '.session_id // ""')}"

# ── Tier 1: user-decision tools — always defer to the human ──────────
# These tools ARE the agent asking the user. Auto-allowing them silently
# answers questions the user never saw. They bypass policy entirely
# (including `*` allow-all).
#
# - AskUserQuestion: clarification with multiple-choice options
# - ExitPlanMode: presents a plan for approval
#
# We do NOT include EnterPlanMode (the agent's internal mode transition),
# nor pure side-effect tools (Bash/Edit/Write/etc.), nor Read/Grep/Glob
# (information retrieval — no user decision involved).
USER_DECISION_TOOLS_REGEX='^(AskUserQuestion|ExitPlanMode)$'
if [[ "$TOOL_NAME" =~ $USER_DECISION_TOOLS_REGEX ]]; then
  # Fall through to the normal permission dialog so the user actually sees
  # and answers the agent's question.
  exit 0
fi

# ── Resolve policy: file-based (per-session) → env var (global) ─────
# File-based policies allow mid-session changes from external UIs
# (e.g. Claude-Tab) by writing to ~/.claude/auto-accept-policies/{session_id}
# CLAUDE_TABS_SESSION_ID env var overrides the session_id from hook input
POLICY="${AUTO_ACCEPT_POLICY:-}"
if [ -n "$SESSION_ID" ]; then
  POLICY_FILE="$HOME/.claude/auto-accept-policies/$SESSION_ID"
  if [ -f "$POLICY_FILE" ]; then
    POLICY=$(cat "$POLICY_FILE")
  fi
fi

# No policy → no-op (normal ask cycle)
if [ -z "$POLICY" ]; then
  exit 0
fi

# "*" → allow all without calling the judge
# (User-decision tools were already filtered out above.)
if [ "$POLICY" = "*" ]; then
  if [ "$HOOK_EVENT" = "PreToolUse" ]; then
    jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"Auto-accepted: allow-all mode"}}'
  else
    jq -n '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
  fi
  exit 0
fi

# ── Mode check ───────────────────────────────────────────────────────
# "permission" = only act on PermissionRequest (default)
# "all"        = act on both PreToolUse and PermissionRequest
MODE="${AUTO_ACCEPT_MODE:-permission}"
if [ "$MODE" = "permission" ] && [ "$HOOK_EVENT" = "PreToolUse" ]; then
  exit 0
fi

# ── Build a compact summary of tool input ────────────────────────────
# Truncate large fields (file content, old/new strings) to keep the
# judge prompt small and fast.
TOOL_INPUT=$(echo "$INPUT" | jq -c '
  .tool_input
  | if .content    and (.content    | length) > 300 then .content    = (.content[:300]    + " ...[truncated]") else . end
  | if .old_string and (.old_string | length) > 300 then .old_string = (.old_string[:300] + " ...[truncated]") else . end
  | if .new_string and (.new_string | length) > 300 then .new_string = (.new_string[:300] + " ...[truncated]") else . end
')

# ── Call the judge ───────────────────────────────────────────────────
MODEL="${AUTO_ACCEPT_MODEL:-haiku}"

PROMPT="You are a permission gate for a Claude Code session.

The user set this policy for the session:
<policy>
${POLICY}
</policy>

Claude Code wants to use this tool:
- Tool: ${TOOL_NAME}
- Input: ${TOOL_INPUT}

Step 1 — Classify the tool call into one of three categories:
  (a) USER_DECISION — the tool's purpose is to ask the human a question or
      request explicit human approval (e.g. presents choices, requests
      confirmation, surfaces a plan for review). Examples: AskUserQuestion,
      ExitPlanMode, an MCP tool literally named like 'prompt_user' /
      'confirm_action' / 'ask_*'. The tool is the agent→user channel itself,
      not an action on the system.
  (b) EXECUTION — the tool performs an action with side effects: runs a
      command, edits a file, writes data, calls an API, fetches a URL.
  (c) READ — the tool only retrieves information without modifying state
      (Read, Grep, Glob, list dirs, search docs).

Step 2 — Decide:
  - If category is USER_DECISION → answer must be \"ask\". The user must see
    and answer the agent's question themselves; you cannot answer for them.
  - Otherwise (EXECUTION or READ) → judge the call against the policy.
      \"allow\" → clearly permitted by the policy
      \"ask\"   → not covered, ambiguous, or potentially risky

When in doubt, choose \"ask\".

Think briefly, then put your final answer inside <answer> tags as a JSON object:
<answer>{\"category\": \"user_decision|execution|read\", \"decision\": \"allow|ask\", \"reason\": \"brief reason\"}</answer>"

# Use stream-json to extract text content — works around a claude -p bug
# where the result field is empty when the model uses extended thinking.
# Unset CLAUDE_TABS_SESSION_ID so the judge subprocess doesn't trigger
# hooks back to Claude-Tab under the parent session.
# Redirect stdin from /dev/null since the hook already consumed it.
JUDGE_RESPONSE=$(CLAUDE_TABS_SESSION_ID="" claude -p "$PROMPT" --model "$MODEL" \
  --output-format stream-json --verbose --no-session-persistence < /dev/null 2>/dev/null \
  | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        if d.get('type') == 'assistant':
            for c in d.get('message', {}).get('content', []):
                if c.get('type') == 'text':
                    print(c['text'], end='')
    except: pass
") || exit 0

# ── Parse the judge response ─────────────────────────────────────────
# Extract JSON from <answer> tags — the most reliable path
ANSWER_BLOCK=$(echo "$JUDGE_RESPONSE" | sed -n 's/.*<answer>\(.*\)<\/answer>.*/\1/p' | head -1)

if [ -n "$ANSWER_BLOCK" ]; then
  DECISION=$(echo "$ANSWER_BLOCK" | jq -r '.decision' 2>/dev/null) || true
  CATEGORY=$(echo "$ANSWER_BLOCK" | jq -r '.category // ""' 2>/dev/null) || CATEGORY=""
  REASON=$(echo "$ANSWER_BLOCK" | jq -r '.reason // "auto-accept policy"' 2>/dev/null) || REASON="auto-accept policy"
fi

# Fallback: try parsing the whole response as JSON
if [ -z "${DECISION:-}" ] || [ "$DECISION" = "null" ]; then
  DECISION=$(echo "$JUDGE_RESPONSE" | jq -r '.decision' 2>/dev/null) || true
  CATEGORY=$(echo "$JUDGE_RESPONSE" | jq -r '.category // ""' 2>/dev/null) || CATEGORY=""
  REASON=$(echo "$JUDGE_RESPONSE" | jq -r '.reason // "auto-accept policy"' 2>/dev/null) || REASON="auto-accept policy"
fi

# Last resort: grep for a JSON object anywhere in the response
if [ -z "${DECISION:-}" ] || [ "$DECISION" = "null" ]; then
  EXTRACTED=$(echo "$JUDGE_RESPONSE" | grep -o '{[^}]*}' | head -1) || true
  DECISION=$(echo "$EXTRACTED" | jq -r '.decision' 2>/dev/null) || exit 0
  CATEGORY=$(echo "$EXTRACTED" | jq -r '.category // ""' 2>/dev/null) || CATEGORY=""
  REASON=$(echo "$EXTRACTED" | jq -r '.reason // "auto-accept policy"' 2>/dev/null) || REASON="auto-accept policy"
fi

# Defense-in-depth: if the judge mis-classified an EXECUTION tool but
# (against the rules) returned "allow" on a USER_DECISION category, force
# fall-through. The static regex above catches the built-in cases; this
# protects against MCP tools that look like questions to the LLM.
if [ "${CATEGORY:-}" = "user_decision" ]; then
  exit 0
fi

# ── Emit hook output ─────────────────────────────────────────────────
case "$DECISION" in
  allow)
    if [ "$HOOK_EVENT" = "PreToolUse" ]; then
      jq -n --arg reason "$REASON" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "allow",
          permissionDecisionReason: ("Auto-accepted: " + $reason)
        }
      }'
    else
      jq -n '{
        hookSpecificOutput: {
          hookEventName: "PermissionRequest",
          decision: {
            behavior: "allow"
          }
        }
      }'
    fi
    ;;
  *)
    # "ask", "deny", or unrecognized → fall through to normal permission dialog
    exit 0
    ;;
esac
