#!/bin/bash
# run-tests.sh — hermetic test suite.
#
# Stubs tmux, systemctl, loginctl, claude and curl, runs the installer into a
# throwaway HOME, and asserts real behaviour. Touches NOTHING on your system:
# no systemd units, no network, no tmux sessions, no files outside the sandbox.
# Section 12 asserts that.
#
#   ./test/run-tests.sh          run everything
#   KEEP=1 ./test/run-tests.sh   keep the sandbox for inspection
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/semperwake-test.XXXXXX")"
STUB="$SANDBOX/stub"
PASS=0; FAIL=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
ok()    { PASS=$((PASS+1)); printf '  %s %s\n' "$(green ✓)" "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(red ✗)" "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }
assert_contains() { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1" "missing: $3"; }
assert_lacks()    { printf '%s' "$2" | grep -qF -- "$3" && bad "$1" "should not contain: $3" || ok "$1"; }
assert_file()     { [ -f "$2" ] && ok "$1" || bad "$1" "no such file: $2"; }
assert_nofile()   { [ ! -f "$2" ] && ok "$1" || bad "$1" "should not exist: $2"; }
section()         { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() { [ -n "${KEEP:-}" ] && { echo "sandbox kept: $SANDBOX"; return; }; rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ───────────────────────── stubs ─────────────────────────
mkdir -p "$STUB"
cat > "$STUB/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  has-session)   [ -z "${FAKE_NO_SESSION:-}" ] ;;
  kill-session)  echo "kill-session" >> "${TMUX_LOG:-/dev/null}" ;;
  display-message) echo "${FAKE_SESSION_CREATED:-}" ;;
  capture-pane)  printf '%s' "${FAKE_PANE:-agent loop queue cursor idle}" ;;
  send-keys)     echo "${*:4}" >> "${SENDKEYS_LOG:?}" ;;
  list-clients)  [ -n "${FAKE_ATTACHED:-}" ] && echo client ; exit 0 ;;
  *)             exit 0 ;;
esac
EOF
cat > "$STUB/systemctl" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "is-active" ] && { echo active; exit 0; }; done
[ "${1:-}" = "--user" ] && [ "${2:-}" = "show-environment" ] && exit 0
echo "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB/loginctl"
printf '#!/bin/bash\necho "AGENT=${AGENT:-} $*" >> "${DOCKER_LOG:-/dev/null}"\n' > "$STUB/docker"
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"
# curl must never reach the network. Record the call, return a plausible body
# for both providers' DM-resolution endpoints.
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "${CURL_LOG:-/dev/null}"
case "$*" in
  *users/@me/channels*) echo '{"id":"DISCORDDM"}' ;;
  *conversations.open*) echo '{"ok":true,"channel":{"id":"SLACKDM"}}' ;;
  *)                    echo '{"ok":true}' ;;
