# Architecture

Why each piece exists, and what breaks without it.

The design constraint that shapes everything: **Claude Code is an interactive REPL, not a daemon.**
It expects a terminal, a human, and a conversation. Everything here is about making that into a
supervised service without wrapping it in a framework that then becomes its own thing to maintain
and debug.

---

## 1. The supervised session

```
systemd (Restart=always)
  └── run.sh                     blocks until the session dies
        └── tmux session         detached, 220x60
              └── claude --dangerously-skip-permissions
```

**Why tmux at all?** Claude Code needs a TTY. More usefully, tmux gives you three things no
`nohup`/`&` approach does:

- `tmux attach` — a human can drop into a live agent mid-thought and type at it
- `tmux capture-pane` — the watchdog can *read what the agent is doing* and judge it
- `tmux send-keys` — anything on the box can wake the agent with a keystroke

That last one is the whole event model. It's a strange interface for an API-era system, and it's
remarkably robust: there is no socket to go stale, no port to collide, no queue to drain.

**Why does `run.sh` block instead of exiting?** So systemd supervises the real thing. If the runner
forked tmux and exited, systemd would mark the unit "done" and never notice `claude` dying. The
runner polls `tmux has-session` every 30s and exits when the session is gone, at which point
`Restart=always` brings the whole thing back.

```bash
while tmux has-session -t "$SESSION" 2>/dev/null; do sleep 30; done
```

30s is coarse enough not to burn CPU, tight enough that systemd notices within one restart cycle.

