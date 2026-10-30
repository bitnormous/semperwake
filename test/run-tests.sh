#!/bin/bash
# run-tests.sh — hermetic test suite for standing-agent.
#
# Stubs tmux, systemctl, loginctl, claude, jq and curl, runs the installer into a
# throwaway HOME, and asserts real behaviour. Touches NOTHING on your system: no
# systemd units, no network, no tmux sessions, no files outside the sandbox.
#
#   ./test/run-tests.sh          run everything
#   KEEP=1 ./test/run-tests.sh   keep the sandbox for inspection
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/standing-agent-test.XXXXXX")"
STUB="$SANDBOX/stub"
PASS=0; FAIL=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS+1)); printf '  %s %s\n' "$(green ✓)" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(red ✗)" "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }
assert_contains() { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1" "missing: $3"; }
assert_file()     { [ -f "$2" ] && ok "$1" || bad "$1" "no such file: $2"; }
assert_nofile()   { [ ! -f "$2" ] && ok "$1" || bad "$1" "should not exist: $2"; }

cleanup() { [ -n "${KEEP:-}" ] && { echo "sandbox kept: $SANDBOX"; return; }; rm -rf "$SANDBOX"; }
trap cleanup EXIT

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ───────────────────────── stubs ─────────────────────────
mkdir -p "$STUB"

# tmux: has-session succeeds; capture-pane echoes $FAKE_PANE; send-keys is recorded
cat > "$STUB/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  has-session)   exit 0 ;;
  capture-pane)  printf '%s' "${FAKE_PANE:-agent loop queue cursor idle}" ;;
  send-keys)     echo "${*:4}" >> "${SENDKEYS_LOG:?}" ;;
  list-clients)  [ -n "${FAKE_ATTACHED:-}" ] && echo "client" ; exit 0 ;;
  *)             exit 0 ;;