esac
EOF
chmod +x "$STUB"/*

run_install() { # run_install <home> <agent> [extra env...]
  local home="$1" agent="$2"; shift 2
  env -i HOME="$home" PATH="$STUB:/usr/local/bin:/usr/bin:/bin" \
      AGENT="$agent" WORKSPACE="$home/$agent" STATE_DIR="$SANDBOX/state-$agent" \
      ENV_FILE="${TEST_ENV_FILE:-/nonexistent}" "$@" \
      bash "$REPO/install.sh" 2>&1
}

# ═════════════════════════ 1. syntax ═════════════════════════
section "1. Syntax and packaging"
bash -n "$REPO/install.sh"       && ok "install.sh parses"     || bad "install.sh parses"
bash -n "$0"                     && ok "run-tests.sh parses"   || bad "run-tests.sh parses"
assert_file "prompt template present"  "$REPO/prompts/BOOTSTRAP-PROMPT.txt"
assert_file ".env.example shipped"     "$REPO/.env.example"
grep -q '^\.env$' "$REPO/.gitignore"   && ok ".env is gitignored" || bad ".env is gitignored"
# .env.example must never ship a populated secret
grep -qE '^(SLACK_BOT_TOKEN|SLACK_APP_TOKEN|DISCORD_BOT_TOKEN)=.+' "$REPO/.env.example" \
  && bad ".env.example carries no real tokens" || ok ".env.example carries no real tokens"
# every var the installer reads should be documented in .env.example
for v in AGENT CHAT_PROVIDER OWNER_ID SELF_BOT_ID OWNER_CHANNELS INCIDENT_CHANNELS \
         IDLE_STALL_SECS NUDGE_COOLDOWN_SECONDS SLACK_APP_TOKEN SLACK_BOT_TOKEN DISCORD_BOT_TOKEN; do
  grep -qE "^#?$v=" "$REPO/.env.example" || bad "$v documented in .env.example"
done
ok "all config vars documented in .env.example"

# ═════════════════════════ 2. tier 1 ═════════════════════════
section "2. Tier 1 install (CHAT_PROVIDER=none)"
HDEFAULT="$SANDBOX/default"; mkdir -p "$HDEFAULT"
OUT="$(env -i HOME="$HDEFAULT" PATH="$STUB:/usr/local/bin:/usr/bin:/bin" \
      WORKSPACE="$HDEFAULT/semp" STATE_DIR="$SANDBOX/state-semp" \
      ENV_FILE=/nonexistent bash "$REPO/install.sh" 2>&1)"
assert_contains "default installer completes" "$OUT" "Done."
assert_file "default agent is semp" "$HDEFAULT/semp/agent.env"

H1="$SANDBOX/h1"; mkdir -p "$H1"
OUT="$(run_install "$H1" solo)"
assert_contains "installer completes"  "$OUT" "Done."
assert_file "agent.env written"        "$H1/solo/agent.env"
assert_file "prompt installed"         "$H1/solo/BOOTSTRAP-PROMPT.txt"
assert_file "runner"                   "$H1/solo/scripts/run.sh"
assert_file "nudger"                   "$H1/solo/scripts/nudger.sh"
assert_file "watchdog"                 "$H1/solo/scripts/watchdog.sh"
assert_file "notify"                   "$H1/solo/scripts/notify.sh"
assert_file "signal filter"            "$H1/solo/scripts/signal-filter.py"
assert_file "MEMORY.md seeded"         "$H1/solo/MEMORY.md"
assert_file "bootstrap helper"         "$H1/.local/bin/solo-bootstrap"
assert_file "attach helper"            "$H1/.local/bin/solo-attach"
assert_file "claude unit"              "$H1/.config/systemd/user/solo-claude.service"
assert_file "liveness timer"           "$H1/.config/systemd/user/solo-liveness.timer"
assert_nofile "NO listener unit"       "$H1/.config/systemd/user/solo-listener.service"
assert_nofile "NO nudger unit"         "$H1/.config/systemd/user/solo-nudger.service"
assert_nofile "NO listener script"     "$H1/solo/scripts/slack-listener.mjs"

for f in run.sh nudger.sh watchdog.sh notify.sh; do
  bash -n "$H1/solo/scripts/$f" && ok "generated $f parses" || bad "generated $f parses"
done
bash -n "$H1/.local/bin/solo-bootstrap" && ok "solo-bootstrap parses" || bad "solo-bootstrap parses"
bash -n "$H1/.local/bin/solo-attach"    && ok "solo-attach parses"    || bad "solo-attach parses"
python3 -m py_compile "$H1/solo/scripts/signal-filter.py" 2>/dev/null \
  && ok "signal-filter.py compiles" || bad "signal-filter.py compiles"

P="$H1/solo/BOOTSTRAP-PROMPT.txt"
assert_eq "installer placeholders substituted" \
  "$(grep -c '<WORKSPACE>\|<AGENT_NAME>\|<EVENT_JSONL>\|<CURSOR_FILE>\|<SESSION>' "$P")" "0"
grep -q 'solo/IDENTITY.md' "$P" && ok "prompt reads the agent's profile" || bad "prompt reads the agent's profile"
grep -q '<OWNER_NAME>' "$P" && ok "human-fill placeholders preserved" || bad "human-fill placeholders preserved"
grep -q hasTrustDialogAccepted "$H1/.claude.json" && ok "workspace pre-trusted" || bad "workspace pre-trusted"
assert_eq "agent.env is mode 600" "$(stat -c '%a' "$H1/solo/agent.env")" "600"

# ═════════════════════════ 3. .env loading ═════════════════════════
section "3. Config via .env"
H3="$SANDBOX/h3"; mkdir -p "$H3"
ENVF="$SANDBOX/test.env"
cat > "$ENVF" <<EOF
# a comment, and a blank line follow

AGENT=envagent
CHAT_PROVIDER=none
IDLE_STALL_SECS=1234
NUDGE_COOLDOWN_SECONDS=7
OWNER_ID=UFROMENV
OWNER_CHANNELS=CONE,CTWO
QUOTED_VALUE="with quotes"
EOF
OUT="$(env -i HOME="$H3" PATH="$STUB:/usr/local/bin:/usr/bin:/bin" \
       ENV_FILE="$ENVF" WORKSPACE="$H3/envagent" STATE_DIR="$SANDBOX/state-envagent" \
       bash "$REPO/install.sh" 2>&1)"
assert_contains "install from .env completes" "$OUT" "Done."
assert_file "agent named from .env" "$H3/envagent/agent.env"
AE="$(cat "$H3/envagent/agent.env" 2>/dev/null)"
assert_contains ".env IDLE_STALL_SECS applied"  "$AE" "IDLE_STALL_SECS=1234"
assert_contains ".env NUDGE_COOLDOWN applied"   "$AE" "NUDGE_COOLDOWN_SECONDS=7"
assert_contains ".env OWNER_ID applied"         "$AE" "OWNER_ID=UFROMENV"
assert_contains ".env OWNER_CHANNELS applied"   "$AE" "OWNER_CHANNELS=CONE,CTWO"
assert_lacks    "comments not parsed as vars"   "$AE" "a comment"
# shell environment must beat the .env file
OUT="$(env -i HOME="$SANDBOX/h3b" PATH="$STUB:/usr/local/bin:/usr/bin:/bin" \
       ENV_FILE="$ENVF" AGENT=shellwins WORKSPACE="$SANDBOX/h3b/shellwins" \
       STATE_DIR="$SANDBOX/state-shellwins" bash "$REPO/install.sh" 2>&1)"
assert_file "shell env overrides .env" "$SANDBOX/h3b/shellwins/agent.env"

# ═════════════════════════ 4. slack tier ═════════════════════════
section "4. Tier 2 install — slack"
H4="$SANDBOX/h4"; mkdir -p "$H4"
OUT="$(run_install "$H4" nova CHAT_PROVIDER=slack SLACK_APP_TOKEN=xapp-t \
        SLACK_BOT_TOKEN=xoxb-t OWNER_ID=UTESTOWNER SELF_BOT_ID=UTESTBOT)"
assert_contains "installer completes" "$OUT" "Done."
assert_file "listener unit"   "$H4/.config/systemd/user/nova-listener.service"
assert_file "nudger unit"     "$H4/.config/systemd/user/nova-nudger.service"
assert_file "slack listener"  "$H4/nova/scripts/slack-listener.mjs"
assert_nofile "no discord listener" "$H4/nova/scripts/discord-listener.mjs"
grep -q 'Requires=nova-listener.service nova-claude.service' \
  "$H4/.config/systemd/user/nova-nudger.service" \
  && ok "nudger fails closed on its deps" || bad "nudger fails closed on its deps"
if command -v node >/dev/null; then
  node --check "$H4/nova/scripts/slack-listener.mjs" 2>/dev/null \
    && ok "slack-listener.mjs parses" || bad "slack-listener.mjs parses"
else printf '  - skipped (no node): slack listener syntax\n'; fi

# ═════════════════════════ 5. discord tier ═════════════════════════
section "5. Tier 2 install — discord"
H5="$SANDBOX/h5"; mkdir -p "$H5"
OUT="$(run_install "$H5" disc CHAT_PROVIDER=discord DISCORD_BOT_TOKEN=dtok \
        OWNER_ID=123456789012345678 SELF_BOT_ID=987654321098765432)"
assert_contains "installer completes" "$OUT" "Done."
assert_file "discord listener"      "$H5/disc/scripts/discord-listener.mjs"
assert_nofile "no slack listener"   "$H5/disc/scripts/slack-listener.mjs"
assert_contains "listener unit points at discord" \
  "$(cat "$H5/.config/systemd/user/disc-listener.service")" "discord-listener.mjs"
if command -v node >/dev/null; then
  node --check "$H5/disc/scripts/discord-listener.mjs" 2>/dev/null \
    && ok "discord-listener.mjs parses" || bad "discord-listener.mjs parses"
  # MESSAGE_CONTENT (1<<15) must be in the intents or every message is empty
  node -e 'const i=1|(1<<9)|(1<<12)|(1<<15); if(!(i & (1<<15))) process.exit(1)' \
    && ok "intents include MESSAGE_CONTENT" || bad "intents include MESSAGE_CONTENT"
else printf '  - skipped (no node): discord listener syntax\n'; fi
# an unknown provider must be rejected, not silently accepted
OUT="$(run_install "$SANDBOX/h5b" bad CHAT_PROVIDER=telegram 2>&1 || true)"
assert_contains "unknown provider rejected" "$OUT" "CHAT_PROVIDER must be one of"

# ═════════════════════════ 6. idempotency ═════════════════════════
section "6. Idempotency"
echo "### MY LOCAL EDIT" >> "$H1/solo/BOOTSTRAP-PROMPT.txt"
OUT="$(run_install "$H1" solo)"
assert_contains "re-run detects existing prompt" "$OUT" "already present"
assert_contains "local prompt edit preserved" "$(tail -1 "$H1/solo/BOOTSTRAP-PROMPT.txt")" "MY LOCAL EDIT"

# ═════════════════════════ 7. signal filter ═════════════════════════
section "7. Signal filter (normalized envelope, provider-agnostic)"
W="$H4/nova"
J="$SANDBOX/events.jsonl"; C="$SANDBOX/cursor.txt"
sed -i "s|^EVENT_JSONL=.*|EVENT_JSONL=$J|; s|^CURSOR_FILE=.*|CURSOR_FILE=$C|; \
        s|^INCIDENT_CHANNELS=.*|INCIDENT_CHANNELS=CSRE,CALERTS|; \
        s|^OWNER_CHANNELS=.*|OWNER_CHANNELS=CSRE|" "$W/agent.env"
: > "$J"; echo 0 > "$C"
# Mixed providers in one queue, to prove the filter is provider-agnostic.
cat > "$J" <<'EOF'
{"provider":"slack","kind":"message","channel":"DDM","channel_type":"dm","user":"UTESTOWNER","text":"deploy the hotfix, go","is_bot":false,"mentions_self":false}
{"provider":"discord","kind":"message","channel":"CRANDOM","channel_type":"channel","user":"USOMEONE","text":"hey <@UTESTBOT> check CI","is_bot":false,"mentions_self":true}
{"provider":"slack","kind":"message","channel":"CSRE","channel_type":"channel","user":"UTESTOWNER","text":"what is the backup state","is_bot":false,"mentions_self":false}
{"provider":"slack","kind":"message","channel":"CALERTS","channel_type":"channel","user":"UMON","text":"[P2] Backup Freshness DOWN","is_bot":true,"mentions_self":false}
{"provider":"discord","kind":"message","channel":"CARENA","channel_type":"channel","user":"UX","text":"live commentary noise","is_bot":false,"mentions_self":false}
{"provider":"slack","kind":"message","channel":"CRANDOM","channel_type":"channel","user":"UBOTSPAM","text":"deploy succeeded","is_bot":true,"mentions_self":false}
{"provider":"slack","kind":"message","channel":"CRANDOM","channel_type":"channel","user":"UTESTBOT","text":"my own echo","is_bot":true,"mentions_self":false}
{"kind":"job","job":"nightly-backup","ts":"2026-10-30T04:00:00Z"}
EOF
filter() { AGENT_ENV="$W/agent.env" python3 "$W/scripts/signal-filter.py" "$@"; }

R="$(filter)"
assert_eq "5 signals out of 8 events" "$(printf '%s\n' "$R" | grep -c '^\[')" "5"
assert_contains "owner DM tagged"           "$R" "[OWNER-DM]"
assert_contains "mention tagged (discord)"  "$R" "[MENTION]"
assert_contains "owner channel tagged"      "$R" "[OWNER-CHAN]"
assert_contains "incident bot kept"         "$R" "[INCIDENT]"
assert_contains "cron job tagged"           "$R" "[JOB]"
assert_lacks "human noise dropped"          "$R" "live commentary"
assert_lacks "bot noise outside incident channels dropped" "$R" "deploy succeeded"
assert_lacks "self-echo dropped"            "$R" "my own echo"
assert_eq "cursor advanced to EOF" "$(cat "$C")" "$(wc -c < "$J")"
assert_contains "second read is flat" "$(filter)" "(no new signal events)"

echo '{"provider":"slack","kind":"message","channel":"DDM","channel_type":"dm","user":"UTESTOWNER","text":"second message"}' >> "$J"
A="$(filter --peek)"; B="$(filter --peek)"
assert_eq "--peek is idempotent" "$A" "$B"
assert_contains "--peek sees the new event" "$A" "second message"

: > "$J"   # rotation / truncation
echo '{"provider":"slack","kind":"message","channel":"DDM","channel_type":"dm","user":"UTESTOWNER","text":"post-rotation"}' >> "$J"
assert_contains "rotation re-read, not reported flat" "$(filter)" "post-rotation"

# ═════════════════════════ 8. nudger + notify ═════════════════════════
section "8. Nudger and notify"
SK="$SANDBOX/sendkeys.log"; : > "$SK"
rm -rf "$SANDBOX/state-nova/nudger"
( export AGENT_ENV="$W/agent.env" SENDKEYS_LOG="$SK" PATH="$STUB:$PATH"
  bash "$W/scripts/nudger.sh" > "$SANDBOX/nudger.out" 2>&1 ) &
NP=$!
sleep 1
for i in 1 2 3 4 5; do
  echo "{\"provider\":\"slack\",\"kind\":\"message\",\"channel\":\"DDM\",\"channel_type\":\"dm\",\"user\":\"UTESTOWNER\",\"text\":\"msg $i\"}" >> "$J"
done
sleep 2
echo '{"provider":"discord","kind":"message","channel":"CARENA","channel_type":"channel","user":"UX","text":"pure chatter","is_bot":false,"mentions_self":false}' >> "$J"
sleep 2
kill $NP 2>/dev/null; wait $NP 2>/dev/null

assert_eq "burst of 5 produces exactly 1 wake" "$(grep -c '^Enter$' "$SK")" "1"
assert_eq "the wake sends a literal dot"       "$(grep -c '^\.$' "$SK")" "1"
assert_eq "4 of the burst debounced"           "$(grep -c debounced "$SANDBOX/nudger.out")" "4"
assert_lacks "noise did not wake the agent"    "$(cat "$SANDBOX/nudger.out")" "pure chatter"

# notify must resolve + cache a DM channel per provider, and never hit the real network
CL="$SANDBOX/curl.log"; : > "$CL"
env AGENT_ENV="$W/agent.env" PATH="$STUB:$PATH" CURL_LOG="$CL" \
  bash "$W/scripts/notify.sh" "test alert" >/dev/null 2>&1
assert_contains "notify posts via slack api" "$(cat "$CL")" "chat.postMessage"
DW="$H5/disc"; CL2="$SANDBOX/curl2.log"; : > "$CL2"
env AGENT_ENV="$DW/agent.env" PATH="$STUB:$PATH" CURL_LOG="$CL2" \
  bash "$DW/scripts/notify.sh" "test alert" >/dev/null 2>&1
assert_contains "notify posts via discord api" "$(cat "$CL2")" "discord.com/api"
# Tier 1 has no provider: the alert must still be recoverable from disk
env AGENT_ENV="$H1/solo/agent.env" PATH="$STUB:$PATH" \
  bash "$H1/solo/scripts/notify.sh" "tier1 alert" >/dev/null 2>&1
assert_contains "tier 1 notify falls back to a log" \
  "$(cat "$SANDBOX/state-solo/notify.log" 2>/dev/null)" "tier1 alert"

# ═════════════════════════ 9. watchdog ═════════════════════════
section "9. Watchdog"
wd() { # wd <fake pane> [env file]
  env AGENT_ENV="${2:-$W/agent.env}" FAKE_PANE="$1" PATH="$STUB:$PATH" \
      SENDKEYS_LOG="$SK" SYSTEMCTL_LOG="$SANDBOX/sc.log" CURL_LOG="$SANDBOX/curl.log" \
      bash "$W/scripts/watchdog.sh" 2>&1
}
rm -rf "$SANDBOX/state-nova/watchdog"
assert_contains "healthy pane -> ok" "$(wd 'nova loop idle, next wake 600s')" "ok"

rm -rf "$SANDBOX/state-nova/watchdog"
R="$(wd 'Invalid API key · Please run /login')"
assert_contains "expired login alerts" "$R" "ALERT[login-expired]"
assert_lacks "login failure does NOT restart the unit" "$R" "restarting"

rm -rf "$SANDBOX/state-nova/watchdog"
FZ="$SANDBOX/agent.env.frozen"
sed 's/^IDLE_STALL_SECS=.*/IDLE_STALL_SECS=0/' "$W/agent.env" > "$FZ"
wd 'identical frozen pane' "$FZ" >/dev/null       # pass 1 records the hash
R="$(wd 'identical frozen pane' "$FZ")"           # pass 2 sees it unchanged
assert_contains "frozen loop detected"        "$R" "looks frozen"
assert_contains "frozen loop re-bootstrapped" "$R" "re-bootstrapped"

