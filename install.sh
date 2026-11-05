#!/bin/bash
# install.sh — stand up an always-on, self-healing autonomous Claude Code agent
# under systemd. No orchestration framework, no gateway, no second runtime: the
# ONLY agent process is `claude` itself, inside a detached tmux session that
# systemd supervises.
#
# Configure by copying .env.example to .env and editing it. This script sources
# .env automatically; anything already in your shell environment wins over it.
#
# Architecture (5 parts, each one replaceable):
#   1. <agent>-claude.service   systemd keeps a detached tmux session alive, running
#                               `claude --dangerously-skip-permissions`, and pastes the
#                               /loop bootstrap prompt into it ~25s after launch so a
#                               crash or reboot self-resumes with no human action.
#   2. BOOTSTRAP-PROMPT.txt     the agent's brain: identity, event-queue contract,
#                               safety gates, loop pacing, measurement discipline.
#   3. <agent>-nudger.service   tails the event queue and sends a literal "." + Enter
#                               into the tmux pane when an ACTIONABLE line lands.
#                               That is what makes the agent real-time, not a poller.
#   4. <agent>-liveness.timer   every 2 min: is the unit up, the session alive, the pane
#                               moving, the loop armed, the login valid? Heal, else alert.
#   5. <agent>-listener.service OPTIONAL chat producer (slack | discord) that appends
#                               NORMALIZED JSON lines to the event queue.
#
# Tier 1 (CHAT_PROVIDER=none): parts 1+2+4. Zero extra deps. The agent paces
#         itself with ScheduleWakeup. Start here.
# Tier 2 (slack|discord): all five. Real-time wake on inbound messages.
#
# Docker: the image sets SUPERVISOR=container, which skips everything systemd-only
# (linger, units) and leaves docker/entrypoint.sh to supervise the same scripts.
#
# Idempotent — safe to re-run. Run as the agent's OWN unix user, never root.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── load .env (shell environment takes precedence) ──────────────────────────
if [ -f "${ENV_FILE:-$SRC/.env}" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [ "${line#*=}" = "$line" ] && continue          # skip lines with no '='
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac  # only sane var names
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    # shell env wins: only set if currently unset/empty
    [ -z "$(eval "printf '%s' \"\${$k:-}\"")" ] && export "$k=$v"
  done < "${ENV_FILE:-$SRC/.env}"
fi

# ─────────────────────────── CONFIG ───────────────────────────
AGENT="${AGENT:-semp}"
WORKSPACE="${WORKSPACE:-$HOME/$AGENT}"
SESSION="${SESSION:-$AGENT}"
STATE_DIR="${STATE_DIR:-/tmp/$AGENT-state}"
SUPERVISOR="${SUPERVISOR:-systemd}"                       # systemd | container
CHAT_PROVIDER="${CHAT_PROVIDER:-${EVENT_SOURCE:-none}}"   # none | slack | discord
IDLE_STALL_SECS="${IDLE_STALL_SECS:-2400}"
NUDGE_COOLDOWN_SECONDS="${NUDGE_COOLDOWN_SECONDS:-15}"
TYPING_MAX_SECS="${TYPING_MAX_SECS:-120}"
USAGE_LIMIT_RETRY_SECS="${USAGE_LIMIT_RETRY_SECS:-1800}"
API_ERROR_WAKE_SECS="${API_ERROR_WAKE_SECS:-300}"
API_ERROR_ALERT_AFTER="${API_ERROR_ALERT_AFTER:-3}"
OWNER_ID="${OWNER_ID:-${OWNER_SLACK_USER:-}}"
SELF_BOT_ID="${SELF_BOT_ID:-}"
OWNER_DM_CHANNEL="${OWNER_DM_CHANNEL:-}"
ALERT_CHANNEL="${ALERT_CHANNEL:-}"
OWNER_CHANNELS="${OWNER_CHANNELS:-}"
INCIDENT_CHANNELS="${INCIDENT_CHANNELS:-}"
NUDGE_PATTERN="${NUDGE_PATTERN:-}"
SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
# Whitespace stripped: a pasted key often carries some, and agent.env is sourced
# unquoted, so one space would break every script that reads it.
ANTHROPIC_API_KEY="$(printf '%s' "${ANTHROPIC_API_KEY:-}" | tr -d '[:space:]')"   # blank = stored login
CLAUDE_CODE_OAUTH_TOKEN="$(printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" | tr -d '[:space:]')"
# ──────────────────────────────────────────────────────────────

EVENT_JSONL="${EVENT_JSONL:-/tmp/${AGENT}-events.jsonl}"
CURSOR_FILE="${CURSOR_FILE:-/tmp/${AGENT}-cursor.txt}"
UN="$HOME/.config/systemd/user"
BIN="$HOME/.local/bin"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as the agent's own user, not root"
command -v tmux      >/dev/null || die "tmux not installed (apt install tmux)"
command -v python3   >/dev/null || die "python3 required"
case "$SUPERVISOR" in
  systemd)
    command -v systemctl >/dev/null || die "systemd required (on macOS or without systemd, use Docker: see README)"
    systemctl --user show-environment >/dev/null 2>&1 \
      || die "no systemd --user bus. Log in properly (ssh/su -l), or: loginctl enable-linger $(whoami)"
    ;;
  container) ;;
  *) die "SUPERVISOR must be one of: systemd container (got '$SUPERVISOR')" ;;
esac

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
[ -x "$CLAUDE_BIN" ] || die "claude CLI not found. Install Claude Code: npm i -g @anthropic-ai/claude-code"

case "$CHAT_PROVIDER" in
  none) ;;
  slack)
    command -v node >/dev/null || die "CHAT_PROVIDER=slack needs node >= 18"
    [ -n "$SLACK_APP_TOKEN" ] || die "CHAT_PROVIDER=slack needs SLACK_APP_TOKEN (xapp-...)"
    [ -n "$SLACK_BOT_TOKEN" ] || die "CHAT_PROVIDER=slack needs SLACK_BOT_TOKEN (xoxb-...)"
    [ -n "$OWNER_ID" ]        || die "CHAT_PROVIDER=slack needs OWNER_ID (your U... member id)"
    ;;
  discord)
    command -v node >/dev/null || die "CHAT_PROVIDER=discord needs node >= 18"
    [ -n "$DISCORD_BOT_TOKEN" ] || die "CHAT_PROVIDER=discord needs DISCORD_BOT_TOKEN"
    [ -n "$OWNER_ID" ]          || die "CHAT_PROVIDER=discord needs OWNER_ID (your user id)"
    ;;
  *) die "CHAT_PROVIDER must be one of: none slack discord (got '$CHAT_PROVIDER')" ;;
esac

[ -n "$OWNER_ID" ] || [ "$CHAT_PROVIDER" = none ] || die "OWNER_ID is required"
if [ "$CHAT_PROVIDER" != none ] && [ -z "$SELF_BOT_ID" ]; then
  echo "    WARNING: SELF_BOT_ID is empty. The agent cannot recognise @-mentions of"
  echo "             itself, and cannot drop its own messages — which means it may"
  echo "             read its own output as new input. Set it in .env."
fi

mkdir -p "$WORKSPACE"/{scripts,memory,config} "$UN" "$BIN" "$STATE_DIR"

# ── 0. linger: user units must survive logout, or the agent dies when you ssh out
if [ "$SUPERVISOR" = systemd ]; then
  say "enabling linger for $(whoami)"
  loginctl enable-linger "$(whoami)" 2>/dev/null \
    || echo "    (could not self-enable; ask an admin for: loginctl enable-linger $(whoami))"
fi

# ── 1. the agent's env file — every script and unit sources this one file
say "writing $WORKSPACE/agent.env"
( umask 077; cat > "$WORKSPACE/agent.env" <<EOF
AGENT=$AGENT
SESSION=$SESSION
WORKSPACE=$WORKSPACE
STATE_DIR=$STATE_DIR
SUPERVISOR=$SUPERVISOR
CLAUDE_BIN=$CLAUDE_BIN
CLAUDE_UNIT=$AGENT-claude.service
EVENT_JSONL=$EVENT_JSONL
CURSOR_FILE=$CURSOR_FILE
BOOTSTRAP_FILE=$WORKSPACE/BOOTSTRAP-PROMPT.txt
BOOTSTRAP_CMD=$BIN/$AGENT-bootstrap
IDLE_STALL_SECS=$IDLE_STALL_SECS
NUDGE_COOLDOWN_SECONDS=$NUDGE_COOLDOWN_SECONDS
NUDGE_PATTERN=$NUDGE_PATTERN
TYPING_MAX_SECS=$TYPING_MAX_SECS
USAGE_LIMIT_RETRY_SECS=$USAGE_LIMIT_RETRY_SECS
API_ERROR_WAKE_SECS=$API_ERROR_WAKE_SECS
API_ERROR_ALERT_AFTER=$API_ERROR_ALERT_AFTER
CHAT_PROVIDER=$CHAT_PROVIDER
OWNER_ID=$OWNER_ID
SELF_BOT_ID=$SELF_BOT_ID
OWNER_DM_CHANNEL=$OWNER_DM_CHANNEL
ALERT_CHANNEL=$ALERT_CHANNEL
OWNER_CHANNELS=$OWNER_CHANNELS
INCIDENT_CHANNELS=$INCIDENT_CHANNELS
SLACK_APP_TOKEN=$SLACK_APP_TOKEN
SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN
DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN
EOF
)
chmod 600 "$WORKSPACE/agent.env"

