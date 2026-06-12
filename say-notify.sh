#!/bin/bash
# Claude Code Notification hook: speak a concise line of radio chatter via macOS `say`.
# Registered one-line in ~/.claude/settings.json. Reads the hook JSON on stdin;
# never blocks (always exits 0).
#
# Format:  "<radio opener with callsign>. <concise body>"
#   opener = self-identifying radio call, e.g. "Godfather, this is speech-1-Speech."
#   body   = concise radio chatter, INSPIRED by (not quoting) the movie/themed bank
#            archived at ~/Desktop/say-notify-phrases.md. Routed by notification type:
#              mutating/exec tool permission -> warning body (urgent)
#              read-only/benign tool          -> action body  (routine clearance)
#              idle / waiting-for-input        -> idle body    (hand back to you)
#   Permission bodies splice in {detail} = the pending action (command head or a
#   generic verb; never a filename). NOTE: in bypass-permissions mode the permission
#   notifications don't fire, so the idle bodies are what you actually hear.

# Radio openers — vary the self-ID. {cs} = callsign, {gf} = addressee (the user).
# Every opener self-identifies with the callsign (never just "{gf}, <cs>").
openers=( "{gf}, this is {cs}." "{cs} to {gf}." "{cs} here." "This is {cs}." )

# Concise radio bodies, movie-inspired.
warning_body=( "danger close, {detail}?" "weapons hot, {detail}?" "cleared hot to {detail}?" "go on {detail}?" "{detail}, danger close?" "{detail}, weapons free?" "clear to engage {detail}?" )
action_body=(  "cleared to {detail}?" "go for {detail}?" "permission to {detail}?" "okay to {detail}?" "{detail}, your go?" "you are go for {detail}?" "{detail}, cleared hot?" )
idle_body=(    "over to you." "come in." "talk to me." "do you copy?" "you're up." "you're on deck." "holding for you." "how do you read?" "standing by." "awaiting your orders." "say your intentions." "radio check." "wake me when you need me." "what's your status?" "sitrep?" "send it." "go ahead." "say the word." "your move." "your orders?" "sound off." "I'm all ears." )

mutating='Bash|Write|Edit|MultiEdit|NotebookEdit|Remove|Delete|Move'

input="$(cat)"
raw="$(jq -r '.message // "Claude is waiting for your input"' <<<"$input" 2>/dev/null)"
[ -z "$raw" ] && raw="Claude is waiting for your input"
sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
tpath="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"

# SAY_LOG=1 → append every fire/suppress decision to ~/.claude/say-notify.log
# (off by default; opt-in for debugging "why did/ didn't it trigger").

# --- focus-aware gating via cmux ------------------------------------------
# cmux exposes a surface tree marking the CALLING surface (◀ here) and the
# FOCUSED one (◀ active), plus each window's title. We identify THIS window by
# the ◀ here marker (cmux computes it from the caller — works even if the hook
# didn't inherit $CMUX_SURFACE_ID); env match is the fallback. Then:
#   (b) stay silent when you're already looking at this window (here == active),
#   (a) name the callsign after this window's title (below).
# Visual card is ON by default (SAY_OVERLAY=1); SAY_FORCE=1 bypasses (b).
CMUX_BIN="${CMUX_BUNDLED_CLI_PATH:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
cmux_title=""; active_here=0; here_src="none"
if [ -x "$CMUX_BIN" ]; then
  tree="$("$CMUX_BIN" tree --id-format both 2>/dev/null)"
  my_line="$(printf '%s\n' "$tree" | grep -F '◀ here' | head -1)"           # cmux's caller marker
  if [ -n "$my_line" ]; then here_src="here-marker"; fi
  if [ -z "$my_line" ] && [ -n "${CMUX_SURFACE_ID:-}" ]; then               # fallback: env id
    my_line="$(printf '%s\n' "$tree" | grep -F "$CMUX_SURFACE_ID" | head -1)"; [ -n "$my_line" ] && here_src="env-id"
  fi
  if [ -n "$my_line" ]; then
    cmux_title="$(printf '%s' "$my_line" | sed -E 's/[^"]*"([^"]*)".*/\1/; s/^[^[:alnum:]]+//; s/[[:space:]]+$//')"
    printf '%s' "$my_line" | grep -q '◀ active' && active_here=1
  fi