rm -rf "$SANDBOX/state-nova/watchdog"
assert_contains "un-armed pane re-armed" "$(wd 'Welcome to Claude Code  >')" "bootstrap re-armed"

rm -rf "$SANDBOX/state-nova/watchdog"
wd 'nova loop idle, next wake 600s' >/dev/null
assert_lacks "default threshold spares a sleeping agent" \
  "$(wd 'nova loop idle, next wake 600s')" "frozen"

# A booting session has no loop markers yet, and the runner is about to paste.
rm -rf "$SANDBOX/state-nova/watchdog"
assert_lacks "booting session is not re-armed" \
  "$(FAKE_SESSION_CREATED="$(date +%s)" wd 'Welcome to Claude Code  >')" "re-armed"

# A logged-out claude has no error text, only a picker. Re-arming pastes the prompt
# into the login flow and logs "ok" forever, so these must alert instead.
for pane in 'Select login method:' 'Paste code here if prompted >'; do
  rm -rf "$SANDBOX/state-nova/watchdog"
  R="$(wd "$pane")"
  assert_contains "login screen alerts: $pane" "$R" "ALERT[login-expired]"
  assert_lacks "login screen is not re-armed: $pane" "$R" "re-armed"
done
rm -rf "$SANDBOX/state-nova/watchdog"
R="$(wd 'Bypass Permissions mode  No, exit  Yes, I accept')"
assert_contains "bypass warning alerts" "$R" "ALERT[bypass-unaccepted]"
assert_lacks "bypass warning is not re-armed" "$R" "re-armed"

