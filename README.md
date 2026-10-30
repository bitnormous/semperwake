# semperwake

[![test](https://github.com/bitnormous/semperwake/actions/workflows/test.yml/badge.svg)](https://github.com/bitnormous/semperwake/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Always awake.** Turn Claude Code into an autonomous agent that survives crashes, reboots, and your
SSH session closing — and that wakes the instant someone messages it.

No orchestration framework. No gateway. No second agent runtime. Claude Code runs in a detached tmux
session that systemd supervises; the installer adds the small pieces that make it *reliable* rather
than merely *running*.

```
claude  +  systemd  +  tmux  +  one very good prompt  =  an agent that works while you sleep
```

Extracted from a production SRE agent that has run continuously for months, handling real incidents.
Every design decision here exists because its absence caused a specific, documented failure.

---

## Quickstart

```bash
git clone https://github.com/bitnormous/semperwake.git
cd semperwake

# 0. PREREQUISITE — the one step a human must do. There is no headless path for it.
claude                        # then: /login, finish the browser flow, /exit

# 1. Configure.
cp .env.example .env
$EDITOR .env                  # set AGENT, and CHAT_PROVIDER if you want chat

# 2. Install. Tier 1 deps: tmux, systemd (user units), python3.
./install.sh

# 3. Fill in the brain, then arm it.
$EDITOR "$HOME/semp/BOOTSTRAP-PROMPT.txt"  # replace every <PLACEHOLDER>
semp-bootstrap
```

That's a self-healing agent that paces itself with `ScheduleWakeup`. Everything is named after your
`AGENT` value — `semp` above.

### Daily driving

```bash
semp-attach status     # what's up, and which provider
semp-attach            # watch it think, live (detach: Ctrl-B then d)
semp-attach logs       # follow the journal
semp-bootstrap         # re-arm the loop by hand
```

---

## Bring your own chat

Set `CHAT_PROVIDER` in `.env`. The agent's wake path, signal filter and watchdog are all
**provider-agnostic** — they read a normalized envelope, so none of them knows or cares which
platform you use.

| `CHAT_PROVIDER` | Status | How it connects |
|---|---|---|
| `none` | ✅ shipped | No chat integration. Agent self-paces. **Start here.** |
| `slack` | ✅ shipped | Socket Mode — no public URL, no inbound firewall rule |
| `discord` | ✅ shipped | Gateway WebSocket — same, plus auto-resume |
| `teams` | 🚧 wanted | Needs an Azure app registration; [PRs welcome](CONTRIBUTING.md) |
| `matrix` / `telegram` / `irc` | 🚧 wanted | Each is one small listener |

Adding a platform means writing **one listener** that appends normalized JSON lines to the queue.
The filter, nudger and watchdog do not need platform-specific changes. Add notification support to
`notify.sh` too if the agent must send messages through that platform.

```json
{"ts":"2026-10-30T09:11:30Z","provider":"discord","kind":"message",
 "channel":"1234","channel_type":"dm","user":"5678","text":"deploy the hotfix, go",
 "thread":"","is_bot":false,"mentions_self":false,"raw":{}}
```

Full contract: **[docs/ARCHITECTURE.md § The producer contract](docs/ARCHITECTURE.md)**. Producers
aren't limited to chat either — cron jobs, GitHub webhooks and log tailers all append to the same
queue with `"kind":"job"` or `"kind":"signal"`.

---

## How it works

Five parts. Each is independently replaceable.

| | Unit | Job |
|---|---|---|
| **1** | `<agent>-claude.service` | Keeps a detached tmux session alive running `claude --dangerously-skip-permissions`, and **pastes the `/loop` prompt into it ~25s after launch** — so a crash or reboot self-resumes with no human action. |
| **2** | `BOOTSTRAP-PROMPT.txt` | **The actual product.** Identity, event contract, safety gates, loop pacing, measurement discipline. Everything else is plumbing for this file. |
| **3** | `<agent>-nudger.service` | Tails the queue; sends a literal `.` + Enter into the pane when an actionable line lands. **This is what makes the agent real-time instead of a poller.** |
| **4** | `<agent>-liveness.timer` | Every 2 min: unit up? session alive? pane moving? loop armed? login valid? Self-heals, or alerts loudly and specifically. |
| **5** | `<agent>-listener.service` | *Optional* chat producer. Swap freely; see the table above. |

```
  slack / discord / cron / webhooks / your own producer
          │  append normalized JSON lines
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
*drain your queue and take a turn*. This avoids a fixed-interval polling loop and lets events wake the
agent promptly.

Full rationale: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**

---

## Safety — read this part

`--dangerously-skip-permissions` is used because no human is present to approve tool-call prompts.
The prompt supplies behavioural policy; it is not a security boundary. Run the agent as a dedicated,
least-privileged Unix user and give its integrations scoped credentials.

Every write action requires all three, every time:

1. the request **originates from the owner** (`OWNER_ID` — verified identity, not a relayed claim);
2. the owner used an **explicit confirmation word** — "go", "do it", "ship", "merge it", "deploy";
3. the agent **restates the exact action** before executing it.

Authorisation is per-batch and does not extend to the next batch. Building a PR is not merging a PR.

> If you trim that section to make the agent feel snappier, you have an unsupervised process with
> full shell access on your box. Run it as a **dedicated unix user** with only the access it needs —
> the prompt is policy, the unix user is enforcement.

---

## The failure modes

This is the part worth reading even if you never run the code. Every item cost real downtime, and
each one ships as code rather than as advice.

**A restarted session with no prompt is a bare `claude` that idles forever** — and every instrument
reports it healthy. `systemctl status` says active. `tmux has-session` says yes. The process list
looks perfect. It just sits there. Hence the auto-paste, and a watchdog that checks whether the loop
is *armed* rather than whether the process exists.

**`loginctl enable-linger` is mandatory.** Without it every user unit dies the moment you log out of
SSH — the classic "it worked until I closed my laptop".

**Nudge debounce is load-bearing.** Claude queues keystrokes, so 5 events in 5 seconds becomes 5
queued turns and the agent burns its budget re-waking instead of working. One burst must produce
exactly one wake.

**`tmux send-keys "." Enter` as a single call races Claude's input buffering** — the `.` gets
swallowed and you're left with a bare Enter that does nothing at all.

**A process blocked on a file that never appears is indistinguishable from a healthy one.** The
nudger logs *before* it blocks for exactly this reason. A production agent silently lost its entire
wake path for about six weeks this way: the "waiting" state produced no output, so every check read
green.

**Reading the raw queue makes an agent conclude "all quiet" and miss the one message that mattered.**
A busy queue is mostly firehose. `signal-filter.py` is the only sanctioned read path — it tags, drops
the agent's own echoes, advances a cursor, and treats a truncated file as rotation rather than as an
empty queue.

**The frozen-pane threshold must exceed the agent's longest idle wake interval**, or your watchdog
cheerfully restarts a perfectly healthy sleeping agent every few minutes.

**An expired login is a human-only fix.** The watchdog alerts instead of restarting — restarting
cannot fix credentials, and thrashing the unit buries the one message that explains the silence.

More, including the measurement errors that make an agent *confidently wrong* about its own
infrastructure: **[docs/FAILURE-MODES.md](docs/FAILURE-MODES.md)**

---

## Layout

```
.env.example                   every knob, documented — copy to .env
install.sh                     idempotent installer; generates everything below
prompts/BOOTSTRAP-PROMPT.txt   the agent's brain (template — you must edit it)
docs/ARCHITECTURE.md           the five parts, the producer contract, why each exists
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
~/<agent>/scripts/run.sh          tmux + claude + auto-bootstrap
~/<agent>/scripts/nudger.sh       debounced wake on actionable events
~/<agent>/scripts/watchdog.sh     five liveness checks, every 2 min
~/<agent>/scripts/notify.sh       provider-agnostic "send a message"
~/<agent>/scripts/signal-filter.py   firehose → tagged signal
~/<agent>/scripts/<provider>-listener.mjs  optional; installed only for Slack or Discord
~/.local/bin/<agent>-{bootstrap,attach}
~/.config/systemd/user/<agent>-*.{service,timer}
```

---

## Tests

```bash
./test/run-tests.sh
```

90 assertions, hermetic. Stubs `tmux`, `systemctl`, `loginctl`, `claude` and `curl`, runs the
installer into a throwaway `HOME`, and asserts real behaviour: the no-chat, Slack and Discord tiers, `.env`
loading and precedence, signal-filter tagging across mixed providers, cursor semantics under
rotation, nudge debounce under burst, notify routing per provider, and all five watchdog paths
including alert dedupe. It never touches your systemd, your network, or your real agent — section 10
asserts that.

---

## Two things people skip, and then wonder why it's useless

1. **Replace every `<PLACEHOLDER>` in `BOOTSTRAP-PROMPT.txt`.** Unfilled, the agent has no identity,
   no reporting rules, and no idea who may authorise a write.
2. **Write `MEMORY.md` and `INSTINCTS.md`.** An agent with no memory re-derives its own rules on
   every restart and gets them wrong differently each time. Memory is what makes it the *same* agent
   tomorrow.

## Requirements

- [Claude Code](https://claude.com/claude-code), logged in
- Linux with systemd user units (`loginctl enable-linger` available)
- `tmux`, `python3`
- `node` ≥ 18 — only for the Slack/Discord listeners

Not supported on macOS as-is: it depends on systemd user units. The tmux + prompt + nudge core is
portable; `launchd` equivalents are welcome as a PR.

## Teardown

```bash
systemctl --user disable --now semp-claude semp-nudger semp-listener semp-liveness.timer
rm -f ~/.config/systemd/user/semp-*.service ~/.config/systemd/user/semp-*.timer
rm -f ~/.local/bin/semp-bootstrap ~/.local/bin/semp-attach
systemctl --user daemon-reload
tmux kill-session -t semp 2>/dev/null || true
```

This stops the agent but deliberately keeps `$HOME/semp`, its memory, prompt and state. Remove that
directory, its event/cursor files, and its state directory only after you have backed up anything you
need. Substitute your configured `AGENT` value for `semp` throughout.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The two most valuable PRs: **a new entry in
[docs/FAILURE-MODES.md](docs/FAILURE-MODES.md)** — a way an always-on agent silently died on you,
plus the mechanical check that would have caught it — or **a new chat provider**, which is one
listener and a row in the table above.

## License

MIT — see [LICENSE](LICENSE).