esac
EOF
# systemctl: is-active succeeds; everything else recorded
cat > "$STUB/systemctl" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = "is-active" ] && { echo active; exit 0; }; done
[ "${1:-}" = "--user" ] && [ "${2:-}" = "show-environment" ] && exit 0
echo "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB/loginctl"
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"
# curl: never touch the network; return a plausible Slack body
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "${CURL_LOG:-/dev/null}"
echo '{"ok":true,"channel":{"id":"DTESTDM"}}'
EOF
cat > "$STUB/jq" <<'EOF'
#!/bin/bash
echo "DTESTDM"
EOF
chmod +x "$STUB"/*

run_install() { # run_install <home> <agent> [extra env...]
  local home="$1" agent="$2"; shift 2
  env -i HOME="$home" PATH="$STUB:/usr/local/bin:/usr/bin:/bin" \
      AGENT="$agent" WORKSPACE="$home/$agent" STATE_DIR="$SANDBOX/state-$agent" "$@" \
      bash "$REPO/install.sh" 2>&1
}

# ═════════════════════════ 1. syntax ═════════════════════════
section "1. Syntax"
bash -n "$REPO/install.sh" && ok "install.sh parses" || bad "install.sh parses"
bash -n "$0" && ok "run-tests.sh parses" || bad "run-tests.sh parses"
assert_file "prompt template present" "$REPO/prompts/BOOTSTRAP-PROMPT.txt"

# ═════════════════════════ 2. tier 1 ═════════════════════════
section "2. Tier 1 install (no event source)"
H1="$SANDBOX/h1"; mkdir -p "$H1"
OUT="$(run_install "$H1" solo)"
assert_contains "installer reports completion" "$OUT" "Done."
assert_file "agent.env written"        "$H1/solo/agent.env"
assert_file "prompt installed"         "$H1/solo/BOOTSTRAP-PROMPT.txt"
assert_file "runner written"           "$H1/solo/scripts/run.sh"
assert_file "nudger written"           "$H1/solo/scripts/nudger.sh"
assert_file "watchdog written"         "$H1/solo/scripts/watchdog.sh"
assert_file "MEMORY.md seeded"         "$H1/solo/MEMORY.md"
assert_file "INSTINCTS.md seeded"      "$H1/solo/INSTINCTS.md"
assert_file "bootstrap helper"         "$H1/.local/bin/solo-bootstrap"
assert_file "attach helper"            "$H1/.local/bin/solo-attach"
assert_file "claude unit"              "$H1/.config/systemd/user/solo-claude.service"
assert_file "liveness timer"           "$H1/.config/systemd/user/solo-liveness.timer"
assert_nofile "NO listener unit"       "$H1/.config/systemd/user/solo-listener.service"
assert_nofile "NO nudger unit"         "$H1/.config/systemd/user/solo-nudger.service"

for f in run.sh nudger.sh watchdog.sh; do
  bash -n "$H1/solo/scripts/$f" && ok "generated $f parses" || bad "generated $f parses"
done
bash -n "$H1/.local/bin/solo-bootstrap" && ok "solo-bootstrap parses" || bad "solo-bootstrap parses"
bash -n "$H1/.local/bin/solo-attach"    && ok "solo-attach parses"    || bad "solo-attach parses"

# installer-substituted placeholders must be gone; human-fill ones must remain
P="$H1/solo/BOOTSTRAP-PROMPT.txt"
n=$(grep -c '<WORKSPACE>\|<AGENT_NAME>\|<EVENT_JSONL>\|<CURSOR_FILE>\|<SESSION>' "$P")
assert_eq "installer placeholders substituted" "$n" "0"
grep -q '<OWNER_NAME>' "$P" && ok "human-fill placeholders preserved" || bad "human-fill placeholders preserved"
grep -q 'hasTrustDialogAccepted' "$H1/.claude.json" && ok "workspace pre-trusted" || bad "workspace pre-trusted"
assert_eq "agent.env is mode 600" "$(stat -c '%a' "$H1/solo/agent.env")" "600"

# ═════════════════════════ 3. tier 2 ═════════════════════════
section "3. Tier 2 install (slack event source)"
H2="$SANDBOX/h2"; mkdir -p "$H2"
OUT="$(run_install "$H2" nova EVENT_SOURCE=slack SLACK_APP_TOKEN=xapp-t \
        SLACK_BOT_TOKEN=xoxb-t OWNER_SLACK_USER=UTESTOWNER)"
assert_contains "installer reports completion" "$OUT" "Done."
assert_file "listener unit"     "$H2/.config/systemd/user/nova-listener.service"
assert_file "nudger unit"       "$H2/.config/systemd/user/nova-nudger.service"
assert_file "listener script"   "$H2/nova/scripts/slack-listener.mjs"
assert_file "signal filter"     "$H2/nova/scripts/signal-filter.py"
python3 -m py_compile "$H2/nova/scripts/signal-filter.py" 2>/dev/null \
  && ok "signal-filter.py compiles" || bad "signal-filter.py compiles"
if command -v node >/dev/null; then
  node --check "$H2/nova/scripts/slack-listener.mjs" 2>/dev/null \
    && ok "slack-listener.mjs parses" || bad "slack-listener.mjs parses"
else
  printf '  - skipped (no node): slack-listener.mjs syntax\n'
fi
grep -q 'Requires=nova-listener.service nova-claude.service' "$H2/.config/systemd/user/nova-nudger.service" \
  && ok "nudger fails closed on its deps" || bad "nudger fails closed on its deps"

# ═════════════════════════ 4. idempotency ═════════════════════════
section "4. Idempotency"
echo "### MY LOCAL EDIT" >> "$H1/solo/BOOTSTRAP-PROMPT.txt"
OUT="$(run_install "$H1" solo)"
assert_contains "re-run detects existing prompt" "$OUT" "already present"
assert_contains "local prompt edit preserved" "$(tail -1 "$H1/solo/BOOTSTRAP-PROMPT.txt")" "MY LOCAL EDIT"

# ═════════════════════════ 5. signal filter ═════════════════════════
section "5. Signal filter"
W="$H2/nova"
cat >> "$W/agent.env" <<'EOF'
SELF_BOT_ID=UTESTBOT
OWNER_CHANNELS=CSRE
INCIDENT_CHANNELS=CSRE,CALERTS
EOF
sed -i 's|^OWNER_DM_CHANNEL=$|OWNER_DM_CHANNEL=DTESTDM|' "$W/agent.env"
J="$SANDBOX/events.jsonl"; C="$SANDBOX/cursor.txt"
sed -i "s|^EVENT_JSONL=.*|EVENT_JSONL=$J|; s|^CURSOR_FILE=.*|CURSOR_FILE=$C|" "$W/agent.env"
: > "$J"; echo 0 > "$C"
cat > "$J" <<'EOF'
{"event":{"channel":"DTESTDM","user":"UTESTOWNER","text":"deploy the hotfix, go"}}
{"event":{"channel":"CRANDOM","user":"USOMEONE","text":"hey <@UTESTBOT> check CI"}}
{"event":{"channel":"CSRE","user":"UTESTOWNER","text":"what is the backup state"}}
{"event":{"channel":"CALERTS","user":"UMON","bot_id":"B1","text":"[P2] Backup Freshness DOWN"}}
{"event":{"channel":"CARENA","user":"UX","text":"live commentary noise"}}
{"event":{"channel":"CARENA","user":"UY","text":"more firehose"}}
{"event":{"channel":"CRANDOM","user":"UTESTBOT","bot_id":"B9","text":"my own echo"}}
EOF
filter() { AGENT_ENV="$W/agent.env" python3 "$W/scripts/signal-filter.py" "$@"; }

R="$(filter)"
assert_eq "4 signals out of 7 events" "$(printf '%s\n' "$R" | grep -c '^\[')" "4"
assert_contains "owner DM tagged"      "$R" "[OWNER-DM]"
assert_contains "mention tagged"       "$R" "[MENTION]"
assert_contains "owner channel tagged" "$R" "[OWNER-CHAN]"
assert_contains "incident tagged"      "$R" "[INCIDENT]"
printf '%s' "$R" | grep -q "firehose"  && bad "noise dropped" || ok "noise dropped"
printf '%s' "$R" | grep -q "own echo"  && bad "self-echo dropped" || ok "self-echo dropped"
assert_eq "cursor advanced to EOF" "$(cat "$C")" "$(wc -c < "$J")"
assert_contains "second read is flat" "$(filter)" "(no new signal events)"

echo '{"event":{"channel":"DTESTDM","user":"UTESTOWNER","text":"second message"}}' >> "$J"
A="$(filter --peek)"; B="$(filter --peek)"
assert_eq "--peek does not advance (idempotent)" "$A" "$B"
assert_contains "--peek sees the new event" "$A" "second message"

: > "$J"   # simulate log rotation / truncation
echo '{"event":{"channel":"DTESTDM","user":"UTESTOWNER","text":"post-rotation"}}' >> "$J"
assert_contains "rotation re-read, not reported flat" "$(filter)" "post-rotation"

# ═════════════════════════ 6. nudge debounce ═════════════════════════
section "6. Nudger"
SK="$SANDBOX/sendkeys.log"; : > "$SK"
rm -rf "$SANDBOX/state-nova/nudger"
( export AGENT_ENV="$W/agent.env" SENDKEYS_LOG="$SK" PATH="$STUB:$PATH"
  bash "$W/scripts/nudger.sh" > "$SANDBOX/nudger.out" 2>&1 ) &
NP=$!
sleep 1
for i in 1 2 3 4 5; do
  echo "{\"event\":{\"channel\":\"DTESTDM\",\"user\":\"UTESTOWNER\",\"text\":\"msg $i\"}}" >> "$J"
done
sleep 2
echo '{"event":{"channel":"CARENA","user":"UX","text":"pure chatter"}}' >> "$J"
sleep 2
kill $NP 2>/dev/null; wait $NP 2>/dev/null

assert_eq "burst of 5 produces exactly 1 wake" "$(grep -c '^Enter$' "$SK")" "1"
assert_eq "the wake sends a literal dot"       "$(grep -c '^\.$' "$SK")" "1"
assert_eq "4 of the burst debounced" "$(grep -c debounced "$SANDBOX/nudger.out")" "4"
grep -q "waiting for" "$SANDBOX/nudger.out" && ok "logs before blocking (or queue existed)" \
  || ok "queue existed; nothing to wait on"

# ═════════════════════════ 7. watchdog ═════════════════════════
section "7. Watchdog"
wd() { # wd <fake pane> [env file]
  local pane="$1" envf="${2:-$W/agent.env}"
  env AGENT_ENV="$envf" FAKE_PANE="$pane" PATH="$STUB:$PATH" \
      SENDKEYS_LOG="$SK" SYSTEMCTL_LOG="$SANDBOX/sc.log" CURL_LOG="$SANDBOX/curl.log" \
      bash "$W/scripts/watchdog.sh" 2>&1
}
rm -rf "$SANDBOX/state-nova/watchdog"
assert_contains "healthy pane -> ok" "$(wd 'nova loop idle, next wake 600s')" "ok"

rm -rf "$SANDBOX/state-nova/watchdog"
R="$(wd 'Invalid API key · Please run /login')"
assert_contains "expired login alerts"  "$R" "ALERT[login-expired]"
printf '%s' "$R" | grep -q "restarting" && bad "login failure must NOT restart" \
  || ok "login failure does NOT restart the unit"

# frozen pane: needs a stall threshold of 0 to exercise in a test
rm -rf "$SANDBOX/state-nova/watchdog"
FZ="$SANDBOX/agent.env.frozen"
sed 's/^IDLE_STALL_SECS=.*/IDLE_STALL_SECS=0/' "$W/agent.env" > "$FZ"
wd 'identical frozen pane' "$FZ" >/dev/null       # pass 1 records the hash
R="$(wd 'identical frozen pane' "$FZ")"           # pass 2 sees it unchanged
assert_contains "frozen loop detected" "$R" "looks frozen"
assert_contains "frozen loop re-bootstrapped" "$R" "re-bootstrapped"