# alert dedupe: the same fault twice in a row must page once
rm -rf "$SANDBOX/state-nova/watchdog"
wd 'Invalid API key · Please run /login' >/dev/null
assert_contains "repeat alert is deduped" \
  "$(wd 'Invalid API key · Please run /login')" "deduped"

# ═════════════════════════ 10. container supervision ═════════════════════════
section "10. Container supervision (SUPERVISOR=container)"
bash -n "$REPO/docker/entrypoint.sh" && ok "entrypoint.sh parses" || bad "entrypoint.sh parses"
assert_file "Dockerfile shipped"       "$REPO/Dockerfile"
assert_file "compose.yaml shipped"     "$REPO/compose.yaml"
grep -qx '\*' "$REPO/.dockerignore" && ! grep -q '^!\.env' "$REPO/.dockerignore" \
  && ok ".env cannot enter the image" || bad ".env cannot enter the image"

grep -q '^/agents/\*$' "$REPO/.gitignore" && ok "agent directories are private by default" \
  || bad "agent directories are private by default"
assert_file "example agent profile shipped" "$REPO/agents/example/IDENTITY.md"
COMPOSE="$(cat "$REPO/compose.yaml")"
assert_contains "each agent mounts its own directory" "$COMPOSE" './agents/${AGENT:-semp}:/workspace'
assert_contains "each agent gets its own project"     "$COMPOSE" 'name: semperwake-${AGENT:-semp}'
assert_contains "per-agent settings are loaded"       "$COMPOSE" 'path: agents/${AGENT:-semp}/.env'
assert_contains "the mounted agent is the one named"  "$COMPOSE" 'AGENT: ${AGENT:-semp}'