# ── 2. bootstrap prompt: install the template once, never clobber local edits
TEMPLATE=""
for c in "$SRC/prompts/BOOTSTRAP-PROMPT.txt" "$SRC/BOOTSTRAP-PROMPT.txt"; do
  [ -f "$c" ] && { TEMPLATE="$c"; break; }
done
if [ -f "$WORKSPACE/BOOTSTRAP-PROMPT.txt" ]; then
  say "BOOTSTRAP-PROMPT.txt already present — leaving your edits alone"
elif [ -n "$TEMPLATE" ]; then
  say "installing BOOTSTRAP-PROMPT.txt template (EDIT IT — the placeholders are not optional)"
  sed -e "s|<AGENT_NAME>|$AGENT|g" -e "s|<WORKSPACE>|$WORKSPACE|g" \
      -e "s|<EVENT_JSONL>|$EVENT_JSONL|g" -e "s|<CURSOR_FILE>|$CURSOR_FILE|g" \
      -e "s|<SESSION>|$SESSION|g" \
      "$TEMPLATE" > "$WORKSPACE/BOOTSTRAP-PROMPT.txt"
else
  die "BOOTSTRAP-PROMPT.txt not found in $SRC/prompts/ or beside this installer"
fi
[ -f "$WORKSPACE/MEMORY.md" ]    || printf '# MEMORY.md — %s long-term memory\n\n## Identity\n\n## Owner\n\n## Infra\n\n## Laws\n' "$AGENT" > "$WORKSPACE/MEMORY.md"
[ -f "$WORKSPACE/INSTINCTS.md" ] || printf '# INSTINCTS.md — %s reflexes (IF -> THEN, fire without thinking)\n' "$AGENT" > "$WORKSPACE/INSTINCTS.md"
[ -f "$WORKSPACE/HEARTBEAT.md" ] || printf '# HEARTBEAT.md — what %s checks on every wake\n' "$AGENT" > "$WORKSPACE/HEARTBEAT.md"
[ -f "$EVENT_JSONL" ] || : > "$EVENT_JSONL"
[ -f "$CURSOR_FILE" ] || wc -c < "$EVENT_JSONL" > "$CURSOR_FILE"