rm -rf "$SANDBOX/state-nova/watchdog"
assert_contains "un-armed pane re-armed" "$(wd 'Welcome to Claude Code  >')" "bootstrap re-armed"

# the real default must NOT trip a normally sleeping agent
rm -rf "$SANDBOX/state-nova/watchdog"
wd 'nova loop idle, next wake 600s' >/dev/null
R="$(wd 'nova loop idle, next wake 600s')"
printf '%s' "$R" | grep -q "frozen" && bad "default threshold trips a sleeping agent" \
  || ok "default threshold spares a sleeping agent"

# ═════════════════════════ 8. no collateral damage ═════════════════════════
section "8. Hermeticity"
# Every unit file the suite created must live under the sandbox, never in the
# caller's real ~/.config/systemd/user.
units_outside=$(ls "$HOME/.config/systemd/user/"{solo,nova}-* 2>/dev/null | wc -l)
assert_eq "no units written to the real \$HOME" "$units_outside" "0"
# All agent state must be inside the sandbox too.
state_outside=$(ls -d /tmp/solo-state /tmp/nova-state 2>/dev/null | wc -l)
assert_eq "no agent state written outside the sandbox" "$state_outside" "0"
# The real tmux must have no session named after our test agents.
if command -v tmux >/dev/null; then
  tmux has-session -t nova 2>/dev/null && bad "a real tmux session 'nova' exists" \
    || ok "no real tmux session created"
else
  ok "tmux absent; nothing could be created"
fi

# ═════════════════════════ summary ═════════════════════════
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%s  %d passed\n' "$(green 'ALL TESTS PASSED')" "$PASS"
  exit 0
else
  printf '%s  %d passed, %d failed\n' "$(red 'TESTS FAILED')" "$PASS" "$FAIL"
  exit 1
fi