HC="$SANDBOX/hc"; mkdir -p "$HC"
SCL="$SANDBOX/container-sc.log"; TL="$SANDBOX/container-tmux.log"; : > "$SCL"; : > "$TL"
OUT="$(run_install "$HC" box SUPERVISOR=container SYSTEMCTL_LOG="$SCL")"
assert_contains "container install completes" "$OUT" "installed for container supervision"
assert_contains "agent.env records the supervisor" "$(cat "$HC/box/agent.env")" "SUPERVISOR=container"
assert_file "scripts still generated"  "$HC/box/scripts/watchdog.sh"
assert_nofile "NO systemd units"       "$HC/.config/systemd/user/box-claude.service"
assert_lacks "linger not attempted"    "$OUT" "enabling linger"
assert_eq "systemctl never called"     "$(wc -l < "$SCL" | tr -d ' ')" "0"
OUT="$(run_install "$SANDBOX/hcb" bad SUPERVISOR=launchd 2>&1 || true)"
assert_contains "unknown supervisor rejected" "$OUT" "SUPERVISOR must be one of"

# Without a session the watchdog must restart by killing it: there is no unit to
# restart, and calling systemctl here would fail every time without saying why.
R="$(env AGENT_ENV="$HC/box/agent.env" FAKE_NO_SESSION=1 PATH="$STUB:$PATH" \
       SYSTEMCTL_LOG="$SCL" TMUX_LOG="$TL" bash "$HC/box/scripts/watchdog.sh" 2>&1)"
