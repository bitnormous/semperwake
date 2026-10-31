#!/bin/bash
# entrypoint.sh — systemd's job inside a container, and nothing more.
#
# Docker restarts the container; this restarts the pieces inside it. A crashed
# nudger or listener must not take claude down with it, because restarting claude
# throws away the agent's live context. That is why each piece gets its own loop
# rather than letting any exit stop the container.
#
# The scripts it runs are the ones install.sh generates for systemd, unchanged.
# Pass a command to run that instead of the agent: `docker compose run --rm agent claude`
set -euo pipefail

[ "$#" -eq 0 ] || exec "$@"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_POLL_SECS="${PROMPT_POLL_SECS:-10}"
WATCHDOG_BOOT_SECS="${WATCHDOG_BOOT_SECS:-90}"     # OnBootSec of the systemd timer
WATCHDOG_EVERY_SECS="${WATCHDOG_EVERY_SECS:-120}"  # OnUnitActiveSec of the systemd timer

log() { echo "$(date -u +%FT%TZ) [${AGENT:-semp}-entrypoint] $*"; }

stop() { log "stopping"; tmux kill-server 2>/dev/null || true; exit 0; }
trap stop TERM INT

# Re-run on every start so a token rotated in .env reaches agent.env. The installer
# never touches an edited prompt or memory file.
SUPERVISOR=container bash "$SRC/install.sh"
export AGENT_ENV="${WORKSPACE:-$HOME/${AGENT:-semp}}/agent.env"
set -a; source "$AGENT_ENV"; set +a

# An unfilled prompt names no owner and no authorisation rules, so arming it would
# start an agent with skipped permissions and no policy. Waiting here also means the
# agent starts by itself once the file is saved, with no restart needed.
placeholders='<(OWNER_NAME|FILL IN|ONE PARAGRAPH)'
if grep -qE "$placeholders" "$BOOTSTRAP_FILE"; then
    log "waiting: fill in every placeholder in BOOTSTRAP-PROMPT.txt ($WORKSPACE)"
    while grep -qE "$placeholders" "$BOOTSTRAP_FILE"; do
        sleep "$PROMPT_POLL_SECS" & wait $!
    done
    log "prompt filled in; starting"
fi

supervise() { # supervise <restart-delay> <name> <command...> — Restart=always
    local delay="$1" name="$2"; shift 2
    (
        set +e
        while :; do
            "$@"
            log "$name exited ($?); restarting in ${delay}s"
            sleep "$delay"
        done
    ) &
}

supervise 30 claude "$WORKSPACE/scripts/run.sh"
# The nudger runs without a chat provider too: `semperwake job` writes to the same
# queue, and a job should not wait for the next safety-net wake.
supervise 5 nudger "$WORKSPACE/scripts/nudger.sh"
if [ "$CHAT_PROVIDER" != none ]; then
    supervise 5 listener node "$WORKSPACE/scripts/$CHAT_PROVIDER-listener.mjs"
fi

(
    set +e
    sleep "$WATCHDOG_BOOT_SECS"
    while :; do
        "$WORKSPACE/scripts/watchdog.sh"
        sleep "$WATCHDOG_EVERY_SECS"
    done
) &

log "agent supervised (provider: $CHAT_PROVIDER)"
wait
