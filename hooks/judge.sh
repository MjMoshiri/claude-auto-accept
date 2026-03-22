#!/usr/bin/env bash
set -euo pipefail

# ── Guard: no policy → no-op ────────────────────────────────────────
if [ -z "${AUTO_ACCEPT_POLICY:-}" ]; then
  exit 0
fi

# ── Dependencies ─────────────────────────────────────────────────────
for cmd in jq claude; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "auto-accept: '$cmd' not found, skipping" >&2
    exit 0
  fi
done

# ── Read hook input ──────────────────────────────────────────────────
INPUT=$(cat)

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')

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
${AUTO_ACCEPT_POLICY}
</policy>

Claude Code wants to use this tool:
- Tool: ${TOOL_NAME}
- Input: ${TOOL_INPUT}

Based ONLY on the policy above, should this tool call be allowed?

Respond with ONLY a JSON object — no markdown, no explanation outside the JSON:
{\"decision\": \"allow\", \"reason\": \"brief reason\"}

Rules:
- \"allow\"  → clearly permitted by the policy
- \"deny\"   → clearly violates the policy
- \"ask\"    → ambiguous or not covered by the policy (let the user decide)

When in doubt, choose \"ask\"."

JUDGE_RESPONSE=$(claude -p "$PROMPT" --model "$MODEL" 2>/dev/null) || exit 0

# ── Parse the judge response ─────────────────────────────────────────
# Try direct parse first, then try extracting JSON from markdown fences
DECISION=$(echo "$JUDGE_RESPONSE" | jq -r '.decision' 2>/dev/null) || true

if [ -z "$DECISION" ] || [ "$DECISION" = "null" ]; then
  # Try extracting JSON from markdown code fences
  EXTRACTED=$(echo "$JUDGE_RESPONSE" | sed -n '/^```/,/^```/p' | grep -v '^```' | head -5)
  if [ -n "$EXTRACTED" ]; then
    DECISION=$(echo "$EXTRACTED" | jq -r '.decision' 2>/dev/null) || true
    JUDGE_RESPONSE="$EXTRACTED"
  fi
fi

if [ -z "$DECISION" ] || [ "$DECISION" = "null" ]; then
  # Last resort: grep for a JSON object in the response
  EXTRACTED=$(echo "$JUDGE_RESPONSE" | grep -o '{[^}]*}' | head -1)
  DECISION=$(echo "$EXTRACTED" | jq -r '.decision' 2>/dev/null) || exit 0
  JUDGE_RESPONSE="$EXTRACTED"
fi

REASON=$(echo "$JUDGE_RESPONSE" | jq -r '.reason // "auto-accept policy"' 2>/dev/null) || REASON="auto-accept policy"

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
  deny)
    if [ "$HOOK_EVENT" = "PreToolUse" ]; then
      jq -n --arg reason "$REASON" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ("Denied by policy: " + $reason)
        }
      }'
    else
      jq -n --arg reason "$REASON" '{
        hookSpecificOutput: {
          hookEventName: "PermissionRequest",
          decision: {
            behavior: "deny",
            message: ("Denied by policy: " + $reason)
          }
        }
      }'
    fi
    ;;
  *)
    # "ask" or unrecognized → fall through to normal permission dialog
    exit 0
    ;;
esac