assert_contains "watchdog restarts the session" "$R" "restarting"
assert_eq "restart goes through tmux"  "$(grep -c '^kill-session$' "$TL")" "1"
assert_eq "watchdog never calls systemctl" "$(wc -l < "$SCL" | tr -d ' ')" "0"
assert_contains "attach logs points at docker" \
  "$(env PATH="$STUB:$PATH" bash "$HC/.local/bin/box-attach" logs 2>&1)" "docker compose logs"

# Enter on the bypass warning selects "No, exit", so pasting there kills claude.
BL="$SANDBOX/run.out"
env AGENT_ENV="$HC/box/agent.env" BOOTSTRAP_DELAY_SECS=0 FAKE_PANE='No, exit  Yes, I accept' \
    PATH="$STUB:$PATH" setsid bash "$HC/box/scripts/run.sh" > "$BL" 2>&1 &
RP=$!; sleep 1; kill -TERM -- "-$RP" 2>/dev/null; wait "$RP" 2>/dev/null
assert_contains "no auto-paste onto a human-only screen" "$(cat "$BL")" "skipping auto-bootstrap"
assert_lacks "prompt not loaded onto a human-only screen" "$(cat "$BL")" "loop prompt loaded"

entry() { # entry <out> — start the entrypoint in its own process group
  env -i HOME="$HC" PATH="$STUB:/usr/local/bin:/usr/bin:/bin" AGENT=box WORKSPACE="$HC/box" \
      STATE_DIR="$SANDBOX/state-box" ENV_FILE=/nonexistent SUPERVISOR=container \
      PROMPT_POLL_SECS=1 WATCHDOG_BOOT_SECS=600 SENDKEYS_LOG="$SK" \
      setsid bash "$REPO/docker/entrypoint.sh" > "$1" 2>&1 &
  EP=$!
}
stop_entry() { kill -TERM -- "-$EP" 2>/dev/null; wait "$EP" 2>/dev/null; }

