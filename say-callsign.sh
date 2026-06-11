#!/bin/bash
# Set THIS Claude session's say-notify callsign — overrides the auto "Project N"
# derivation so the spoken/overlay call-sign reflects what the window is actually
# doing (the agent decides, based on the conversation), e.g. a window watching a
# Google Takeout job sets "Takeout Watch" instead of the meaningless "G 1".
#
#   say-callsign.sh "Takeout Watch"
#
# Keyed by $CLAUDE_CODE_SESSION_ID (the same id Claude Code passes to the
# Notification/Stop hook), so say-notify.sh picks it up on the next fire. Upserts
# the registry: one callsign per session, last write wins.
set -euo pipefail
name="$*"
reg="$HOME/.claude/say-callsigns.tsv"
sid="${CLAUDE_CODE_SESSION_ID:-}"

[ -n "$name" ] || { echo "usage: say-callsign.sh <callsign>   (e.g. \"Takeout Watch\")" >&2; exit 2; }
[ -n "$sid" ]  || { echo "say-callsign: \$CLAUDE_CODE_SESSION_ID unset — not inside a Claude Code session, can't bind." >&2; exit 1; }

mkdir -p "$(dirname "$reg")"; touch "$reg"
# Upsert: drop any existing row for this session, then append the new mapping.
tmp="$(mktemp)"
awk -F'\t' -v s="$sid" '$1 != s' "$reg" > "$tmp" && mv "$tmp" "$reg"
printf '%s\t%s\n' "$sid" "$name" >> "$reg"
echo "callsign set: \"$name\"  (session ${sid})"
