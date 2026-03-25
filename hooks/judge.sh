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

Based ONLY on the policy above, should this tool call be allowed?

Think briefly, then put your final answer inside <answer> tags as a JSON object:
<answer>{\"decision\": \"allow\", \"reason\": \"brief reason\"}</answer>

Rules:
- \"allow\" → clearly permitted by the policy
- \"ask\"   → not covered, ambiguous, or potentially risky (let the user decide)

When in doubt, choose \"ask\"."

# Use stream-json to extract text content — works around a claude -p bug
# where the result field is empty when the model uses extended thinking.
# Unset CLAUDE_TABS_SESSION_ID so the judge subprocess doesn't trigger
# hooks back to Claude-Tab under the parent session.
# Redirect stdin from /dev/null since the hook already consumed it.
JUDGE_RESPONSE=$(CLAUDE_TABS_SESSION_ID="" claude -p "$PROMPT" --model "$MODEL" \
  --output-format stream-json --verbose < /dev/null 2>/dev/null \
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
  REASON=$(echo "$ANSWER_BLOCK" | jq -r '.reason // "auto-accept policy"' 2>/dev/null) || REASON="auto-accept policy"
fi

# Fallback: try parsing the whole response as JSON
if [ -z "${DECISION:-}" ] || [ "$DECISION" = "null" ]; then
  DECISION=$(echo "$JUDGE_RESPONSE" | jq -r '.decision' 2>/dev/null) || true
  REASON=$(echo "$JUDGE_RESPONSE" | jq -r '.reason // "auto-accept policy"' 2>/dev/null) || REASON="auto-accept policy"
fi

# Last resort: grep for a JSON object anywhere in the response
if [ -z "${DECISION:-}" ] || [ "$DECISION" = "null" ]; then
  EXTRACTED=$(echo "$JUDGE_RESPONSE" | grep -o '{[^}]*}' | head -1) || true
  DECISION=$(echo "$EXTRACTED" | jq -r '.decision' 2>/dev/null) || exit 0
  REASON=$(echo "$EXTRACTED" | jq -r '.reason // "auto-accept policy"' 2>/dev/null) || REASON="auto-accept policy"
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