# ── 3. pre-trust the working directory so claude boots straight to the REPL.
# Without this the first launch blocks on the folder-trust dialog and the agent
# never reaches its prompt — it just sits there looking alive.
#
# An ANTHROPIC_API_KEY is approved here too. claude asks before using a key from
# the environment, and the paste's Enter would answer for the human. Putting the key
# in .env is the owner's answer. claude records keys by their last 20 characters.
say "pre-trusting $WORKSPACE in ~/.claude.json"
[ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"
WORKSPACE="$WORKSPACE" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" python3 - <<'PYEOF'
import json, os
p = os.path.expanduser('~/.claude.json')
try:
    d = json.load(open(p))
except Exception:
    d = {}
d.setdefault('projects', {}).setdefault(os.environ['WORKSPACE'], {})['hasTrustDialogAccepted'] = True
key = os.environ.get('ANTHROPIC_API_KEY', '').strip()[-20:]
if key:
    r = d.setdefault('customApiKeyResponses', {})
    r['approved'] = [k for k in r.get('approved', []) if k != key] + [key]
    r['rejected'] = [k for k in r.get('rejected', []) if k != key]
json.dump(d, open(p, 'w'), indent=2)
PYEOF

# ── 4. runner: tmux + claude, auto-bootstrap, block until the session dies
say "writing scripts/claude.sh"
cat > "$WORKSPACE/scripts/claude.sh" <<'SCRIPT'
#!/bin/bash
# What the tmux pane runs: claude, with the model credential from agent.env.
#
# It reads the credential here rather than inheriting it from run.sh because a new
# tmux session takes its environment from the tmux server. When this user already
# has a server running, run.sh's environment never reaches claude. Only the
# credential is exported, so natively the bot tokens stay out of every tool claude
# runs. (In Docker, entrypoint.sh has already exported all of agent.env.)
set -euo pipefail
source "${1:?usage: claude.sh <agent.env>}"
for v in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    [ -z "${!v:-}" ] || export "$v"
done
cd "$WORKSPACE"
exec "$CLAUDE_BIN" --dangerously-skip-permissions
SCRIPT

say "writing scripts/run.sh"
cat > "$WORKSPACE/scripts/run.sh" <<'SCRIPT'
#!/bin/bash
# Boots the detached tmux session running claude, pastes the /loop bootstrap
# prompt ~25s later, then blocks until the session ends so systemd's
# Restart=always treats a dead claude as a dead unit and brings it back.
#
# Why --dangerously-skip-permissions: no human is present to approve tool-call
# prompts. Safety is enforced INSIDE the bootstrap prompt instead (owner-only
# authorisation + an explicit confirmation word for every write action).
set -euo pipefail
source "${AGENT_ENV:?AGENT_ENV not set}"
log() { echo "$(date -u +%FT%TZ) [$AGENT-run] $*"; }

[ -x "$CLAUDE_BIN" ] || { log "FATAL: claude not executable at $CLAUDE_BIN"; exit 1; }

if tmux has-session -t "$SESSION" 2>/dev/null; then
    log "killing stale tmux session for a clean start"
    tmux kill-session -t "$SESSION" || true
fi

log "starting detached tmux '$SESSION' -> claude --dangerously-skip-permissions"
tmux new-session -d -s "$SESSION" -x 220 -y 60 \
    "exec '$WORKSPACE/scripts/claude.sh' '$AGENT_ENV'"

# Auto-load the prompt so a crash or reboot self-resumes the loop unattended.
# 25s because claude renders a splash, checks for updates and loads project
# context first; paste into that window and the prompt lands mangled.
# Skipped if a human is attached, so we never clobber their typing, and if claude
# is holding on a screen only a human can answer: the paste's Enter would take the
# default, which on the bypass-permissions warning is "No, exit" — a restart loop
# that never reaches the prompt. The watchdog alerts, then re-arms once it clears.
(
    sleep "${BOOTSTRAP_DELAY_SECS:-25}"
    if [ -n "$(tmux list-clients -t "$SESSION" 2>/dev/null)" ]; then
        log "human attached — skipping auto-bootstrap (run $AGENT-bootstrap by hand)"
    elif tmux capture-pane -p -t "$SESSION" 2>/dev/null \
            | grep -qiE 'select login method|paste code here|yes, i accept|custom api key'; then
        log "claude is waiting on a human — skipping auto-bootstrap"
    elif tmux has-session -t "$SESSION" 2>/dev/null && [ -f "$BOOTSTRAP_FILE" ]; then
        tmux load-buffer  -t "$SESSION" -b "$AGENT-boot" "$BOOTSTRAP_FILE"
        tmux paste-buffer -t "$SESSION" -b "$AGENT-boot"
        sleep 1
        tmux send-keys    -t "$SESSION" Enter
        tmux delete-buffer -b "$AGENT-boot" 2>/dev/null || true
        log "auto-bootstrap: loop prompt loaded"
    fi
) &

log "session live; waiting for it to terminate"
while tmux has-session -t "$SESSION" 2>/dev/null; do sleep 30; done
log "session ended; exiting so systemd restarts us"
SCRIPT

# ── 5. notify: one provider-agnostic way to send a message
say "writing scripts/notify.sh"
cat > "$WORKSPACE/scripts/notify.sh" <<'SCRIPT'
#!/bin/bash
# notify.sh <text> [channel] — post a message via the configured chat provider.
# Used by the watchdog, and available to the agent itself. Keeping this in one
# place is why nothing else in the system needs to know which provider you use.
set -uo pipefail
source "${AGENT_ENV:?AGENT_ENV not set}"
TEXT="${1:?usage: notify.sh <text> [channel]}"
CHAN="${2:-${ALERT_CHANNEL:-$OWNER_DM_CHANNEL}}"
STATE="${STATE_DIR:-/tmp/$AGENT-state}"; mkdir -p "$STATE"
json_str() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
# A silent failure here reads as "the owner was told", so a post only counts when
# the API's reply says so. curl's exit status can't show that: Discord refuses
# with a 4xx body, and Slack refuses with HTTP 200 and "ok":false.
confirmed() { # confirmed <response> <key that must be truthy>
  printf '%s' "$1" | python3 -c '
import json,sys
sys.exit(0 if json.load(sys.stdin).get(sys.argv[1]) else 1)' "$2" 2>/dev/null
}
# The message may be an alert the owner still needs, so keep it on disk.
undelivered() { # undelivered <response>
  echo "$(date -u +%FT%TZ) [notify:$AGENT] UNDELIVERED: $TEXT | response: ${1:-none}" >> "$STATE/notify.log"
  echo "notify: delivery failed: ${1:-no response}" >&2
  exit 1
}

case "${CHAT_PROVIDER:-none}" in
  slack)
    if [ -z "$CHAN" ]; then   # resolve + cache the owner DM channel
      if [ -f "$STATE/dm-channel" ]; then CHAN="$(cat "$STATE/dm-channel")"
      else
        CHAN="$(curl -s --max-time 12 -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
          -H 'Content-type: application/json' -d "{\"users\":\"$OWNER_ID\"}" \
          https://slack.com/api/conversations.open \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("channel",{}).get("id",""))' 2>/dev/null)"
        [ -n "$CHAN" ] && echo "$CHAN" > "$STATE/dm-channel"
      fi
    fi
    [ -n "$CHAN" ] || { echo "notify: no slack channel resolved" >&2; exit 1; }
    RESP="$(curl -s --max-time 12 -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
         -H 'Content-type: application/json; charset=utf-8' \
         -d "{\"channel\":\"$CHAN\",\"text\":$(json_str "$TEXT")}" \
         https://slack.com/api/chat.postMessage)"
    confirmed "$RESP" ok || undelivered "$RESP"
    ;;
  discord)
    if [ -z "$CHAN" ]; then
      if [ -f "$STATE/dm-channel" ]; then CHAN="$(cat "$STATE/dm-channel")"
      else
        CHAN="$(curl -s --max-time 12 -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
          -H 'Content-Type: application/json' -d "{\"recipient_id\":\"$OWNER_ID\"}" \
          https://discord.com/api/v10/users/@me/channels \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
        [ -n "$CHAN" ] && echo "$CHAN" > "$STATE/dm-channel"
      fi
    fi
    [ -n "$CHAN" ] || { echo "notify: no discord channel resolved" >&2; exit 1; }
    RESP="$(curl -s --max-time 12 -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
         -H 'Content-Type: application/json' \
         -d "{\"content\":$(json_str "$TEXT")}" \
         "https://discord.com/api/v10/channels/$CHAN/messages")"
    confirmed "$RESP" id || undelivered "$RESP"
    # A delivered reply ends the wait, or typing.sh would show "typing…" again.
    rm -f "$STATE"/typing/*
    ;;
  *)
    # Tier 1: no chat provider. Log it so the alert is at least recoverable.
    echo "$(date -u +%FT%TZ) [notify:$AGENT] $TEXT" >> "$STATE/notify.log"
    ;;
esac
SCRIPT

say "writing scripts/typing.sh"
cat > "$WORKSPACE/scripts/typing.sh" <<'SCRIPT'
#!/bin/bash
# typing.sh <channel> — show "typing…" in a Discord channel while the agent works.
# The nudger starts this, and a delivered notify.sh message ends it by removing the
# marker. TYPING_MAX_SECS bounds it, because the agent may decide not to answer.
#
# Purely cosmetic, so nothing waits for it and its curl result is ignored: a failure
# here must never get in the way of the real reply.
set -uo pipefail
source "${AGENT_ENV:?AGENT_ENV not set}"
CHAN="${1:?usage: typing.sh <channel>}"
[ "${CHAT_PROVIDER:-none}" = discord ] || exit 0
[ "${TYPING_MAX_SECS:-120}" -gt 0 ] || exit 0
DIR="${STATE_DIR:-/tmp/$AGENT-state}/typing"; mkdir -p "$DIR"
MARK="$DIR/$CHAN"
# Written before taking the lock, so a follow-up message extends a running loop.
echo "$(($(date +%s) + TYPING_MAX_SECS))" > "$MARK"
# Hidden, so that notify.sh's glob removes the marker and leaves this alone.
LOCK="$DIR/.$CHAN.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rm -rf "$LOCK"' EXIT
while [ "$(date +%s)" -lt "$(cat "$MARK" 2>/dev/null || echo 0)" ]; do
    curl -s -o /dev/null --max-time 5 -X POST -d '' \
         -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
         "https://discord.com/api/v10/channels/$CHAN/typing"
    # Discord documents the indicator as lasting about 10s, so renew it inside that.
    sleep "${TYPING_EVERY_SECS:-8}"
done
rm -f "$MARK"
SCRIPT

# ── 5b. claude's own state: can it think right now? Shared by the nudger and watchdog
say "writing scripts/claude-state.sh"
cat > "$WORKSPACE/scripts/claude-state.sh" <<'SCRIPT'
#!/bin/bash
# claude-state.sh — can claude think right now? Prints one tab-separated line:
#
#   <state>  <reset epoch or 0>  <detail or ->  <signatures or ->
#
#   ok            nothing below
#   limited       a usage limit. Detail is the reset time as claude printed it
#   context-full  the conversation no longer fits. Detail is claude's message
#   api-error     a request failed after claude's own retries. Detail is the message
#
# The nudger asks before it presses keys and the watchdog asks on every pass, so both
# judge the pane the same way. Only the last lines count, and only lines that start
# with one of claude's own messages: the agent's prose can mention "usage limit
# reached" too. A line the watchdog has acted on is listed in claude/handled and
# skipped, because an old limit message stays on screen after the limit lifts, and
# acting on it again would pause an agent that is working.
set -uo pipefail
source "${AGENT_ENV:?AGENT_ENV not set}"
DIR="${STATE_DIR:-/tmp/$AGENT-state}/claude"; mkdir -p "$DIR"
# The whole history, not the screen: a line's signature counts the identical lines
# before it, so a second "resets 3pm" after a wake is a new event, not the old one.
tmux capture-pane -p -S - -t "$SESSION" 2>/dev/null \
  | python3 -c '
import hashlib, os, re, sys, time
from datetime import datetime, timedelta
state_dir, retry = sys.argv[1], int(sys.argv[2])
now = int(time.time())

# Wording from Claude Code 2.1. It is not a stable interface: if claude changes it,
# these stop matching and the agent falls back to the frozen-pane check.
LIMIT = re.compile(r"^[^A-Za-z]*(you.ve hit your limit|usage limit reached|claude (ai )?usage limit reached"
                   r"|your limit will reset|you.re out of (usage credits|extra usage)"
                   r"|stop and wait for limit to reset)", re.I)
ERROR = re.compile(r"^[^A-Za-z]*(api error|prompt is too long|conversation too long|request timed out"
                   r"|repeated 529|server is temporarily limiting requests|connection error)", re.I)
FULL  = re.compile(r"prompt is too long|conversation too long", re.I)

lines = sys.stdin.buffer.read().decode("utf-8", "replace").splitlines()
seen, sigs = {}, []
for l in lines:
    t = l.strip()
    seen[t] = seen.get(t, 0) + 1
    sigs.append(hashlib.md5(("%s|%d" % (t, seen[t])).encode()).hexdigest()[:16])
try:
    handled = set(open(os.path.join(state_dir, "handled")).read().split())
except OSError:
    handled = set()
tail = [i for i, l in enumerate(lines) if l.strip()][-20:]
hits = [i for i in tail if sigs[i] not in handled and (LIMIT.search(lines[i]) or ERROR.search(lines[i]))]

def out(state, until=0, detail="-", keys="-"):
    detail = re.sub(r"\s+", " ", detail).strip()[:200] or "-"
    sys.stdout.buffer.write(("%s\t%d\t%s\t%s\n" % (state, until, detail, keys)).encode())
    sys.exit(0)

if not hits:
    out("ok")
keys = ",".join(sigs[i] for i in hits)
last = lines[hits[-1]]
limits = [lines[i] for i in hits if LIMIT.search(lines[i])]
if not limits:
    out("context-full" if FULL.search(last) else "api-error", 0, re.sub(r"^[^A-Za-z]*", "", last), keys)

MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()
WHEN = re.compile(r"(?:resets?|automatically)\s+(?:at\s+)?((?:([A-Z][a-z]{2})\s+(\d{1,2})(?:,\s*(\d{4}))?,?\s+(?:at\s+)?)?"
                  r"(\d{1,2})(?::(\d{2}))?\s*([ap]m)(?:\s*\(([^)]+)\))?)", re.I)

def reset_at(text):
    """The reset as an epoch, or None. Claude prints local time, with a zone name in brackets when
    it knows one, and adds the date when the reset is more than a day away."""
    m = re.search(r"\|(\d{10})\b", text)   # older clients: "Claude AI usage limit reached|<epoch>"
    if m:
        return int(m.group(1)), ""
    m = WHEN.search(text)
    if not m:
        return None
    label, mon, day, year, hour, minute, ampm, zone = m.groups()
    tz = None
    if zone:
        try:
            from zoneinfo import ZoneInfo
            tz = ZoneInfo(zone)
        except Exception:
            tz = None
    current = datetime.now(tz) if tz else datetime.now().astimezone()
    h = int(hour) % 12 + (12 if ampm.lower() == "pm" else 0)
    try:
        if mon:
            when = current.replace(year=int(year or current.year), month=MONTHS.index(mon.lower()[:3]) + 1,
                                   day=int(day), hour=h, minute=int(minute or 0), second=0, microsecond=0)
            if not year and when < current - timedelta(days=1):
                when = when.replace(year=when.year + 1)
        else:
            when = current.replace(hour=h, minute=int(minute or 0), second=0, microsecond=0)
            # A time with no date is today or tomorrow. One that passed in the last few hours is
            # an old message for a limit that has already lifted, not one a day away.
            if when < current - timedelta(hours=6):
                when += timedelta(days=1)
    except ValueError:
        return None
    return int(when.timestamp()) + 60, label   # a minute late beats a wake into the limit

found = None
for l in reversed(limits):
    found = reset_at(l)
    if found:
        break
if found:
    out("limited", found[0], found[1], keys)
# No time to read, so retry later. The first sighting fixes the retry time, or every
# pass would push it back.
memo = os.path.join(state_dir, "limit-until")
try:
    k, until = open(memo).read().split()
    if k == keys:
        out("limited", int(until), "-", keys)
except (OSError, ValueError):
    pass
with open(memo + ".tmp", "w") as f:
    f.write("%s %d\n" % (keys, now + retry))
os.replace(memo + ".tmp", memo)
out("limited", now + retry, "-", keys)
' "$DIR" "${USAGE_LIMIT_RETRY_SECS:-1800}"
SCRIPT

say "writing scripts/wake.sh"
cat > "$WORKSPACE/scripts/wake.sh" <<'SCRIPT'
#!/bin/bash
# wake.sh — send the "." wake signal into claude's pane. Exit 1 if it can't.
#
# claude can be showing its usage-limit menu. Enter there picks the highlighted
# option, and the options include "Add funds to continue" and "Upgrade your plan",
# so the menu is closed with Escape first, and nothing is typed if it stays open.
set -uo pipefail
source "${AGENT_ENV:?AGENT_ENV not set}"
MENU='stop and wait for limit to reset'
# Blank lines dropped first: the capture is the whole screen, so on a pane that isn't
# full the last rows are empty and a plain tail would never see the menu.
menu_open() {
    tmux capture-pane -p -t "$SESSION" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 30 | grep -qi "$MENU"
}

tmux has-session -t "$SESSION" 2>/dev/null || exit 1
if menu_open; then
    tmux send-keys -t "$SESSION" Escape
    sleep 1
    if menu_open; then
        echo "wake: claude's usage-limit menu is still open; not pressing Enter" >&2
        exit 1
    fi
fi
# Two calls, not one: `send-keys "." Enter` races Claude's input buffering
# and the "." can be swallowed, leaving a bare Enter that does nothing.
tmux send-keys -t "$SESSION" "."
sleep 0.1
tmux send-keys -t "$SESSION" Enter
SCRIPT

# ── 6. nudger: this is what makes the agent real-time rather than a poller
say "writing scripts/nudger.sh"
cat > "$WORKSPACE/scripts/nudger.sh" <<'SCRIPT'
#!/bin/bash
# Tails the event queue and wakes the session with a literal "." + Enter when an
# ACTIONABLE line lands. The "." is a wake signal, not a message — the bootstrap
# prompt tells the agent to drain its queue on every ".".
#
# Provider-agnostic: it matches on the NORMALIZED envelope fields that every
# listener writes, so it works for slack, discord, or anything you add.
#
# DEBOUNCE IS LOAD-BEARING. Claude queues keystrokes: a burst of 5 events in 5
# seconds becomes 5 queued turns, and the agent spends its budget re-waking
# instead of working. One burst must produce exactly ONE wake.
set -uo pipefail
source "${AGENT_ENV:?AGENT_ENV not set}"
STATE="${STATE_DIR:-/tmp/$AGENT-state}/nudger"; mkdir -p "$STATE"
LAST="$STATE/last-nudge"
DEGRADED="${STATE_DIR:-/tmp/$AGENT-state}/claude/degraded"   # written by the watchdog
log() { echo "$(date -u +%FT%TZ) [$AGENT-nudger] $*"; }
# State survives a restart. A lock left by a killed typing.sh would otherwise block
# that channel for good, and clearing the markers stops any loop still running.
rm -rf "${STATE_DIR:-/tmp/$AGENT-state}/typing"

# Build the actionable pattern from the normalized envelope.
PAT='"mentions_self":true'
[ -n "${OWNER_ID:-}" ] && PAT="$PAT|\"user\":\"$OWNER_ID\""
for c in $(printf '%s' "${INCIDENT_CHANNELS:-}" | tr ',' ' '); do
    [ -n "$c" ] && PAT="$PAT|\"channel\":\"$c\""
done
PAT="$PAT|\"kind\":\"job\"|\"kind\":\"signal\""
[ -n "${NUDGE_PATTERN:-}" ] && PAT="$PAT|$NUDGE_PATTERN"

nudge() { # nudge <why>
    local now last
    now="$(date +%s)"; last="$(cat "$LAST" 2>/dev/null || echo 0)"
    if [ "$((now - last))" -lt "$NUDGE_COOLDOWN_SECONDS" ]; then
        log "debounced ($NUDGE_COOLDOWN_SECONDS s window): $1"; return
    fi
    tmux has-session -t "$SESSION" 2>/dev/null || { log "no session — cannot nudge"; return; }
    echo "$now" > "$LAST"
    if AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/wake.sh"; then log "nudged: $1"
    else log "could not wake claude: $1"; fi
}

# The channel of a message someone is waiting on a reply to, or nothing. Only what
# signal-filter.py tags [OWNER-DM], [OWNER-CHAN] or [MENTION], which the agent is
# expected to answer: an [INCIDENT] or [JOB] often ends in silence, and "typing…" or an
# automatic reply would promise one. The id becomes a file name and part of a URL, so
# only the provider's own id format passes.
reply_channel() { # reply_channel <event line>
    printf '%s' "$1" | python3 -c '
import json,re,sys
provider,owner,me,chans=sys.argv[1:]
e=json.load(sys.stdin)
ch=str(e.get("channel") or "")
ids={"discord":r"[0-9]+","slack":r"[A-Z0-9]+"}
if e.get("provider")!=provider or provider not in ids or not re.fullmatch(ids[provider],ch): sys.exit()
if e.get("kind")!="message" or e.get("is_bot") or (me and e.get("user")==me): sys.exit()
mine=owner and e.get("user")==owner
if (mine and (e.get("channel_type")=="dm" or ch in chans.split(","))) or e.get("mentions_self"):
    print(ch)' "${CHAT_PROVIDER:-none}" "${OWNER_ID:-}" "${SELF_BOT_ID:-}" "${OWNER_CHANNELS:-}" 2>/dev/null
}

# Tell the sender why no answer is coming yet. Once per channel per episode, so a
# conversation during a four-hour limit gets one notice, not one per message.
auto_reply() { # auto_reply <event line> <text> <episode>
    local chan f
    chan="$(reply_channel "$1")"
    [ -n "$chan" ] || return 0
    f="$STATE/replied-$chan"
    [ "$(cat "$f" 2>/dev/null)" = "$3" ] && return 0
    echo "$3" > "$f"
    AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/notify.sh" "$2" "$chan" >/dev/null 2>&1 &
    log "auto-replied in $chan ($3)"
}

# True when claude can't think and the event must wait. At a usage limit a wake
# would only type into claude's limit menu, so the event stays in the queue and the
# watchdog wakes the agent after the reset. When requests keep failing, the wake
# still goes ahead, since it is also the retry.
held() { # held <event line>
    local st until detail keys
    IFS=$'\t' read -r st until detail keys < <(AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/claude-state.sh")
    if [ "${st:-}" = limited ] && [ "${until:-0}" -gt "$(date +%s)" ]; then
        local when="as soon as it resets"
        [ "${detail:--}" = - ] || when="when it resets ($detail)"
        auto_reply "$1" "⏳ I've hit my Claude usage limit, so I can't work on this yet. I'll pick up your message $when." "limit-$keys"
        log "held for the usage limit: $(printf '%s' "$1" | cut -c1-100)"
        return 0
    fi
    if [ -f "$DEGRADED" ]; then
        auto_reply "$1" "⚠️ I'm having trouble reaching Claude ($(sed -n 2p "$DEGRADED")), so my reply may be late. I'll keep retrying." "degraded-$(sed -n 1p "$DEGRADED")"
    fi
    return 1
}

show_typing() { # show_typing <event line>
    local chan
    chan="$(reply_channel "$1")"
    [ -n "$chan" ] || return 0
    # With no session, nothing is working on this message, so don't imply otherwise.
    tmux has-session -t "$SESSION" 2>/dev/null || return 0
    AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/typing.sh" "$chan" >/dev/null 2>&1 &
}

while [ ! -f "$EVENT_JSONL" ]; do
    log "waiting for $EVENT_JSONL to appear"   # log BEFORE blocking: a process
    sleep 5                                    # waiting on a file that never
done                                           # appears must not look healthy
log "watching $EVENT_JSONL"
log "actionable pattern: $PAT"
tail -n0 -F "$EVENT_JSONL" 2>/dev/null | while IFS= read -r line; do
    printf '%s' "$line" | grep -qE "$PAT" || continue
    held "$line" && continue
    show_typing "$line"   # before nudge, so a debounced message still shows it
    nudge "$(printf '%s' "$line" | cut -c1-140)"
done
SCRIPT

# ── 7. watchdog: turns silent failure into self-healing or a loud, specific alert
say "writing scripts/watchdog.sh"
cat > "$WORKSPACE/scripts/watchdog.sh" <<'SCRIPT'
#!/bin/bash
# One invocation = one health pass. Fired by a systemd timer every ~2 min.
# Checks, in order of how silently each one kills the agent:
#   1. unit not running             -> start it
#   2. tmux session missing         -> restart the unit
#   3. login/auth expired, or the
#      bypass warning unanswered    -> ALERT (only a human can fix this)
#   4. claude can't think           -> usage limit: pause, wake after the reset;
#                                      API errors: wake with backoff, then alert;
#                                      context full: /compact, then restart
#   5. pane byte-identical too long -> loop frozen: re-bootstrap, else restart
#   6. session alive, loop not armed-> re-bootstrap (a bare claude idles forever)
#
# Deliberately NOT `set -e`: a failing check must not abort the remaining ones.
set -uo pipefail
source "${AGENT_ENV:?AGENT_ENV not set}"
STATE="${STATE_DIR:-/tmp/$AGENT-state}/watchdog"; mkdir -p "$STATE"
log() { echo "$(date -u +%FT%TZ) [watchdog:$AGENT] $*"; }
tell() { # tell <message> — news for the owner that isn't a fault
    [ -x "$WORKSPACE/scripts/notify.sh" ] && \
      AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/notify.sh" "$AGENT: $1" || true
}

alert() { # alert <key> <message> [dedupe-secs] — deduped so we never spam
    local key="$1" msg="$2" dedupe="${3:-1800}" f="$STATE/alert-$1" now
    now="$(date +%s)"
    if [ -f "$f" ] && [ "$((now - $(cat "$f")))" -lt "$dedupe" ]; then
        log "alert '$key' deduped"; return
    fi
    echo "$now" > "$f"
    log "ALERT[$key]: $msg"
    [ -x "$WORKSPACE/scripts/notify.sh" ] && \
      AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/notify.sh" "⚠️ $AGENT watchdog: $msg" || true
    return 0
}

# The only place the watchdog touches its supervisor. In a container there are no
# units: the entrypoint's restart loop owns run.sh, and run.sh exits once the tmux
# session is gone, so killing the session IS the restart.
unit_active() {
    [ "$SUPERVISOR" = container ] && return 0
    systemctl --user is-active --quiet "$CLAUDE_UNIT"
}
unit_start() {
    [ "$SUPERVISOR" = container ] && return 0
    systemctl --user start "$CLAUDE_UNIT"
}
unit_restart() {
    if [ "$SUPERVISOR" = container ]; then
        tmux kill-session -t "$SESSION" 2>/dev/null || true
    else
        systemctl --user restart "$CLAUDE_UNIT"
    fi
}

restart_guarded() { # never restart-loop: at most once an hour
    local f="$STATE/last-restart" now; now="$(date +%s)"
    if [ -f "$f" ] && [ "$((now - $(cat "$f")))" -lt 3600 ]; then
        log "restart suppressed (cooldown)"; return 1
    fi
    echo "$now" > "$f"
    log "restarting $CLAUDE_UNIT"
    unit_restart
}

# 1. unit
if ! unit_active; then
    log "$CLAUDE_UNIT inactive — starting"
    unit_start || alert unit-start-failed "$CLAUDE_UNIT will not start"
    exit 0
fi

# 2. session
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "tmux session '$SESSION' missing while unit is active"
    restart_guarded || alert session-missing "session '$SESSION' gone and restart is in cooldown"
    exit 0
fi

PANE="$(tmux capture-pane -p -t "$SESSION" 2>/dev/null || true)"

# 3. login — a human-only fix, so alert rather than thrash the unit
if printf '%s' "$PANE" | grep -qiE 'invalid api key|/login|please run .*login|authentication_error|credit balance|select login method|paste code here|custom api key'; then
    alert login-expired "Claude login/credential problem — the agent cannot think until a human runs 'tmux attach -t $SESSION' and re-authenticates" 3600
    exit 0
fi
if printf '%s' "$PANE" | grep -qi 'yes, i accept'; then
    alert bypass-unaccepted "claude is holding on the bypass-permissions warning — a human must run 'tmux attach -t $SESSION' and accept it" 3600
    exit 0
fi

# 4. claude is running but can't think. None of these is fixed by re-pasting the
# prompt, which the checks below would do: its first step skips the queue backlog,
# so the messages that arrived meanwhile would never be answered.
CS="${STATE_DIR:-/tmp/$AGENT-state}/claude"; mkdir -p "$CS"; now="$(date +%s)"
IFS=$'\t' read -r cstate cuntil cdetail ckeys < <("$WORKSPACE/scripts/claude-state.sh")
handled() { # this pane's messages are dealt with; claude-state.sh skips them from now on
    printf '%s\n' "$ckeys" | tr ',' '\n' >> "$CS/handled"
    tail -n 200 "$CS/handled" > "$CS/handled.tmp" && mv "$CS/handled.tmp" "$CS/handled"
}
quiet_since() { # quiet_since <file> — true once the time at the end of <file> is 15 minutes old
    local t; t="$(awk '{print $NF}' "$1" 2>/dev/null)"
    [ "$((now - ${t:-0}))" -ge 900 ]
}
case "${cstate:-ok}" in
  limited)
    # The nudger holds events and replies to their senders until the reset.
    if [ "$now" -lt "$cuntil" ]; then
        if [ "$(cat "$CS/limit-alerted" 2>/dev/null)" != "$ckeys" ]; then
            echo "$ckeys" > "$CS/limit-alerted"
            when=""; [ "$cdetail" = - ] || when=" (resets $cdetail)"
            alert usage-limit "hit the Claude usage limit$when. Messages wait in the queue, their senders get an automatic reply, and the agent resumes after the reset" 60
        fi
        log "usage limit: paused until $(date -u -d "@$cuntil" +%FT%TZ 2>/dev/null || echo "$cuntil")"
        exit 0
    fi
    # Past the reset. If claude is still limited, it prints a new limit line,
    # which starts the next pause.
    if AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/wake.sh"; then
        handled
        log "usage limit reset; woke the agent to work through the queue"
        tell "the usage limit has reset. Catching up on the queue now."
    else
        alert limit-menu "the usage limit has reset, but claude's limit menu won't close. A human must run 'tmux attach -t $SESSION' and choose 'Stop and wait for limit to reset'" 3600
    fi
    exit 0 ;;
  api-error)
    # claude has already retried this request and given up, so wait before asking
    # again, and wait longer each time.
    read -r tries _ 2>/dev/null < "$CS/error-tries" || tries=0
    if [ "$(cut -d' ' -f1 "$CS/error-seen" 2>/dev/null)" != "$ckeys" ]; then
        echo "$ckeys $now" > "$CS/error-seen"
    fi
    seen="$(cut -d' ' -f2 "$CS/error-seen")"
    wait=$((API_ERROR_WAKE_SECS << (tries < 4 ? tries : 4))); [ "$wait" -le 3600 ] || wait=3600
    if [ "$((now - seen))" -lt "$wait" ]; then
        log "claude reported: $cdetail. Waking it in $((wait - (now - seen)))s"
        exit 0
    fi
    tries=$((tries + 1)); echo "$tries $now" > "$CS/error-tries"
    handled
    if [ "$tries" -ge "$API_ERROR_ALERT_AFTER" ]; then
        # The nudger reads this and tells new senders their reply may be late.
        [ -f "$CS/degraded" ] || printf '%s\n%s\n' "$now" "$cdetail" > "$CS/degraded"
        alert api-errors "claude's requests keep failing ($tries tries): $cdetail" 3600
    fi
    AGENT_ENV="$AGENT_ENV" "$WORKSPACE/scripts/wake.sh" && log "woke claude after an API error (try $tries)"
    exit 0 ;;
  context-full)
    if [ ! -f "$CS/compacted" ]; then
        handled; echo "$now" > "$CS/compacted"
        log "context full ($cdetail); compacting"
        tmux send-keys -t "$SESSION" "/compact"
        sleep 0.1
        tmux send-keys -t "$SESSION" Enter
    else
        handled; rm -f "$CS/compacted"
        alert context-full "claude's context is full and /compact didn't fix it ($cdetail). Restarting it: the live conversation is lost, the memory files carry over" 3600
        restart_guarded || alert context-full-stuck "context full and restart is in cooldown" 3600
    fi
    exit 0 ;;
  *)
    # A failure is over only after a quiet spell: right after a wake, claude is
    # still retrying and the pane shows no error yet.
    if [ -f "$CS/error-tries" ] && quiet_since "$CS/error-tries"; then
        [ -f "$CS/degraded" ] && tell "claude is answering again."
        rm -f "$CS/error-tries" "$CS/error-seen" "$CS/degraded"
    fi
    [ -f "$CS/compacted" ] && quiet_since "$CS/compacted" && rm -f "$CS/compacted"
    ;;
esac

# 5. frozen pane. The threshold MUST exceed the agent's longest idle
# ScheduleWakeup interval, or a normally-sleeping agent gets restarted.
HASH="$(printf '%s' "$PANE" | md5sum | cut -d' ' -f1)"
HF="$STATE/pane-hash"; TF="$STATE/pane-since"
if [ "$(cat "$HF" 2>/dev/null || echo)" = "$HASH" ]; then
    since="$(cat "$TF" 2>/dev/null || echo "$now")"
    if [ "$((now - since))" -ge "$IDLE_STALL_SECS" ]; then
        log "pane unchanged for $((now - since))s — loop looks frozen"
        if [ -x "$BOOTSTRAP_CMD" ]; then
            "$BOOTSTRAP_CMD" && log "re-bootstrapped frozen loop" && echo "$now" > "$TF"
        else
            restart_guarded || alert loop-frozen "loop frozen ${IDLE_STALL_SECS}s+, restart in cooldown"
        fi
        exit 0
    fi
else
    echo "$HASH" > "$HF"; echo "$now" > "$TF"
fi

# 6. armed? A restarted session with no prompt is a bare claude that idles
# forever while every instrument reports it healthy.
# A session younger than the runner's auto-paste delay is booting, not un-armed:
# pasting now means the prompt lands in the splash and then arrives a second time.
created="$(tmux display-message -p -t "$SESSION" '#{session_created}' 2>/dev/null || true)"
if [ "$((now - ${created:-0}))" -ge 60 ] && ! printf '%s' "$PANE" | grep -qiE "$AGENT|loop|wake|queue|cursor"; then
    log "session appears un-armed (no loop prompt in pane)"
    [ -x "$BOOTSTRAP_CMD" ] && "$BOOTSTRAP_CMD" && log "bootstrap re-armed"
fi
log "ok"
SCRIPT

# ── 8. helper bins
say "writing $BIN/$AGENT-bootstrap and $BIN/$AGENT-attach"
cat > "$BIN/$AGENT-bootstrap" <<EOF
#!/bin/bash
# Paste the /loop prompt into the running session (the runner also auto-loads it
# ~25s after start; use this to re-arm after a crash or a manual /clear).
set -euo pipefail
source "$WORKSPACE/agent.env"
tmux has-session -t "\$SESSION" 2>/dev/null || { echo "ERROR: session '\$SESSION' not running" >&2; exit 1; }
[ -f "\$BOOTSTRAP_FILE" ] || { echo "ERROR: prompt missing at \$BOOTSTRAP_FILE" >&2; exit 1; }
tmux load-buffer  -t "\$SESSION" -b "\$AGENT-boot" "\$BOOTSTRAP_FILE"
tmux paste-buffer -t "\$SESSION" -b "\$AGENT-boot"
sleep 1
tmux send-keys    -t "\$SESSION" Enter
tmux delete-buffer -b "\$AGENT-boot" 2>/dev/null || true
echo "loop prompt loaded into \$AGENT."
EOF
cat > "$BIN/$AGENT-attach" <<EOF
#!/bin/bash
# attach | status | restart | logs — detach from an attached session with Ctrl-B then d
set -euo pipefail
source "$WORKSPACE/agent.env"
case "\${1:-attach}" in
  attach)  exec tmux attach -t "\$SESSION" ;;
  status)  for u in "\$AGENT-claude.service" "\$AGENT-nudger.service" "\$AGENT-listener.service" "\$AGENT-liveness.timer"; do
             [ -f "\$HOME/.config/systemd/user/\$u" ] || continue
             printf '  %-30s %s\n' "\$u" "\$(systemctl --user is-active "\$u" 2>/dev/null | head -1)"; done
           tmux has-session -t "\$SESSION" 2>/dev/null && echo "  tmux session: alive" || echo "  tmux session: MISSING"
           echo "  provider: \$CHAT_PROVIDER" ;;
  restart) if [ "\$SUPERVISOR" = container ]; then tmux kill-session -t "\$SESSION"
           else systemctl --user restart "\$AGENT-claude.service"; fi
           echo "restarted; prompt auto-loads shortly after the session returns" ;;
  logs)    [ "\$SUPERVISOR" = systemd ] || { echo "logs go to the container: run 'docker compose logs -f' on the host" >&2; exit 1; }
           exec journalctl --user -u "\$AGENT-claude.service" -u "\$AGENT-liveness.service" -n 100 -f ;;
  *)       echo "usage: \$AGENT-attach {attach|status|restart|logs}" >&2; exit 1 ;;
esac
EOF
chmod 0755 "$BIN/$AGENT-bootstrap" "$BIN/$AGENT-attach"
chmod 0755 "$WORKSPACE/scripts"/{claude.sh,run.sh,nudger.sh,watchdog.sh,notify.sh,typing.sh,claude-state.sh,wake.sh}

# ── 9. the signal filter (provider-agnostic; works on the normalized envelope)
say "writing scripts/signal-filter.py"
cat > "$WORKSPACE/scripts/signal-filter.py" <<'SCRIPT'
#!/usr/bin/env python3
"""Read new events since the cursor and print ONLY what the agent must act on.

The queue is mostly firehose. An agent that reads it raw concludes "all quiet"
and misses the one message that mattered, so this filter is the ONLY sanctioned
way to read it. It advances the cursor itself; --peek inspects without advancing.

Provider-agnostic: it reads the NORMALIZED envelope that every listener writes,
so slack, discord and any producer you add all work identically here.

Tags: [OWNER-DM] [MENTION] [OWNER-CHAN] [INCIDENT] [JOB]
Exit 0 always; prints "(no new signal events)" when the queue is genuinely flat.
"""
import json, os, sys

env_path = os.environ.get("AGENT_ENV", os.path.expanduser("~/agent.env"))
ENV = {}
with open(env_path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            ENV[k.strip()] = v

JSONL  = ENV.get("EVENT_JSONL", "/tmp/agent-events.jsonl")
CURSOR = ENV.get("CURSOR_FILE", "/tmp/agent-cursor.txt")
OWNER  = ENV.get("OWNER_ID", "")
SELF   = ENV.get("SELF_BOT_ID", "")
INCIDENT_CHANNELS = {c for c in ENV.get("INCIDENT_CHANNELS", "").split(",") if c}
OWNER_CHANNELS    = {c for c in ENV.get("OWNER_CHANNELS", "").split(",") if c}
peek = "--peek" in sys.argv

size = os.path.getsize(JSONL) if os.path.exists(JSONL) else 0
try:
    cur = int(open(CURSOR).read().strip() or 0)
except Exception:
    cur = 0
# A cursor past EOF means the file was rotated or truncated. Re-read from the
# start — treating it as "nothing new" silently drops everything after the
# rotation, and a count that drops to zero is the classic false all-clear.
if cur > size:
    cur = 0

out = []
if size > cur:
    with open(JSONL, "rb") as f:
        f.seek(cur)
        for raw in f.read().decode("utf-8", "replace").splitlines():
            try:
                d = json.loads(raw)
            except Exception:
                continue

            kind = d.get("kind", "message")
            ch   = d.get("channel", "")
            user = d.get("user", "")
            text = (d.get("text") or "")[:400]

            # Non-message producers (cron, webhooks) are always signal.
            if kind in ("job", "signal"):
                out.append(f"[JOB] {d.get('job', kind)} :: {json.dumps(d)[:300]}")
                continue

            # Drop our own echoes, or the agent answers itself forever.
            # Bot traffic is kept only in channels we were told to triage.
            if SELF and user == SELF:
                continue
            if d.get("is_bot") and ch not in INCIDENT_CHANNELS:
                continue

            tag = None
            if OWNER and user == OWNER and d.get("channel_type") == "dm":
                tag = "OWNER-DM"
            elif d.get("mentions_self"):
                tag = "MENTION"
            elif OWNER and user == OWNER and ch in OWNER_CHANNELS:
                tag = "OWNER-CHAN"
            elif ch in INCIDENT_CHANNELS:
                tag = "INCIDENT"
            if tag:
                thread = d.get("thread") or ""
                out.append(f"[{tag}] ch={ch} user={user}"
                           + (f" thread={thread}" if thread else "")
                           + f" :: {text}")

if not peek:
    with open(CURSOR, "w") as f:
        f.write(str(size))

print("\n".join(out) if out else "(no new signal events)")
SCRIPT
chmod 0755 "$WORKSPACE/scripts/signal-filter.py"

# ── 10. chat listeners (optional). Each writes the SAME normalized envelope.
if [ "$CHAT_PROVIDER" = "slack" ]; then
  say "writing scripts/slack-listener.mjs (Socket Mode -> normalized JSONL)"
  cat > "$WORKSPACE/scripts/slack-listener.mjs" <<'SCRIPT'
#!/usr/bin/env node
// Slack Socket Mode -> one NORMALIZED JSON object per line.
// No public URL, no inbound firewall rule, no API quota for receiving.
// Env: SLACK_APP_TOKEN (xapp-...), SELF_BOT_ID, EVENT_JSONL.
import fs from 'node:fs'
const APP_TOKEN = process.env.SLACK_APP_TOKEN
const OUT  = process.env.EVENT_JSONL || '/tmp/agent-events.jsonl'
const SELF = process.env.SELF_BOT_ID || ''
const TAG  = '[slack-listener]'
if (!APP_TOKEN?.startsWith('xapp-')) { console.error(`${TAG} FATAL: SLACK_APP_TOKEN missing/not xapp-`); process.exit(1) }
let ws = null, delay = 1000
const log = (lvl, m, x) => (lvl === 'error' || lvl === 'warn' ? console.error : console.log)(
  `${new Date().toISOString()} ${TAG} [${lvl}] ${m}${x ? ' ' + JSON.stringify(x) : ''}`)
const write = (r) => { try { fs.appendFileSync(OUT, JSON.stringify(r) + '\n') } catch (e) { log('error', 'append failed', { e: e.message }) } }

function normalize (e) {
  const text = e.text || ''
  return {
    ts: new Date().toISOString(),
    provider: 'slack',
    kind: 'message',
    channel: e.channel || '',
    // channel_type 'im' is Slack's DM marker; normalize it so the filter
    // never has to know provider-specific vocabulary.
    channel_type: e.channel_type === 'im' ? 'dm' : 'channel',
    user: e.user || e.bot_id || '',
    text,
    thread: e.thread_ts || e.ts || '',
    is_bot: Boolean(e.bot_id || e.subtype === 'bot_message'),
    mentions_self: SELF ? text.includes(`<@${SELF}>`) : false,
    raw: e,
  }
}

async function open () {
  const r = await fetch('https://slack.com/api/apps.connections.open',
    { method: 'POST', headers: { Authorization: `Bearer ${APP_TOKEN}` } })
  const d = await r.json()
  if (!d.ok) throw new Error(`apps.connections.open: ${d.error}`)
  // debug_reconnects gives a reconnect hint before Slack's ~30min recycle,
  // so we don't drop events in the gap.
  return d.url + (d.url.includes('?') ? '&' : '?') + 'debug_reconnects=true'
}
function retry (why) { log('info', `reconnect in ${delay}ms`, { why }); setTimeout(connect, delay); delay = Math.min(delay * 2, 60000) }
async function connect () {
  let url; try { url = await open() } catch (e) { log('error', 'open failed', { e: e.message }); return retry('open') }
  ws = new WebSocket(url)
  ws.addEventListener('open', () => { log('info', 'socket open'); delay = 1000 })
  ws.addEventListener('message', (ev) => {
    let m; try { m = JSON.parse(ev.data) } catch { return log('warn', 'non-json frame') }
    // Ack FIRST — Slack redelivers after ~3s if we ack after the disk write.
    if (m.envelope_id) { try { ws.send(JSON.stringify({ envelope_id: m.envelope_id })) } catch {} }
    if (m.type === 'hello') return log('info', 'hello', { n: m.num_connections })
    if (m.type === 'disconnect') { log('info', 'disconnect requested', { reason: m.reason }); try { ws.close() } catch {}; return }
    if (m.type === 'events_api' && m.payload?.event) return write(normalize(m.payload.event))
    if (m.type === 'slash_commands' || m.type === 'interactive') {
      return write({ ts: new Date().toISOString(), provider: 'slack', kind: m.type, raw: m.payload })
    }
  })
  ws.addEventListener('close', (e) => { log('warn', 'closed', { code: e.code }); retry('close') })
  ws.addEventListener('error', (e) => log('error', 'socket error', { m: e.message || String(e) }))
}
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { try { ws?.close() } catch {}; process.exit(0) })
connect()
SCRIPT
fi

if [ "$CHAT_PROVIDER" = "discord" ]; then
  say "writing scripts/discord-listener.mjs (Gateway -> normalized JSONL)"
  cat > "$WORKSPACE/scripts/discord-listener.mjs" <<'SCRIPT'
#!/usr/bin/env node
// Discord Gateway -> one NORMALIZED JSON object per line, identical in shape to
// the Slack listener's output. Env: DISCORD_BOT_TOKEN, SELF_BOT_ID, EVENT_JSONL.
//
// REQUIRES the MESSAGE CONTENT INTENT enabled in the Discord developer portal.
// Without it every message arrives with an empty `content` — traffic the agent
// can see but cannot read, which looks exactly like a parsing bug.
import fs from 'node:fs'
const TOKEN = process.env.DISCORD_BOT_TOKEN
const OUT   = process.env.EVENT_JSONL || '/tmp/agent-events.jsonl'
const SELF  = process.env.SELF_BOT_ID || ''
const TAG   = '[discord-listener]'
// GUILDS(1<<0) | GUILD_MESSAGES(1<<9) | DIRECT_MESSAGES(1<<12) | MESSAGE_CONTENT(1<<15)
const INTENTS = 1 | (1 << 9) | (1 << 12) | (1 << 15)
if (!TOKEN) { console.error(`${TAG} FATAL: DISCORD_BOT_TOKEN missing`); process.exit(1) }

let ws = null, seq = null, hb = null, sessionId = null, resumeUrl = null, delay = 1000
const selfRoles = new Set()
const noteRole = (r) => { if (SELF && r?.tags?.bot_id === SELF) selfRoles.add(r.id) }
const log = (lvl, m, x) => (lvl === 'error' || lvl === 'warn' ? console.error : console.log)(
  `${new Date().toISOString()} ${TAG} [${lvl}] ${m}${x ? ' ' + JSON.stringify(x) : ''}`)
const write = (r) => { try { fs.appendFileSync(OUT, JSON.stringify(r) + '\n') } catch (e) { log('error', 'append failed', { e: e.message }) } }

function normalize (msg) {
  const text = msg.content || ''
  const mentioned = SELF
    ? (msg.mentions || []).some((u) => u.id === SELF) || text.includes(`<@${SELF}>`)
      || (msg.mention_roles || []).some((id) => selfRoles.has(id))
    : false
  return {
    ts: new Date().toISOString(),
    provider: 'discord',
    kind: 'message',
    channel: msg.channel_id || '',
    // No guild_id on a MESSAGE_CREATE means it arrived in a DM.
    channel_type: msg.guild_id ? 'channel' : 'dm',
    user: msg.author?.id || '',
    text,
    thread: msg.message_reference?.message_id || '',
    is_bot: Boolean(msg.author?.bot),
    mentions_self: mentioned,
    raw: msg,
  }
}

function send (op, d) { try { ws.send(JSON.stringify({ op, d })) } catch (e) { log('warn', 'send failed', { op, e: e.message }) } }
function startHeartbeat (ms) {
  clearInterval(hb)
  // Discord closes the socket if we miss heartbeats; jitter the first one as
  // the docs require so a fleet of bots doesn't thunder together.
  hb = setInterval(() => send(1, seq), ms)
}
function retry (why) {
  clearInterval(hb)
  log('info', `reconnect in ${delay}ms`, { why })
  setTimeout(connect, delay)
  delay = Math.min(delay * 2, 60000)
}

async function gatewayUrl () {
  if (resumeUrl) return resumeUrl
  const r = await fetch('https://discord.com/api/v10/gateway')
  const d = await r.json()
  if (!d.url) throw new Error('no gateway url')
  return d.url
}

async function connect () {
  let base
  try { base = await gatewayUrl() } catch (e) { log('error', 'gateway lookup failed', { e: e.message }); return retry('gateway') }
  ws = new WebSocket(`${base}?v=10&encoding=json`)

  ws.addEventListener('open', () => log('info', 'socket open'))
  ws.addEventListener('message', (ev) => {
    let m; try { m = JSON.parse(ev.data) } catch { return log('warn', 'non-json frame') }
    if (m.s !== null && m.s !== undefined) seq = m.s

    switch (m.op) {
      case 10: // HELLO
        startHeartbeat(m.d.heartbeat_interval)
        if (sessionId && resumeUrl) {
          log('info', 'resuming session')
          send(6, { token: TOKEN, session_id: sessionId, seq })
        } else {
          send(2, { token: TOKEN, intents: INTENTS, properties: { os: 'linux', browser: 'semperwake', device: 'semperwake' } })
        }
        return
      case 11: return                  // heartbeat ack
      case 1:  return send(1, seq)     // server asked for a heartbeat
      case 7:                          // RECONNECT
        log('info', 'reconnect requested'); try { ws.close() } catch {}; return
      case 9:                          // INVALID SESSION — cannot resume
        log('warn', 'invalid session; starting fresh')
        sessionId = null; resumeUrl = null
        try { ws.close() } catch {}; return
      case 0:                          // DISPATCH
        if (m.t === 'READY') {
          sessionId = m.d.session_id
          resumeUrl = m.d.resume_gateway_url
          delay = 1000
          log('info', 'ready', { user: m.d.user?.username, id: m.d.user?.id })
          if (SELF && m.d.user?.id && SELF !== m.d.user.id) {
            log('warn', 'SELF_BOT_ID does not match the logged-in bot id — mention detection and echo-dropping will not work', { configured: SELF, actual: m.d.user.id })
          }
          return
        }
        if (m.t === 'MESSAGE_CREATE') return write(normalize(m.d))
        if (m.t === 'GUILD_CREATE') return (m.d.roles || []).forEach(noteRole)
        if (m.t === 'GUILD_ROLE_CREATE' || m.t === 'GUILD_ROLE_UPDATE') return noteRole(m.d.role)
        return
    }
  })
  ws.addEventListener('close', (e) => { log('warn', 'closed', { code: e.code, reason: e.reason || '' }); retry('close') })
  ws.addEventListener('error', (e) => log('error', 'socket error', { m: e.message || String(e) }))
}
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { clearInterval(hb); try { ws?.close() } catch {}; process.exit(0) })
connect()
SCRIPT
fi

# A container has no systemd to hand these to: docker/entrypoint.sh starts and
# restarts the scripts generated above, and Docker restarts the container.
if [ "$SUPERVISOR" = container ]; then
  say "installed for container supervision (provider: $CHAT_PROVIDER)"
  exit 0
fi

# ── 11. systemd units
say "installing systemd user units"
cat > "$UN/$AGENT-claude.service" <<EOF
[Unit]
Description=$AGENT — always-on headless Claude Code session
Documentation=file:$WORKSPACE/scripts/run.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Runs synchronously: the wrapper blocks until the tmux session dies, so
# Restart=always supervises the real claude lifetime rather than a forked shell.
Environment=AGENT_ENV=$WORKSPACE/agent.env
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$WORKSPACE/scripts/run.sh
ExecStop=/usr/bin/tmux kill-session -t $SESSION
WorkingDirectory=$WORKSPACE
Restart=always
RestartSec=30
TimeoutStopSec=20
KillMode=mixed
SyslogIdentifier=$AGENT-claude

[Install]
WantedBy=default.target
EOF

cat > "$UN/$AGENT-liveness.service" <<EOF
[Unit]
Description=$AGENT liveness watchdog (self-heal + alert)
After=$AGENT-claude.service

[Service]
Type=oneshot
Environment=AGENT_ENV=$WORKSPACE/agent.env
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$WORKSPACE/scripts/watchdog.sh
SyslogIdentifier=$AGENT-liveness
EOF
cat > "$UN/$AGENT-liveness.timer" <<EOF
[Unit]
Description=Run $AGENT watchdog every 2 minutes

[Timer]
OnBootSec=90
OnUnitActiveSec=120
AccuracySec=15
Unit=$AGENT-liveness.service

[Install]
WantedBy=timers.target
EOF

if [ "$CHAT_PROVIDER" != "none" ]; then
LISTENER="$WORKSPACE/scripts/$CHAT_PROVIDER-listener.mjs"
cat > "$UN/$AGENT-listener.service" <<EOF
[Unit]
Description=$AGENT $CHAT_PROVIDER listener (events -> normalized JSONL)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$WORKSPACE/agent.env
ExecStart=$(command -v node) $LISTENER
WorkingDirectory=$WORKSPACE
Restart=always
RestartSec=5
SyslogIdentifier=$AGENT-listener

[Install]
WantedBy=default.target
EOF
cat > "$UN/$AGENT-nudger.service" <<EOF
[Unit]
Description=$AGENT nudger — instant tmux wake on actionable events
Documentation=file:$WORKSPACE/scripts/nudger.sh
# Hard requirements: no listener = nothing to watch; no session = nowhere to
# nudge. Requires= (not Wants=) so we fail closed rather than run blind.
Requires=$AGENT-listener.service $AGENT-claude.service
After=$AGENT-listener.service $AGENT-claude.service

[Service]
Type=simple
Environment=AGENT_ENV=$WORKSPACE/agent.env
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$WORKSPACE/scripts/nudger.sh
WorkingDirectory=$HOME
Restart=always
RestartSec=5
SyslogIdentifier=$AGENT-nudger

[Install]
WantedBy=default.target
EOF
fi

# ── 12. enable
say "daemon-reload + enable"
systemctl --user daemon-reload
systemctl --user enable --now "$AGENT-claude.service"
sleep 2
if [ "$CHAT_PROVIDER" != "none" ]; then
  systemctl --user enable --now "$AGENT-listener.service"
  systemctl --user enable --now "$AGENT-nudger.service"
fi
systemctl --user enable --now "$AGENT-liveness.timer"

echo
say "state:"
for u in "$AGENT-claude.service" "$AGENT-listener.service" "$AGENT-nudger.service" "$AGENT-liveness.timer"; do
  [ -f "$UN/$u" ] || continue
  printf '  %-30s %s\n' "$u" "$(systemctl --user is-active "$u" 2>/dev/null | head -1)"
done
printf '  %-30s %s\n' "chat provider" "$CHAT_PROVIDER"
cat <<EOF

Done. The loop prompt auto-loads into the session in ~25s.

  $AGENT-attach status      what is up
  $AGENT-attach             watch it think live (detach: Ctrl-B then d)
  $AGENT-attach logs        follow the journal
  $AGENT-bootstrap          re-arm the loop by hand

NEXT — do these two things or the agent is a shell with no brain:
  1. EDIT $WORKSPACE/BOOTSTRAP-PROMPT.txt and replace every <PLACEHOLDER>.
     Then run: $AGENT-bootstrap
  2. Fill $WORKSPACE/MEMORY.md and INSTINCTS.md. An agent with no memory
     re-derives its own rules every restart and gets them wrong differently each time.
EOF