fi
front="$(lsappinfo info -only name "$(lsappinfo front 2>/dev/null)" 2>/dev/null | sed -E 's/.*"name"="?([^"]*)"?/\1/')"
: "${SAY_OVERLAY:=1}"; export SAY_OVERLAY      # portraits ON by default
# (b) you're looking right at this window → don't alert.
if [ "$active_here" = "1" ] && [ "${SAY_FORCE:-0}" != "1" ]; then
  [ -n "${SAY_LOG:-}" ] && printf '%s SUPPRESS active_here sid=%s here_src=%s title=%s front=%s\n' "$(date +%H:%M:%S)" "${sid:0:8}" "$here_src" "$cmux_title" "$front" >> "$HOME/.claude/say-notify.log" 2>/dev/null
  exit 0
fi

# Route to a body set by tool / notification type. needs_detail=1 only for the
# permission bodies that actually splice in {detail}; idle bodies never do.
# RATELIMIT messages (fired by the statusline on a fuel-gauge threshold crossing,
# format "RATELIMIT <window> <pct>") take a dedicated fuel-callout path below.
tool="this action"; needs_detail=0; is_rl=0
case "$raw" in
  RATELIMIT\ *)  is_rl=1; set -- $raw; rl_win="$2"; rl_pct="$3"; bodies=("${idle_body[@]}") ;;
  *"permission to use"*)
    tool="${raw##*permission to use }"; tool="${tool%.}"; needs_detail=1
    if [[ "$tool" =~ ^($mutating) ]]; then bodies=("${warning_body[@]}"); else bodies=("${action_body[@]}"); fi ;;
  *permission*|*approve*|*confirm*) bodies=("${action_body[@]}"); needs_detail=1 ;;
  *waiting*input*|*waiting*)        bodies=("${idle_body[@]}") ;;
  *)                                bodies=("${idle_body[@]}") ;;
esac