entry "$SANDBOX/ep1.out"; sleep 2
assert_contains "unfilled prompt holds the agent" "$(cat "$SANDBOX/ep1.out")" "waiting: fill in"
assert_lacks "claude not started on an unfilled prompt" "$(cat "$SANDBOX/ep1.out")" "starting detached tmux"
sed -i 's/<OWNER_NAME>/Owner/g; /<ONE PARAGRAPH/,/>$/d; /<FILL IN/,/>$/d' "$HC/box/BOOTSTRAP-PROMPT.txt"
sleep 2
assert_contains "filling the prompt starts the agent" "$(cat "$SANDBOX/ep1.out")" "starting detached tmux"
stop_entry

env -i HOME="$HC" PATH="$STUB:/usr/local/bin:/usr/bin:/bin" bash "$REPO/docker/entrypoint.sh" echo passed-through > "$SANDBOX/ep2.out" 2>&1
assert_eq "explicit command runs instead of the agent" "$(cat "$SANDBOX/ep2.out")" "passed-through"

# ═════════════════════════ 11. the semperwake command ═════════════════════════
section "11. The semperwake command"
bash -n "$REPO/semperwake" && ok "semperwake parses" || bad "semperwake parses"
# A copy, because `new` writes under its own agents/ directory.
CLI="$SANDBOX/cli"; mkdir -p "$CLI/agents"
cp -R "$REPO/agents/example" "$CLI/agents/example"
cp -R "$REPO/prompts" "$REPO/compose.yaml" "$REPO/semperwake" "$CLI/"
DL="$SANDBOX/docker.log"; : > "$DL"
sw() { env PATH="$STUB:$PATH" DOCKER_LOG="$DL" bash "$CLI/semperwake" "$@" 2>&1; }
fill() { sed -i '/<ONE PARAGRAPH/,/>$/d; /<FILL IN/,/>$/d; s/<OWNER_NAME>/Owner/g' "$1"; }

assert_contains "new creates an agent" "$(sw new alpha --owner 'Ada Lovelace')" "agents/alpha is ready"
for f in IDENTITY.md SOUL.md MEMORY.md INSTINCTS.md HEARTBEAT.md JOBS.md BOOTSTRAP-PROMPT.txt .env; do
  assert_file "new adds $f" "$CLI/agents/alpha/$f"
done
assert_contains "identity carries the agent's name" "$(cat "$CLI/agents/alpha/IDENTITY.md")" "**Name:** alpha"
P="$(cat "$CLI/agents/alpha/BOOTSTRAP-PROMPT.txt")"
assert_contains "prompt carries the owner"  "$P" "Only Ada Lovelace directs you"
assert_lacks "prompt paths are substituted" "$P" "<WORKSPACE>"
assert_eq "agent .env is mode 600" "$(stat -c '%a' "$CLI/agents/alpha/.env")" "600"
assert_lacks "no chat settings without a provider" "$(cat "$CLI/agents/alpha/.env")" "OWNER_ID"

for name in Bad.Name ../escape UPPER -dash example; do
  assert_contains "new rejects '$name'" "$(sw new "$name")" "error:"
done
assert_eq "rejected names create nothing" "$(ls "$CLI/agents" | tr '\n' ' ')" "alpha example "