**Why `--dangerously-skip-permissions`?** There is no human to approve tool-call prompts. Without
it the agent stops at the first `Bash` call and waits forever, looking alive. See
[Safety](#safety-lives-in-the-prompt).

### The auto-paste

`run.sh` backgrounds a subshell that waits 25 seconds, then pastes the bootstrap prompt into the
session:

```bash
tmux load-buffer  -t "$SESSION" -b boot "$BOOTSTRAP_FILE"
tmux paste-buffer -t "$SESSION" -b boot
sleep 1
tmux send-keys    -t "$SESSION" Enter
```

**Why 25 seconds and not zero?** Claude Code renders a splash, checks for updates, and loads project
context. Paste into that window and your prompt lands in a half-initialised input buffer, mangled or
dropped. 25s is empirical headroom.

**Why `load-buffer` + `paste-buffer` rather than `send-keys "$PROMPT"`?** The prompt is multi-line.
`send-keys` would submit it line by line — forty separate turns, each one a fragment. A tmux buffer
paste arrives as one bracketed-paste block and stays a single input.

**Why paste at all, instead of `claude -p "$PROMPT"`?** Because `-p` is one-shot: it answers and
exits. This needs a persistent REPL that keeps its context across wakes. The paste is how you hand a
starting instruction to a session that then lives on its own.

**Why skip it when a human is attached?** Pasting into someone's half-typed command is rude and
destructive:

```bash
if [ -n "$(tmux list-clients -t "$SESSION" 2>/dev/null)" ]; then
    log "human attached — skipping auto-bootstrap"
```

---

## 2. The prompt is the product

Everything else is plumbing. `prompts/BOOTSTRAP-PROMPT.txt` is the agent.

It opens with `/loop`, which puts Claude Code into a self-pacing mode where it schedules its own next
wake via `ScheduleWakeup` instead of ending the turn and idling.

Its sections, in the order they matter:

| Section | Why it's there |
|---|---|
| **Canonical files** | What to read on every cold start to be the same agent it was yesterday |
| **Event source** | The queue path, the cursor protocol, and an explicit ban on reading the queue raw |
| **How you report** | The installed `notify.sh` command and explicit routing rules — so it never improvises an escalation path mid-incident |
| **Safety posture** | Read freely; three conditions for any write |
| **Loop pacing** | What `.` means, how long to sleep, the per-iteration time cap |
| **Measurement discipline** | The errors that make an agent *confidently wrong* |
| **Cost discipline** | Terseness, and a hard stop after 3 consecutive failures |
| **Attached human** | Typed terminal input is authoritative; no confirmation gate |

See [PROMPT-GUIDE.md](PROMPT-GUIDE.md) for how to fill it in without defeating the point.

---

## 3. The nudger — why the agent is real-time

Without it, an autonomous agent has exactly one option: poll. Wake every 60s, check the queue, go
back to sleep. That's a token bill for sleeping, and still up to 60s of latency.

The nudger closes that: it tails the event queue and, when an actionable line lands, types a single
`.` into the pane. The prompt defines `.` as *drain your queue and take a turn*. Latency drops to
roughly the time tmux takes to deliver a keystroke, and an idle agent costs nothing.

Three details are load-bearing:

**Debounce.** Claude queues keystrokes. Five events in five seconds becomes five queued turns, and
the agent spends its budget re-waking instead of working. One burst must produce exactly one wake:

```bash
if [ "$((now - last))" -lt "$NUDGE_COOLDOWN_SECONDS" ]; then
    log "debounced"; return
fi
```

**Two send-keys calls, not one.** `send-keys "." Enter` races Claude's input buffering; the `.` gets
swallowed and a bare Enter does nothing at all — a wake that silently isn't one.

```bash
tmux send-keys -t "$SESSION" "."
sleep 0.1
tmux send-keys -t "$SESSION" Enter
```

**Log before you block.** The nudger waits for its queue file to exist. A process blocked on a file
that never appears is indistinguishable from a healthy one, so it announces the wait *first*:

```bash
while [ ! -f "$EVENT_JSONL" ]; do
    log "waiting for $EVENT_JSONL to appear"
    sleep 5
done
```

A production agent lost its wake path for about six weeks to exactly this: the blocking happened
before the first log line, so "silently broken" and "quietly healthy" produced identical output.

---

## 4. The watchdog — five ways an agent dies quietly

Runs every 2 minutes. Checks are ordered by *how silently* each failure kills the agent.

| Check | Symptom | Response |
|---|---|---|
| Unit inactive | nothing running | `systemctl start` |
| tmux session missing while unit active | runner alive, session gone | restart (cooldown-guarded) |
| Login/credential error in pane | agent can't think | **alert a human — do not restart** |
| Pane byte-identical too long | loop frozen | re-paste prompt, else restart |
| Pane has no loop markers | bare `claude`, no prompt | re-paste prompt |

**The fourth check is why the watchdog reads the pane at all.** A frozen loop has a live process, a
live session, and an active unit. The only external evidence is that the pane stops changing:

```bash
HASH="$(printf '%s' "$PANE" | md5sum | cut -d' ' -f1)"
```

The threshold (`IDLE_STALL_SECS`, default 2400) **must exceed the agent's longest idle wake interval**
(600s in the shipped prompt). Get this backwards and the watchdog restarts a perfectly healthy
sleeping agent every few minutes — a self-inflicted outage that looks exactly like instability.

**Why does an expired login alert instead of restarting?** Restarting cannot fix credentials. It
produces a restart loop that buries the one message explaining the silence. Some failures are
human-only, and a watchdog that can't tell the difference makes them worse.

**Restart guard.** At most one self-heal per hour:

```bash
if [ -f "$f" ] && [ "$((now - $(cat "$f")))" -lt 3600 ]; then
    log "restart suppressed (cooldown)"; return 1
fi
```

Without it, a crash-on-boot bug becomes an infinite restart loop. Worth knowing: with
`Restart=always`, a service that crash-loops **never reaches `failed`** — `systemctl status` keeps
printing `active (running)` with a fresh pid. The uptime column is the tell, not the state word.

**Alert dedupe.** Keyed per alert type with a 30-minute window, so a persistent fault pages once,
not fifteen times an hour until you mute the channel. An alert you've learned to ignore is worth
less than no alert.

---

## 5. The producer contract

**One line of normalized JSON, appended to a file.** That is the entire interface between the
outside world and the agent.

```json
{
  "ts": "2026-10-30T09:11:30Z",
  "provider": "discord",
  "kind": "message",
  "channel": "1234567890",
  "channel_type": "dm",
  "user": "9876543210",
  "text": "deploy the hotfix, go",
  "thread": "",
  "is_bot": false,
  "mentions_self": false,
  "raw": { }
}
```

| field | meaning |
|---|---|
| `provider` | free-form label; useful in logs, never branched on downstream |
| `kind` | `message`, or `job` / `signal` for non-chat producers |
| `channel_type` | **`dm`** or **`channel`** — normalize your platform's vocabulary into these two |
| `user` | the author's platform id; compared against `OWNER_ID` and `SELF_BOT_ID` |
| `thread` | an opaque reference to the inbound message or thread; retained for consumers that support replies |
| `is_bot` | kept in `INCIDENT_CHANNELS`, dropped everywhere else |
| `mentions_self` | computed by the listener, which is the only component that knows the platform's mention syntax |
| `raw` | the original payload, for when the agent genuinely needs it |

**Why normalize in the listener rather than in the filter?** Because mention syntax, DM detection and
bot flags are the *only* genuinely platform-specific knowledge in the system. Push them into the one
component that already speaks the platform, and the filter, the nudger, the watchdog and the prompt
stay provider-agnostic forever. Adding Teams should not require touching four files.

Producers need not be chat at all. A cron job emitting
`{"kind":"job","job":"nightly-backup","prompt_file":"...","prompt_anchor":"..."}` gets tagged `[JOB]`
and tells the agent to go execute a documented procedure.

### Slack listener (Socket Mode)

No public URL or inbound firewall rule is required. Two details matter:

**Ack before processing.** Slack redelivers after ~3s without an ack, so acking after the disk write
gives you duplicate events under load.

```js
if (m.envelope_id) ws.send(JSON.stringify({ envelope_id: m.envelope_id }))
```

**`debug_reconnects=true`.** Slack recycles Socket Mode connections about every 30 minutes. The flag
gets you a reconnect hint *before* the disconnect, closing the gap where events would be dropped.

### Discord listener (Gateway)

More protocol than Slack, and three parts are easy to get wrong:

**The MESSAGE_CONTENT intent is privileged and off by default.** Without it every message arrives
with an empty `content` field — the agent sees traffic it cannot read, which presents as a parsing
bug rather than a permissions one. The listener requests
`GUILDS | GUILD_MESSAGES | DIRECT_MESSAGES | MESSAGE_CONTENT`.

**Heartbeats are mandatory.** Discord sends `op 10 HELLO` with a `heartbeat_interval`; miss the
interval and the socket closes. The listener starts the heartbeat before identifying.

**Resume beats reconnect.** `READY` carries a `session_id` and a `resume_gateway_url`; using them on
reconnect replays missed events instead of dropping them. `op 9 INVALID_SESSION` means the resume
was refused and a fresh identify is required.

It also validates `SELF_BOT_ID` against the id Discord reports at `READY`, and warns on mismatch —
otherwise mention detection and echo-dropping both silently do nothing, and the agent starts
answering itself.

### The signal filter

A busy queue is overwhelmingly noise. An agent that reads it raw concludes "all quiet" and misses the
one message that mattered — so `signal-filter.py` is the only sanctioned read path. It:

- tags each event: `[OWNER-DM]`, `[MENTION]`, `[OWNER-CHAN]`, `[INCIDENT]`, `[JOB]`
- drops the agent's own messages, or it answers itself forever
- keeps bot traffic **only** in `INCIDENT_CHANNELS`, dropping it elsewhere
- advances a byte-offset cursor (`--peek` to inspect without advancing)
- treats `cursor > filesize` as rotation and re-reads from zero, rather than reporting a flat queue

That last one is subtle and important: a truncated or rotated file makes a naive cursor read as
"nothing new". **A metric that drops to exactly zero is a rotation suspect, not good news.**

`[OWNER-CHAN]` deserves specific attention — it is the inbound path people forget exists. A
production agent once ignored its owner's message in a shared ops channel for 55 minutes while
posting into that very channel, because it was only watching the DM.

---

## Safety lives in the prompt

With `--dangerously-skip-permissions`, the prompt defines the behavioural gate: owner-verified
origin, an explicit confirmation word, and a restatement of the action before execution. It is not a
security boundary and authorisation never extends past the batch it was given for.

Structural protections worth adding around it:

- **Run the agent as a dedicated unix user** with only the access it needs. This is the real
  boundary; the prompt is policy, the unix user is enforcement.
- Keep secrets in an env file mode `600`, never in the prompt, never echoed into a transcript.
- Give it a scoped token per integration, not your personal one.
- Grant no production write path you wouldn't grant a new hire on day one.

---

## Why not X?

**Why not the Agent SDK / a headless harness?** Those are often the right answer for request/response
work. This is for an agent that *persists* — one that remembers yesterday, holds a long-running
investigation across wakes, and that you can attach to and talk with. Choose the operating model and
pricing that fit your Claude Code plan; this project makes no pricing guarantee.

**Why not a cron job that calls `claude -p`?** No continuity. Every run starts cold, re-reads
everything, and re-derives conclusions it reached an hour ago. The expensive part of an agent isn't
the tokens, it's the context.

**Why not Docker?** You can, and the tmux core is portable. But the agent's whole job is usually to
operate the host — systemd, logs, deploys, databases. A container is a boundary in the wrong place.

**Why not a web dashboard instead of tmux?** `tmux attach` is already a perfect live view that
needs no code, no port, and no auth layer of its own. `tmux capture-pane` is already an API.