# Pending action label for permission bodies. Command head (no args) or generic verb;
# NEVER a filename/path. Skip the (potentially multi-MB) transcript parse entirely
# for the idle route, which never uses {detail}.
detail=""
if [ "$needs_detail" = "1" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
  detail="$(jq -rc 'select(.message.content?)|.message.content[]?|select(.type=="tool_use")|
    if .name=="Bash" and (.input.command|type=="string")
      then (.input.command|split("\n")[0]|split(" ")|.[0:2]|join(" "))
    elif (.name|test("Edit$|NotebookEdit")) then "make an edit"
    elif .name=="Write" then "write a file"
    elif .name=="Read" then "read a file"
    elif .name=="Grep" then "run a search"
    else ("use "+.name) end' "$tpath" 2>/dev/null | tail -1)"
fi
[ -z "$detail" ] && detail="${tool}"

# --- callsign: agent override > Claude chat title > cmux title > project dir --
# Reflects what the CONVERSATION is about, not just its folder. Priority:
#   1. an explicit name the agent set with say-callsign.sh (keyed by session id) —
#      UNLESS you've renamed the chat since: a later Claude `/rename` supersedes a
#      stale override. say-callsign.sh records the chat title as it was at set-time
#      (col 3); if the live title no longer matches that baseline, the rename wins.
#      So the MOST RECENT naming action — say-callsign or /rename — governs.
#   2. the Claude chat title — the `/rename` / auto "ai-title" in the transcript
#      (this is the conversation's own name; the thing the user actually means)
#   3. the cmux surface title (the tab's label) — fallback if no transcript
#   4. the project-dir basename (hyphens/underscores → words; never `cut -f1`,
#      which used to turn "g-takeout" into "G")
# First two words, Title Case, so it stays glanceable. For a crisp name, the
# agent should just call say-callsign.sh.
twoWords() { sed -E 's/[-_]+/ /g; s/[0-9]+/ /g' \
  | awk '{n=(NF<2?NF:2); for(i=1;i<=n;i++){w=$i; printf "%s%s%s",toupper(substr(w,1,1)),tolower(substr(w,2)),(i<n?" ":"")}}'; }
reg="$HOME/.claude/say-callsigns.tsv"
# Override row for this session: <sid> \t <name> \t <chat-title baseline @ set-time>.
# (Legacy 2-column rows have no baseline → ov_base empty → never auto-superseded.)
ov_name=""; ov_base=""
IFS=$'\t' read -r _ ov_name ov_base \
  < <(awk -F'\t' -v s="$sid" '$1==s{print; exit}' "$reg" 2>/dev/null) || true
# Latest Claude chat title (ai-title). grep|tail keeps it fast on a multi-MB
# transcript; needed both as path 2 and to detect a /rename since the override.
# (ai-title records are re-emitted constantly but the VALUE only changes on a
#  real retitle, so a value change is what signals "renamed since".)
aititle=""
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  aititle="$(grep '"type":"ai-title"' "$tpath" 2>/dev/null | tail -1 | jq -rc '.aiTitle // empty' 2>/dev/null)"
fi
# Supersede: had an override, captured a baseline, and the title changed since →
# the override is stale, ignore it so the new chat title (path 2) takes over.
if [ -n "$ov_name" ] && [ -n "$ov_base" ] && [ -n "$aititle" ] && [ "$aititle" != "$ov_base" ]; then
  ov_name=""
fi
callsign=""
[ -n "$ov_name" ] && callsign="$ov_name"                                          # 1
[ -z "$callsign" ] && [ -n "$aititle" ] && callsign="$(printf '%s' "$aititle" | twoWords)"   # 2
[ -z "$callsign" ] && [ -n "$cmux_title" ] && callsign="$(printf '%s' "$cmux_title" | twoWords)"   # 3
[ -z "$callsign" ] && callsign="$(basename "${cwd:-$PWD}" | twoWords)"            # 4
[ -z "$callsign" ] && callsign="Unit"

# Collision numbering (tactical-callsign style): if other live cmux windows would
# derive the SAME callsign, append this window's ordinal among them — "Central 1",
# "Central 2". Implicit: a unique callsign gets no number. Uses the same cmux tree
# already fetched; ordinals follow surface order so they're stable per window.
if [ -n "${tree:-}" ]; then
  my_uuid="$(printf '%s' "${my_line:-}" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  match_uuids="$(printf '%s\n' "$tree" | grep 'surface ' | while IFS= read -r ln; do
    t="$(printf '%s' "$ln" | sed -E 's/[^"]*"([^"]*)".*/\1/; s/^[^[:alnum:]]+//; s/[[:space:]]+$//')"
    [ "$(printf '%s' "$t" | twoWords)" = "$callsign" ] || continue
    printf '%s' "$ln" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1
  done)"
  cnt="$(printf '%s\n' "$match_uuids" | grep -c .)"
  if [ "$cnt" -gt 1 ] && [ -n "$my_uuid" ]; then
    ord="$(printf '%s\n' "$match_uuids" | grep -niF "$my_uuid" | head -1 | cut -d: -f1)"
    [ -n "$ord" ] && callsign="$callsign $ord"
  fi
fi

# Pseudo-random pick that avoids repeating the previous pick for this category
# (remembered in a small state file) — so the same line doesn't fire twice in a row.
pick(){ k="$1"; shift; cnt=$#; f="${TMPDIR:-/tmp/}say-notify-last.$k"; last="$(cat "$f" 2>/dev/null)"
  sel=""; i=0
  while [ "$i" -lt 8 ]; do c="$(eval "printf '%s' \"\${$(( RANDOM % cnt + 1 ))}\"")"
    sel="$c"; [ "$cnt" -le 1 ] && break; [ "$c" != "$last" ] && break; i=$((i+1)); done
  printf '%s' "$sel" > "$f" 2>/dev/null; printf '%s' "$sel"; }

# Addressee (the user, the {gf} placeholder): $SAY_ADDRESSEE > ~/.claude/say-addressee > "Godfather".
gf="${SAY_ADDRESSEE:-}"
[ -z "$gf" ] && [ -s "$HOME/.claude/say-addressee" ] && gf="$(cat "$HOME/.claude/say-addressee")"
[ -z "$gf" ] && gf="Godfather"

opener="$(pick opener "${openers[@]}")"; opener="${opener//\{cs\}/$callsign}"; opener="${opener//\{gf\}/$gf}"
body="$(pick body "${bodies[@]}")"; body="${body//\{detail\}/$detail}"

# Resolve our real directory, following symlinks (works when invoked directly OR
# via a symlink, e.g. central/scripts/agent-radio/ → this repo).
SELF="$0"; while [ -h "$SELF" ]; do ld="$(cd "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$ld/$SELF" ;; esac; done
DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)"; [ -d "$DIR" ] || DIR="$(pwd)"
spoken="${opener} ${body}"
beep="$DIR/say-notify-beep.wav"

