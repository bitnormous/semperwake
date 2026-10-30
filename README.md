# standing-agent

[![test](https://github.com/ovac/standing-agent/actions/workflows/test.yml/badge.svg)](https://github.com/ovac/standing-agent/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Turn Claude Code into an always-on autonomous agent that survives crashes, reboots, and your SSH session closing.**

No orchestration framework. No gateway. No second runtime. The only agent process is `claude` itself,
running in a detached tmux session that systemd supervises — plus about 400 lines of shell that make it
*reliable* instead of merely *running*.

```
claude  +  systemd  +  tmux  +  one very good prompt  =  an agent that works while you sleep
```

Extracted from a production SRE agent that has run continuously for months, handling real incidents.
Every design decision in here exists because its absence caused a specific, documented failure.

---

## Quickstart

```bash
git clone https://github.com/ovac/standing-agent.git
cd standing-agent

# 0. PREREQUISITE — the one step a human must do. There is no headless path for it.
claude                                  # then: /login, finish the browser flow, /exit

# 1. Install. Deps: tmux, systemd (user units), python3.
AGENT=nova ./install.sh

# 2. Fill in the brain, then arm it.
$EDITOR ~/nova/BOOTSTRAP-PROMPT.txt     # replace every <PLACEHOLDER>
nova-bootstrap
```

That's a self-healing agent that paces itself with `ScheduleWakeup`.

Want it to react the instant someone messages it? Add an event source:

```bash
AGENT=nova EVENT_SOURCE=slack \
  SLACK_APP_TOKEN=xapp-...  SLACK_BOT_TOKEN=xoxb-...  OWNER_SLACK_USER=U0123ABC \
  ./install.sh
```

Then set `SELF_BOT_ID`, `OWNER_CHANNELS` and `INCIDENT_CHANNELS` in `~/nova/agent.env` and
`systemctl --user restart nova-nudger`.

### Daily driving

```bash
nova-attach status     # what's up
nova-attach            # watch it think, live (detach: Ctrl-B then d)
nova-attach logs       # follow the journal
nova-bootstrap         # re-arm the loop by hand
```

---

## How it works

Five parts. Each is independently replaceable.

| | Unit | Job |
|---|---|---|
| **1** | `<agent>-claude.service` | Keeps a detached tmux session alive running `claude --dangerously-skip-permissions`, and **pastes the `/loop` prompt into it ~25s after launch** — so a crash or reboot self-resumes with no human action. |
| **2** | `BOOTSTRAP-PROMPT.txt` | **The actual product.** Identity, event-queue contract, safety gates, loop pacing, measurement discipline. Everything else is plumbing for this file. |
| **3** | `<agent>-nudger.service` | Tails the event queue; sends a literal `.` + Enter into the pane when an actionable line lands. **This is what makes the agent real-time instead of a poller.** |
| **4** | `<agent>-liveness.timer` | Every 2 min: unit up? session alive? pane moving? loop armed? login valid? Self-heals, or alerts loudly and specifically. |
| **5** | `<agent>-listener.service` | *Optional* event producer (Slack Socket Mode → JSONL). Swap in anything that appends JSON lines. |

```
  Slack / GitHub / cron / any producer
          │  appends JSON lines
          ▼
  /tmp/<agent>-events.jsonl ───────────────┐
          │                                │ tail -F
          │ signal-filter.py               ▼
          │ (firehose → tagged signal)  nudger ── "." + Enter ──┐
          │                                                      │
          ▼                                                      ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  tmux session "<agent>"  →  claude  ←── /loop BOOTSTRAP-PROMPT  │
   └─────────────────────────────────────────────────────────────────┘
          ▲                                       ▲
          │ Restart=always                        │ every 2 min: heal or alert
   <agent>-claude.service                  <agent>-liveness.timer
```

The `.` is a **wake signal, not a message.** The prompt tells the agent that any bare `.` means
*drain your queue and take a turn*. That one trick is the difference between an agent that costs you
a token budget polling every 60 seconds and one that sleeps for free until something actually happens.

Full rationale: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**

---

## Safety — read this part

`--dangerously-skip-permissions` is not optional here: no human is present to approve tool-call
prompts. So **safety is enforced inside the prompt instead**, and the prompt's safety section is the
*only* control on an agent with full tool access.

Every write action requires all three, every time:

1. the request **originates from the owner** (verified identity, not a quoted or relayed claim);
2. the owner used an **explicit confirmation word** — "go", "do it", "ship", "merge it", "deploy";
3. the agent **restates the exact action** before executing it.

Authorisation is per-batch and does not extend to the next batch. Building a PR is not merging a PR.

> If you trim that section to make the agent feel snappier, you have an unsupervised process with
> full shell access on your box. Run it as a **dedicated unix user** with only the access it needs.

---

## The failure modes

This is the part worth reading even if you never run the code. Every item cost real downtime, and
each one is in the repo as code rather than as advice.

**A restarted session with no prompt is a bare `claude` that idles forever** — and every instrument
reports it healthy. `systemctl status` says active. `tmux has-session` says yes. The process list looks
perfect. It just sits there. Hence the auto-paste, and a watchdog that checks whether the loop is
*armed* rather than whether the process exists.

**`loginctl enable-linger` is mandatory.** Without it every user unit dies the moment you log out of
SSH — the classic "it worked until I closed my laptop".

**Nudge debounce is load-bearing.** Claude queues keystrokes, so 5 events in 5 seconds becomes 5
queued turns and the agent burns its budget re-waking instead of working. One burst must produce
exactly one wake.

**`tmux send-keys "." Enter` as a single call races Claude's input buffering** — the `.` gets
swallowed and you're left with a bare Enter that does nothing. Two calls, 100ms apart, always.

**A process blocked on a file that never appears is indistinguishable from a healthy one.** The
nudger logs *before* it blocks for exactly this reason. A production agent silently lost its entire
wake path for about six weeks this way: the "waiting" state produced no output at all, so every check
read as green.

**Reading the raw event queue makes an agent conclude "all quiet" and miss the one message that
mattered.** A busy queue is mostly firehose. `signal-filter.py` is the only sanctioned read path — it
tags, drops the agent's own echoes, advances a cursor, and treats a truncated file as rotation rather
than as an empty queue.

**The frozen-pane threshold must exceed the agent's longest idle wake interval**, or your watchdog
cheerfully restarts a perfectly healthy sleeping agent every few minutes.

**An expired login is a human-only fix.** The watchdog alerts instead of restarting — restarting
cannot fix credentials, and thrashing the unit buries the one message that explains the silence.

More, including the measurement errors that make an agent *confidently wrong* about its own
infrastructure: **[docs/FAILURE-MODES.md](docs/FAILURE-MODES.md)**

---

## Layout

```
install.sh                     idempotent installer; generates everything below
prompts/BOOTSTRAP-PROMPT.txt   the agent's brain (template — you must edit it)
docs/ARCHITECTURE.md           the five parts, the data flow, why each exists
docs/FAILURE-MODES.md          the full catalogue of what goes wrong
docs/PROMPT-GUIDE.md           how to write a bootstrap prompt that holds up
test/run-tests.sh              hermetic test suite — stubs every binary, touches nothing real
```

Installs to:

```
~/<agent>/agent.env               single source of truth; every script and unit sources it
~/<agent>/BOOTSTRAP-PROMPT.txt    the live prompt
~/<agent>/MEMORY.md               durable facts, laws, owner mandates
~/<agent>/INSTINCTS.md            IF→THEN reflexes
~/<agent>/HEARTBEAT.md            what to check every wake
~/<agent>/memory/YYYY-MM-DD.md    daily ledger — continuity across restarts
~/<agent>/scripts/*               run, nudger, watchdog, listener, signal-filter
~/.local/bin/<agent>-{bootstrap,attach}
~/.config/systemd/user/<agent>-*.{service,timer}
```

---

## Tests

```bash
./test/run-tests.sh
```

Hermetic: stubs `tmux`, `systemctl`, `loginctl`, `claude`, `jq` and `curl`, runs the installer into a
throwaway `HOME`, and asserts real behaviour — both install tiers, syntax of every generated artifact,
signal-filter tagging and cursor semantics, nudge debounce under burst, and all four watchdog paths.
It never touches your systemd, your network, or your real agent.

---

## Two things people skip, and then wonder why it's useless

1. **Replace every `<PLACEHOLDER>` in `BOOTSTRAP-PROMPT.txt`.** Unfilled, the agent has no identity,
   no reporting channel, and no idea who may authorise a write.
2. **Write `MEMORY.md` and `INSTINCTS.md`.** An agent with no memory re-derives its own rules on every
   restart and gets them wrong differently each time. Memory is what makes it the *same* agent
   tomorrow.

## Requirements

- [Claude Code](https://claude.com/claude-code), logged in
- Linux with systemd user units (`loginctl enable-linger` available)
- `tmux`, `python3`
- `node` ≥ 18 and `jq` — only for the optional Slack event source

Not supported on macOS as-is: it depends on systemd user units. The tmux + prompt + nudge core is
portable; `launchd` equivalents are welcome as a PR.

## Teardown

```bash
systemctl --user disable --now nova-claude nova-nudger nova-listener nova-liveness.timer
rm ~/.config/systemd/user/nova-*
systemctl --user daemon-reload
tmux kill-session -t nova
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The most valuable PR you can send is **a new entry in
`docs/FAILURE-MODES.md`** — a way an always-on agent silently died on you, and the mechanical check
that would have caught it.

## License

MIT — see [LICENSE](LICENSE).