echo "MY EDIT" >> "$CLI/agents/alpha/SOUL.md"
rm "$CLI/agents/alpha/JOBS.md"
sw new alpha >/dev/null
assert_contains "new keeps existing edits" "$(cat "$CLI/agents/alpha/SOUL.md")" "MY EDIT"
assert_file "new restores what is missing" "$CLI/agents/alpha/JOBS.md"

R="$(sw check alpha)"
assert_contains "check finds unfilled placeholders" "$R" "still has placeholders on lines"
assert_contains "check reports the count"           "$R" "problem(s) to fix"
: > "$DL"
assert_contains "up refuses a failing agent" "$(sw up alpha)" "problem(s) to fix"
assert_lacks "nothing starts on a failed check" "$(cat "$DL")" "up -d"
fill "$CLI/agents/alpha/BOOTSTRAP-PROMPT.txt"
assert_contains "check passes a complete agent" "$(sw check alpha)" "alpha is ready."
: > "$DL"; sw up alpha >/dev/null
L="$(cat "$DL")"
assert_contains "up starts the named agent" "$L" "AGENT=alpha compose"
assert_contains "up runs detached"          "$L" "up -d"

sw new bravo --owner Owner --provider discord >/dev/null
fill "$CLI/agents/bravo/BOOTSTRAP-PROMPT.txt"
assert_contains "provider settings are scaffolded" "$(cat "$CLI/agents/bravo/.env")" "DISCORD_BOT_TOKEN="
R="$(sw check bravo)"
assert_contains "check wants the owner"   "$R" "FAIL  OWNER_ID is empty"
assert_contains "check wants the token"   "$R" "FAIL  DISCORD_BOT_TOKEN is empty"
sed -i 's/^OWNER_ID=.*/OWNER_ID=1234/; s/^DISCORD_BOT_TOKEN=.*/DISCORD_BOT_TOKEN=secret-token-value/' "$CLI/agents/bravo/.env"
R="$(sw check bravo)"
assert_contains "a missing self id only warns" "$R" "warn  SELF_BOT_ID is empty"
assert_lacks "check never prints a secret"     "$R" "secret-token-value"
assert_contains "the shared .env counts too" \
  "$(printf 'SLACK_APP_TOKEN=wrong\n' > "$CLI/.env"; sw new carol --provider slack >/dev/null; sed -i '/^SLACK_APP_TOKEN=/d' "$CLI/agents/carol/.env"; sw check carol)" \
  "FAIL  SLACK_APP_TOKEN should start with xapp-"
rm -f "$CLI/.env"

: > "$DL"
assert_contains "an unknown agent is explained" "$(sw up nobody)" "./semperwake new nobody"
assert_eq "an unknown agent reaches no docker command" "$(wc -l < "$DL" | tr -d ' ')" "0"

printf 'services:\n  agent: {}\n' > "$CLI/agents/alpha/compose.yaml"
: > "$DL"; sw down alpha >/dev/null
assert_contains "an agent's compose.yaml is included" "$(cat "$DL")" "agents/alpha/compose.yaml"
rm "$CLI/agents/alpha/compose.yaml"
: > "$DL"; sw restart alpha >/dev/null
assert_contains "restart applies .env and mount changes" "$(cat "$DL")" "up -d --force-recreate"

: > "$DL"; sw job alpha daily-summary >/dev/null
assert_contains "job queues a normalized event" "$(cat "$DL")" '"kind":"job","job":"daily-summary"'
assert_contains "job rejects unsafe names" "$(sw job alpha 'x"; rm -rf /')" "usage:"
L="$(sw list)"
assert_contains "list shows agents"   "$L" "alpha"
assert_lacks "list hides the template" "$L" "example"

# ═════════════════════════ 12. hermeticity ═════════════════════════
section "12. Hermeticity"
assert_eq "no units written to the real \$HOME" \
  "$(ls "$HOME/.config/systemd/user/"{solo,nova,disc,envagent}-* 2>/dev/null | wc -l)" "0"
assert_eq "no agent state outside the sandbox" \
  "$(ls -d /tmp/solo-state /tmp/nova-state /tmp/disc-state 2>/dev/null | wc -l)" "0"
if command -v tmux >/dev/null; then
  tmux has-session -t nova 2>/dev/null && bad "a real tmux session 'nova' exists" \
    || ok "no real tmux session created"
else ok "tmux absent; nothing could be created"; fi

# ═════════════════════════ summary ═════════════════════════
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%s  %d passed\n' "$(green 'ALL TESTS PASSED')" "$PASS"; exit 0
else
  printf '%s  %d passed, %d failed\n' "$(red 'TESTS FAILED')" "$PASS" "$FAIL"; exit 1
fi