# Quotes mode (SAY_MODE=quotes): speak a movie/themed quote instead of radio chatter.
if [ "${SAY_MODE:-radio}" = "quotes" ] && [ -f "$DIR/say-notify-quotes.sh" ]; then
  . "$DIR/say-notify-quotes.sh"
  case "$raw" in
    *"permission to use"*) qt="${raw##*permission to use }"
      if printf '%s' "${qt%.}" | grep -qE '^(Bash|Write|Edit|MultiEdit|NotebookEdit|Remove|Delete|Move)'; then qp=("${warning_q[@]}"); else qp=("${action_q[@]}"); fi ;;
    *permission*|*approve*|*confirm*) qp=("${action_q[@]}") ;;
    *) qp=("${idle_q[@]}") ;;
  esac
  spoken="$(pick quote "${qp[@]}") This is ${callsign}. ${body}"   # quote + callsign + message
fi
# Rate-limit "fuel gauge" callout. Tier from the percentage (real aviation/brevity
# ladder): JOKER = above bingo, start wrapping up; BINGO = minimum fuel to get
# home, act now; WINCHESTER = nothing left. Every line carries "rate limit" + a
# gas/fuel metaphor, per request.
if [ "$is_rl" = "1" ]; then
  win_say="five hour"; [ "$rl_win" = "seven_day" ] && win_say="seven day"
  if [ "${rl_pct:-0}" -ge 100 ]; then
    fuel=( "Winchester — ${win_say} rate limit maxed at ${rl_pct} percent, out of gas."
           "Tank's dry. ${win_say} rate limit at ${rl_pct} percent. Winchester." )
  elif [ "${rl_pct:-0}" -ge 95 ]; then
    fuel=( "Bingo fuel — ${win_say} rate limit at ${rl_pct} percent, time to head home."
           "Bingo, bingo. ${win_say} rate limit at ${rl_pct} percent, running on fumes." )
  else
    fuel=( "Joker fuel — ${win_say} rate limit at ${rl_pct} percent, start wrapping up."
           "Gas light's on, ${win_say} rate limit at ${rl_pct} percent."
           "Fuel check — ${win_say} rate limit reading ${rl_pct} percent, top off soon." )
  fi
  spoken="${opener} $(pick rlbody "${fuel[@]}")"
fi

[ -n "$SAY_LINE" ] && spoken="$SAY_LINE"   # verbatim spoken-line override (demos/testing)

# TTS pronunciation normalization (clarvis-style): spell acronyms and read CLI
# flags aloud so `say` is intelligible — "API"→"A P I", "-rf"→"dash r f". ONLY the
# spoken audio is normalized; the on-screen card text ($cardtext) stays verbatim.
speakify(){ perl -pe '
  s/\bAPI\b/A P I/g; s/\bCLI\b/C L I/g; s/\bURL\b/U R L/g; s/\bSQL\b/sequel/g;
  s/\bJSON\b/jason/gi; s/\bYAML\b/yamel/gi; s/\bSSH\b/S S H/g; s/\bHTTPS\b/H T T P S/g; s/\bHTTP\b/H T T P/g;
  s/\bnpm\b/N P M/g; s/\bnpx\b/N P X/g; s/\bcwd\b/C W D/g; s/\benv\b/environment/g; s/\bregex\b/redjex/g;
  s/--([A-Za-z][\w-]*)/dash dash $1/g;
  s/(?<![\w-])-([A-Za-z]{1,4})(?![\w-])/"dash ".join(" ", split("",$1))/ge;
' 2>/dev/null; }
tts="$(printf '%s' "$spoken" | speakify)"; [ -z "$tts" ] && tts="$spoken"

# Per-callsign portrait (stable hash into the animated cast) + a matching retro voice.
portrait="$DIR/say-notify-portrait.gif"
if ls "$DIR"/portraits/*.gif >/dev/null 2>&1; then
  pg=( "$DIR"/portraits/*.gif )
  ph="$(printf '%s' "$callsign" | cksum | cut -d' ' -f1)"
  portrait="${pg[$(( ph % ${#pg[@]} ))]}"
fi
# SAY_PORTRAIT override (full path, or a basename in portraits/) — used by the dev UI.
if [ -n "$SAY_PORTRAIT" ]; then
  for cand in "$SAY_PORTRAIT" "$DIR/portraits/$SAY_PORTRAIT" "$DIR/portraits/$SAY_PORTRAIT.gif"; do
    [ -f "$cand" ] && { portrait="$cand"; break; }
  done
fi
# Voice matched 1:1 to each portrait's character, by timbre. en_US-qualified so the
# Eloquence voices don't fall back to a non-English locale (bare "Eddy" = German Eddy).
case "$(basename "$portrait")" in
  *cargo-hauler*) voice="Rocko (English (US))" ;;    # gruff hauler
  *engineer*)     voice="Shelley (English (US))" ;;  # woman
  *mechanic*)     voice="Fred" ;;                     # deadpan low
  *pilot*)        voice="Reed (English (US))" ;;      # smooth, cocky
  *captain*)      voice="Grandpa (English (US))" ;;   # weary old man
  *deckhand*)     voice="Eddy (English (US))" ;;      # younger
  *android*)      voice="Ralph" ;;                    # deep, flat → robotic
  *loader*)       voice="Flo (English (US))" ;;       # woman
  *)              voice="Grandpa (English (US))" ;;
esac
[ -n "$SAY_VOICE" ] && voice="$SAY_VOICE"      # dev-UI / env override
rate="${SAY_RATE:-240}"

# Frame color correlated to the Claude window: a stable distinct hue per session id,
# so each window's cards are colour-coded. Lookdev's SN_TEAL override wins if set.
if [ -z "$SN_TEAL" ]; then
  hh="$(printf '%s' "${sid:-$callsign}" | cksum | cut -d' ' -f1)"
  SN_TEAL="$(python3 -c "import colorsys,sys;h=(int(sys.argv[1])%360)/360.0;r,g,b=colorsys.hls_to_rgb(h,0.66,0.72);print('#%02x%02x%02x'%(round(r*255),round(g*255),round(b*255)))" "$hh" 2>/dev/null)"
  [ -n "$SN_TEAL" ] && export SN_TEAL
fi

# Two-word task descriptor for the card (CALLSIGN + what's happening).
case "$raw" in
  RATELIMIT\ *)          desc="rate limit ${rl_pct}%" ;;
  *"permission to use"*) t="${raw##*permission to use }"; desc="run ${t%.}" ;;
  *permission*|*approve*|*confirm*) desc="your okay" ;;
  *waiting*input*|*waiting*)        desc="your input" ;;
  *)                                desc="incoming traffic" ;;
esac
cardtext="${callsign}: ${desc}"

# Diagnostic: when SAY_LOG=1, append every FIRED notification's decision so we
# can see why something triggered (route, focus state, env source, frontmost).
[ -n "${SAY_LOG:-}" ] && printf '%s FIRE sid=%s route=%s here_src=%s active_here=%s overlay=%s front=%s call=%s\n' \
  "$(date +%H:%M:%S)" "${sid:0:8}" "${needs_detail}d" "$here_src" "$active_here" "$SAY_OVERLAY" "$front" "$callsign" \
  >> "$HOME/.claude/say-notify.log" 2>/dev/null

# Debug: print the resolved decision and exit (no audio/overlay). SAY_DEBUG=1.
if [ -n "${SAY_DEBUG:-}" ]; then
  printf 'callsign=%s\nactive_here=%s overlay=%s\ncmux_title=%s\nspoken=%s\ncard=%s\n' \
    "$callsign" "$active_here" "${SAY_OVERLAY:-1}" "${cmux_title:-}" "$spoken" "$cardtext" >&2
  exit 0
fi

# Serialize the audio so concurrent agents don't talk over each other. mkdir spinlock;
# a lock older than ~30s is treated as stale and stolen.
lock="${TMPDIR:-/tmp/}say-notify-audio.lock"
acquire(){ n=0; until mkdir "$lock" 2>/dev/null; do
  [ -n "$(find "$lock" -maxdepth 0 -mmin +0.5 2>/dev/null)" ] && rm -rf "$lock" && continue
  sleep 0.05; n=$((n+1)); [ "$n" -gt 1200 ] && break; done; }   # snappy handoff between agents
release(){ rmdir "$lock" 2>/dev/null; }

if [ "${SAY_OVERLAY:-1}" != "0" ]; then    # overlay ON by default; SAY_OVERLAY=0 disables
  # Persistent-daemon overlay: the card is a subview of ONE long-lived window, so
  # no window is created/ordered per alert → the terminal never loses focus. We
  # just drop request files in a watched dir: "<id>.card" to show, "<id>.dismiss"
  # to remove (when this card's audio ends).
  ovdsrc="$DIR/say-notify-overlayd.swift"; ovdbin="$DIR/say-notify-overlayd"
  rebuilt=0
  if ! { [ -x "$ovdbin" ] && [ "$ovdbin" -nt "$ovdsrc" ]; }; then
    tmpbin="$(mktemp -t snovd)"
    if swiftc -O "$ovdsrc" -o "$tmpbin" 2>/dev/null; then mv -f "$tmpbin" "$ovdbin"; rebuilt=1; else rm -f "$tmpbin"; fi
  fi
  # A running daemon can't hot-swap its own code, so a fresh rebuild won't take
  # effect until the old instance is replaced. If we just rebuilt AND one is
  # running, restart it (fixes the "edit the .swift, but the card stays stale"
  # caveat — no manual launchctl/pkill needed). This is the only place a restart
  # ever happens, so the one-time focus blip is confined to your own dev edits.
  started=0
  if [ "$rebuilt" = "1" ] && pgrep -f "say-notify-overlayd" >/dev/null 2>&1; then
    # Kill whatever's running (launchd's child OR a bare nohup instance)…
    pkill -f "say-notify-overlayd" 2>/dev/null
    # …then, if a LaunchAgent supervises it, bring the new binary up under launchd
    # (kickstart -k converges to exactly one supervised instance, KeepAlive and all).
    label="$(launchctl list 2>/dev/null | awk '/say-notify-overlayd/{print $3; exit}')"
    if [ -n "$label" ]; then launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null; started=1; fi
  fi
  # Ensure the daemon runs. Its window orderFronts exactly ONCE (at launch); that
  # single moment is the only time focus could blip — never again per alert.
  if [ "$started" = "0" ] && [ -x "$ovdbin" ] && ! pgrep -f "say-notify-overlayd" >/dev/null 2>&1; then
    nohup "$ovdbin" >/dev/null 2>&1 &
  fi
  carddir="${TMPDIR:-/tmp/}say-notify-cards"; mkdir -p "$carddir"
  cardid="c$$-$(date +%s)-${RANDOM}"
  aiff="$(mktemp -t saynotify).aiff"
  say -r "$rate" -v "$voice" -o "$aiff" "$tts" 2>/dev/null || say -o "$aiff" "$tts" 2>/dev/null
  # show the card NOW: atomic write (tmp + mv) so the daemon never reads a partial file
  printf '%s\t%s\t%s\n' "$cardtext" "$portrait" "${SN_TEAL:-}" > "$carddir/.$cardid.tmp" \
    && mv -f "$carddir/.$cardid.tmp" "$carddir/$cardid.card"
  acquire                                          # queue the AUDIO — no talk-over
  # SFX→voice gap (SAY_BEEPGAP, seconds, negative overlaps beep & voice).
  [ -f "$beep" ] && afplay "$beep" 2>/dev/null &
  sleep "$(awk -v g="${SAY_BEEPGAP:-0.2}" 'BEGIN{d=0.22+g; if(d<0)d=0; printf "%.3f",d}')"
  afplay "$aiff" 2>/dev/null; rm -f "$aiff"
  sleep "$(awk -v g="${SAY_MSGGAP:-0}" 'BEGIN{if(g<0)g=0; printf "%.3f",g}')"   # gap between messages
  release
  : > "$carddir/$cardid.dismiss"   # dismiss THIS card when ITS audio ends
else
  acquire
  [ -f "$beep" ] && afplay "$beep" 2>/dev/null &
  sleep "$(awk -v g="${SAY_BEEPGAP:-0.2}" 'BEGIN{d=0.22+g; if(d<0)d=0; printf "%.3f",d}')"
  say -r "$rate" -v "$voice" "$tts" 2>/dev/null || say "$tts" 2>/dev/null || true
  sleep "$(awk -v g="${SAY_MSGGAP:-0}" 'BEGIN{if(g<0)g=0; printf "%.3f",g}')"
  release
fi
exit 0
