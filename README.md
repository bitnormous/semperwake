# semperwake

[![test](https://github.com/bitnormous/semperwake/actions/workflows/test.yml/badge.svg)](https://github.com/bitnormous/semperwake/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Always awake.** Turn Claude Code into an autonomous agent that survives crashes, reboots and your
SSH session closing, and that wakes the instant someone messages it.

No orchestration framework. No gateway. No second agent runtime. Claude Code runs in a detached tmux
session under Docker or systemd, and semperwake adds the small pieces that make it *reliable* rather
than merely *running*.

```
claude  +  a supervisor  +  tmux  +  one very good prompt  =  an agent that works while you sleep
```

Extracted from a production SRE agent that has run continuously for months, handling real incidents.
Every design decision here exists because its absence caused a specific, documented failure.

## What you get

- **An agent that stays up.** It restarts after a crash or reboot and picks its work back up without
  you.
- **Real-time wakes.** A chat message or job wakes it immediately, so it only needs an occasional
  safety-net wake instead of constant polling.
- **Named agents.** Each has its own folder, memory, login and queue, and you can run several at once.
- **Watchdog alerts.** It repairs what it can, and tells you specifically what it can't.
- **Memory across restarts.** Plain Markdown files that you can read and edit.

**Contents:** [Quickstart](#quickstart) · [Commands](#commands) ·
[Build your own agent](#build-your-own-agent) · [Connect chat](#connect-chat) ·
[Projects and jobs](#give-an-agent-projects-and-jobs) ·
[Install without Docker](#install-without-docker) · [Configuration](#configuration) ·
[How it works](#how-it-works) · [Safety](#safety--read-this-part) ·
[Troubleshooting](#troubleshooting) · [Failure modes](#the-failure-modes) ·
[Repository layout](#repository-layout) · [Tests](#tests) · [Uninstall](#uninstall)

---

## Quickstart

This takes you from a fresh clone to a running agent with Docker.

### Before you start

- [Docker](https://docs.docker.com/get-started/get-docker/) with Compose 2.24 or later
- A [Claude Code](https://claude.com/claude-code) account

This has been tested on macOS. Linux should also work, and Windows would need WSL2. You don't need
Node, Python or tmux on your machine, because they're in the image.

### 1. Create an agent

```bash
git clone https://github.com/bitnormous/semperwake.git
cd semperwake
./semperwake new alpha --owner "Your Name"
```

This creates `agents/alpha/` with everything the agent needs. The folder name is the agent's name,
and it can contain lowercase letters, digits and hyphens.

### 2. Give it a job

Open `agents/alpha/BOOTSTRAP-PROMPT.txt` and replace the three sections marked with placeholders.
If you left out `--owner`, also replace every `<OWNER_NAME>`.

| Placeholder | What to write |
|---|---|
| `<ONE PARAGRAPH: ...>` | The agent's role, and what it must leave to others |
| `<FILL IN: your routing rules ...>` | Where it should report, and when to stay quiet |
| `<FILL IN: your own hard laws ...>` | Rules it must never break, such as "never push to main" |

The agent won't start with a placeholder left in, because an unfilled prompt has no safety rules.
[docs/PROMPT-GUIDE.md](docs/PROMPT-GUIDE.md) explains how to write each section.

Then describe the agent in `agents/alpha/IDENTITY.md` and `SOUL.md`.

### 3. Check it

```bash
./semperwake check alpha
```

`check` lists everything that would stop the agent working, all at once. A warning about the image
or login is expected at this point.

### 4. Log in once

```bash
./semperwake login alpha
```

Your computer's Claude login doesn't carry into the container, so each agent logs in once. The first
run builds the image, which takes several minutes.

1. Open the URL it prints in your browser, sign in, and paste the code back.
2. Choose **Yes, I accept** on the Bypass Permissions warning. Read it first: it's the reason for
   the [Safety](#safety--read-this-part) section.
3. Type `/exit`.

### 5. Start it

```bash
./semperwake up alpha
./semperwake logs alpha
```

Allow about 30 seconds for the agent to load its prompt. To watch it think, run
`./semperwake attach alpha`, and press `Ctrl-B` then `d` to leave without stopping it.

From here it keeps running in the background, and it comes back after a reboot whenever Docker
starts.

---

## Commands

| Command | What it does |
|---|---|
| `./semperwake new <name> [--owner NAME] [--provider none\|slack\|discord]` | Create an agent, or add what an existing folder is missing. It never overwrites your files |
| `./semperwake check <name>` | List everything that would stop the agent working |
| `./semperwake login <name>` | Log in to Claude and accept the permissions warning |
| `./semperwake up <name>` | Run `check`, then start the agent |
| `./semperwake down <name>` | Stop it, keeping its login and memory |
| `./semperwake restart <name>` | Restart it and apply `.env` or `compose.yaml` changes |
| `./semperwake status <name>` | Show whether it's running, and its provider |
| `./semperwake attach <name>` | Watch it think (detach with `Ctrl-B` then `d`) |
| `./semperwake logs <name>` | Follow its logs and watchdog alerts |
| `./semperwake job <name> <job>` | Run a section of its `JOBS.md` now |
| `./semperwake list` | Show every agent and whether it's running |

A restart starts a new Claude session, so the agent loses its live conversation. What it wrote to
its memory files stays.

---

## Build your own agent

Each agent is a folder in `agents/`, and the full guide is in
**[agents/README.md](agents/README.md)**.

| File | What it's for |
|---|---|
| `IDENTITY.md` | Name, role and voice |
| `SOUL.md` | Principles, and what the agent owns |
| `BOOTSTRAP-PROMPT.txt` | Instructions and safety rules. This is the most important file |
| `MEMORY.md` | Facts it should always know. The agent adds to this |
| `INSTINCTS.md` | IF→THEN reflexes. The agent adds to this |
| `HEARTBEAT.md` | What to check on every wake |
| `JOBS.md` | Procedures it can run on request |
| `.env` | Chat provider, owner and tokens for this agent |
| `compose.yaml` | Optional project mounts and other Docker settings |

Two things people skip, and then wonder why the agent is useless:

1. **Fill in the prompt properly.** It decides who the agent is, how it reports and who may
   authorise a write.
2. **Write `MEMORY.md` and `INSTINCTS.md`.** An agent with no memory re-derives its own rules on
   every restart and gets them wrong differently each time. Memory is what makes it the *same* agent
   tomorrow.

Everything in `agents/` except `README.md` and `example/` is gitignored, because agents hold private
notes and tokens. To version an agent, give its folder its own private repository.

---

## Connect chat

Without a chat provider, an agent paces itself and writes its reports to
`agents/<name>/.run/state/notify.log`. **Start here**, and add chat once the agent is working.

| `CHAT_PROVIDER` | Status | How it connects |
|---|---|---|
| `none` | ✅ shipped | No chat integration |
| `slack` | ✅ shipped | Socket Mode: no public URL or inbound firewall rule |
| `discord` | ✅ shipped | Gateway WebSocket: the same, plus auto-resume |
| `teams` | 🚧 wanted | Needs an Azure app registration; [PRs welcome](CONTRIBUTING.md) |
| `matrix` / `telegram` / `irc` | 🚧 wanted | Each is one small listener |

An agent connects to one provider at a time. To add one, pass `--provider` to `new`, or set
`CHAT_PROVIDER` in the agent's `.env` and copy in the settings below:

```bash
./semperwake new alpha --provider discord
```

Give each agent its own bot, so two agents never answer the same message. These settings go in
`agents/<name>/.env`:

| Setting | What it's for |
|---|---|
| `OWNER_ID` | **Your** Slack or Discord user ID. Only this person can authorise writes |
| `SELF_BOT_ID` | The bot's own user ID. Without it, the agent can read its own replies as new messages |
| `OWNER_CHANNELS` | Comma-separated channel IDs where your messages count as instructions |
| `INCIDENT_CHANNELS` | Comma-separated channel IDs carrying alerts for the agent to triage |
| `ALERT_CHANNEL` | Where watchdog alerts and reports go. Blank means your DM |

### Discord

1. Create an app at [discord.com/developers/applications](https://discord.com/developers/applications).
2. Under **Bot**, choose **Reset Token**, and save it as `DISCORD_BOT_TOKEN`.
3. Under **Privileged Gateway Intents**, enable **Message Content Intent**. Without it, every message
   arrives empty.
4. Under **OAuth2 → URL Generator**, select the `bot` scope and the **View Channels**, **Send
   Messages** and **Read Message History** permissions. Use the URL to invite the bot.
5. Turn on Developer Mode in Discord, then right-click to copy your user ID and the bot's.

### Slack

1. Create an app at [api.slack.com/apps](https://api.slack.com/apps).
2. Enable **Socket Mode** and generate an app-level token with `connections:write`. Save it as
   `SLACK_APP_TOKEN` (`xapp-...`).
3. Under **OAuth & Permissions**, add the bot scopes `chat:write`, `channels:history`,
   `groups:history`, `im:history`, `im:write`, `users:read` and `reactions:write`. Install the app,
   and save the token as `SLACK_BOT_TOKEN` (`xoxb-...`).
4. Under **Event Subscriptions**, subscribe to `message.channels`, `message.groups`, `message.im` and
   `app_mention`.
5. Invite the bot to every channel it should watch. A bot that isn't in a channel receives nothing.

When you're done, run `./semperwake check <name>` and then `./semperwake restart <name>`.

### Add another provider or event source

The filter, nudger and watchdog read one normalized format, so they don't change per platform. A new
platform is one listener that appends JSON lines to the queue, plus a `notify.sh` path if the agent
must send messages through it.

```json
{"ts":"2026-10-30T09:11:30Z","provider":"discord","kind":"message",
 "channel":"1234","channel_type":"dm","user":"5678","text":"deploy the hotfix, go",
 "thread":"","is_bot":false,"mentions_self":false,"raw":{}}
```

Producers don't have to be chat. Cron jobs, GitHub webhooks and log tailers can add `"kind":"job"` or
`"kind":"signal"` lines to the same queue. The full contract is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Give an agent projects and jobs

### Projects

An agent can only reach its own folder. To add a project, create `agents/alpha/compose.yaml`:

```yaml
services:
  agent:
    volumes:
      - ~/code/my-app:/projects/my-app       # read and write
      - ~/code/docs:/projects/docs:ro        # read only
```

Tell the agent about those paths in `MEMORY.md`, then run `./semperwake restart alpha`. This file
accepts anything Docker Compose does, such as ports, memory limits or extra environment variables.

### Jobs

Add a section to `agents/alpha/JOBS.md`:

```markdown
## daily-summary

Summarize what changed since the last run and report it with `scripts/notify.sh`.
```

Run it with `./semperwake job alpha daily-summary`. To schedule it, add that command to your host's
crontab using the full path:

```cron
0 8 * * * /path/to/semperwake/semperwake job alpha daily-summary
```

The command fails if the agent isn't running, so a missed job shows up in cron's output.

---

## Install without Docker

Use this when the agent's job is to operate a Linux host itself: its services, logs and deploys. A
container can't reach those, by design.

You need Linux with systemd user units, `tmux`, `python3` and
[Claude Code](https://claude.com/claude-code), plus Node 18 or later for Slack or Discord. Run these
as a **dedicated, least-privileged Unix user**, not root:

```bash
git clone https://github.com/bitnormous/semperwake.git
cd semperwake

# 1. Log in, accept the warning, then /exit.
claude --dangerously-skip-permissions

# 2. Configure.
cp .env.example .env
$EDITOR .env                  # set AGENT, and CHAT_PROVIDER if you want chat

# 3. Install.
./install.sh

# 4. Fill in the prompt, then arm the agent.
$EDITOR "$HOME/semp/BOOTSTRAP-PROMPT.txt"
semp-bootstrap
```

Everything is named after your `AGENT` value, which is `semp` above.

```bash
semp-attach status     # what's up, and which provider
semp-attach            # watch it think (detach: Ctrl-B then d)
semp-attach logs       # follow the journal
semp-attach restart    # restart it
semp-bootstrap         # re-arm the loop by hand
```

The native install does not support macOS, because it depends on systemd user units. `launchd`
equivalents are welcome as a PR.

### Docker or native

| | Docker | Native |
|---|---|---|
| **Runs on** | Anywhere Docker runs | Linux with systemd |
| **Can reach** | Only what you mount or give it credentials for | Whatever its Unix user can |
| **Keeps it alive** | A restart loop per process in `docker/entrypoint.sh`, and `restart: unless-stopped` | `Restart=always` on each unit |
| **Survives logout** | Yes, through the Docker daemon | Yes, through `loginctl enable-linger` |
| **Working directory** | `agents/<name>/` | `~/<agent>/` |
| **Logs** | `./semperwake logs <name>` | `<agent>-attach logs` |
| **Claude login** | A named volume per agent | `~/.claude` |
| **Event queue** | `agents/<name>/.run/` | `/tmp`, which is cleared on reboot |
| **Wake on jobs without chat** | Yes | No: the nudger needs a chat provider |

---

## Configuration

With Docker, settings come from `agents/<name>/.env`, and then from an optional shared `.env` at the
repository root. An agent's own value wins, even if it's blank, so delete a line to fall back to the
shared one. [.env.example](.env.example) documents every chat and pacing option.

| Setting | Default | What it does |
|---|---|---|
| `CHAT_PROVIDER` | `none` | `none`, `slack` or `discord` |
| `IDLE_STALL_SECS` | `2400` | How long an unchanged screen counts as frozen. **Must stay above** the agent's longest idle wake, which is 600s in the shipped prompt |
| `NUDGE_COOLDOWN_SECONDS` | `15` | One burst of events causes one wake within this window |
| `NUDGE_PATTERN` | blank | Extra regex for queue lines worth waking for |

These apply to Docker only:

| Setting | Default | What it does |
|---|---|---|
| `WATCHDOG_BOOT_SECS` | `90` | Delay before the first watchdog pass |
| `WATCHDOG_EVERY_SECS` | `120` | Time between watchdog passes |
| `BOOTSTRAP_DELAY_SECS` | `25` | Delay before pasting the prompt into a new session. The watchdog allows 60s, so keep it below that |
| `PROMPT_POLL_SECS` | `10` | How often to look for a filled-in prompt |
| `AGENT_UID` | `1000` | Container user ID, for Linux hosts. Set it in the shell or the root `.env`, then rebuild |

Compose sets `WORKSPACE`, `STATE_DIR`, `EVENT_JSONL` and `CURSOR_FILE` itself, so they can't move an
agent's state out of its folder.

Claude Code doesn't update itself in the container. To upgrade, change `CLAUDE_CODE_VERSION` in the
`Dockerfile`, run `docker compose build`, and restart your agents.

---

## How it works

Five parts, each independently replaceable. The names below are the native install's. In Docker,
`docker/entrypoint.sh` runs the same scripts.

| | Part | Job |
|---|---|---|
| **1** | `<agent>-claude.service` | Keeps a detached tmux session alive running `claude --dangerously-skip-permissions`, and **pastes the `/loop` prompt into it about 25s after launch**, so a crash or reboot resumes with no human action. |
| **2** | `BOOTSTRAP-PROMPT.txt` | **The actual product.** Identity, event contract, safety gates, loop pacing and measurement discipline. Everything else is plumbing for this file. |
| **3** | `<agent>-nudger.service` | Tails the queue and sends a literal `.` + Enter into the pane when an actionable line lands. **This is what makes the agent real-time instead of a poller.** |
| **4** | `<agent>-liveness.timer` | Every 2 minutes: unit up? session alive? login valid? pane moving? loop armed? It self-heals, or alerts loudly and specifically. |
| **5** | `<agent>-listener.service` | *Optional* chat producer. Swap freely. |

```
  slack / discord / cron / webhooks / your own producer
          │  append normalized JSON lines
          ▼
     event queue (JSONL) ──────────────────┐
          │                                │ tail -F
          │ signal-filter.py               ▼
          │ (firehose → tagged signal)  nudger ── "." + Enter ──┐
          │                                                      │
          ▼                                                      ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  tmux session "<agent>"  →  claude  ←── /loop BOOTSTRAP-PROMPT  │
   └─────────────────────────────────────────────────────────────────┘
          ▲                                       ▲
          │ restart on exit                       │ every 2 min: heal or alert
     supervisor                               watchdog
```

The `.` is a **wake signal, not a message.** The prompt tells the agent that any bare `.` means
*drain your queue and take a turn*. This avoids a fixed-interval polling loop and lets events wake
the agent promptly.

Full rationale: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**

---

## Safety — read this part

`--dangerously-skip-permissions` is used because no human is present to approve tool-call prompts.
The prompt supplies behavioural policy, but **it is not a security boundary**. A prompt can be
ignored or talked around, so the real limits must come from what the agent can actually reach.

The shipped prompt requires all three of these for every write action:

1. the request **originates from the owner** (`OWNER_ID`, a verified identity and not a relayed
   claim);
2. the owner used an **explicit confirmation word**: "go", "do it", "ship", "merge it", "deploy",
   "ok", "yes" or "confirmed";
3. the agent **restates the exact action** before executing it.

Authorisation is per-batch and doesn't extend to the next batch. Building a PR is not merging a PR.
You can tighten this list in your prompt, for example by removing "ok" and "yes".

For real enforcement:

- **Limit what it can reach.** In Docker, the container is the boundary: a non-root user with all
  capabilities dropped. Natively, run it as a dedicated Unix user.
- **Limit what it holds.** Give it a narrow token per integration, never your personal passwords. An
  agent with no publishing token can't publish, whatever its prompt says.
- **Mount as little as possible**, and read only where you can.
- **Never mount the Docker socket or your home directory.** Either one removes the boundary.
- **Remember the network is open.** The container doesn't restrict outbound traffic, so anything the
  agent can read, it could send elsewhere.

Claude Code's plan terms and limits apply to your agent. Check that always-on use fits your plan, or
use an API key.

---

## Troubleshooting

Start with `./semperwake check <name>`, and then `./semperwake logs <name>`.

| What you see | Cause | Fix |
|---|---|---|
| `waiting: fill in every placeholder` in the logs | The prompt still has placeholders | Finish the prompt. The agent starts by itself when you save it |
| `ALERT[login-expired]` | Claude is logged out, or the key is invalid | Run `./semperwake login <name>`, then `./semperwake restart <name>` |
| `ALERT[bypass-unaccepted]` | The permissions warning hasn't been accepted | Run `./semperwake attach <name>` and choose **Yes, I accept**. The watchdog re-arms it within about 2 minutes |
| The agent is up but idle | The prompt didn't load | Run `AGENT=<name> docker compose exec agent <name>-bootstrap`, or restart it |
| Discord messages arrive empty | Message Content Intent is off | Enable it in the Discord developer portal |
| The agent replies to itself | `SELF_BOT_ID` is empty or wrong | Set it to the bot's user ID, then restart |
| The agent ignores you in a channel | The bot isn't in the channel, or it isn't listed | Invite the bot, and add the ID to `OWNER_CHANNELS` |
| A `.env` or `compose.yaml` change had no effect | The container still has the old settings | Run `./semperwake restart <name>` |
| No alerts appear in chat | There's no provider, or no channel | With `CHAT_PROVIDER=none`, read `.run/state/notify.log` |
| `Permission denied` on Linux | The container's user doesn't own `agents/` | Set `AGENT_UID=$(id -u)` in the root `.env`, then run `docker compose build` |
| The wrong agent responds to `docker compose` | `AGENT` wasn't set | Use `./semperwake`, or prefix commands with `AGENT=<name>` |
| An agent keeps restarting | It's crashing on start | Find the first error with `./semperwake logs <name>` |

---

## The failure modes

This is the part worth reading even if you never run the code. Every item cost real downtime, and
each one ships as code rather than as advice.

**A restarted session with no prompt is a bare `claude` that idles forever**, and every instrument
reports it healthy. `systemctl status` says active. `tmux has-session` says yes. The process list
looks perfect. It just sits there. Hence the auto-paste, and a watchdog that checks whether the loop
is *armed* rather than whether the process exists.

**A first-run screen can turn the auto-paste into a restart loop.** The bypass warning defaults to
`No, exit`, so the paste's Enter quits Claude, and a logged-out picker has no error text for a
watchdog to match. The pane is read before anything is typed, and screens that need a human raise an
alert.

**`loginctl enable-linger` is mandatory on a native install.** Without it every user unit dies the
moment you log out of SSH: the classic "it worked until I closed my laptop".

**Nudge debounce is load-bearing.** Claude queues keystrokes, so 5 events in 5 seconds becomes 5
queued turns and the agent burns its budget re-waking instead of working. One burst must produce
exactly one wake.

**`tmux send-keys "." Enter` as a single call races Claude's input buffering.** The `.` gets
swallowed and you're left with a bare Enter that does nothing at all.

**A process blocked on a file that never appears is indistinguishable from a healthy one.** The
nudger logs *before* it blocks for exactly this reason. A production agent silently lost its entire
wake path for about six weeks this way: the "waiting" state produced no output, so every check read
green.

**Reading the raw queue makes an agent conclude "all quiet" and miss the one message that mattered.**
A busy queue is mostly firehose. `signal-filter.py` is the only sanctioned read path. It tags, drops
the agent's own echoes, advances a cursor, and treats a truncated file as rotation rather than as an
empty queue.

**The frozen-pane threshold must exceed the agent's longest idle wake interval**, or your watchdog
cheerfully restarts a perfectly healthy sleeping agent every few minutes.

**An expired login is a human-only fix.** The watchdog alerts instead of restarting, because
restarting can't fix credentials, and thrashing the unit buries the one message that explains the
silence.

More, including the measurement errors that make an agent *confidently wrong* about its own
infrastructure: **[docs/FAILURE-MODES.md](docs/FAILURE-MODES.md)**

---

## Repository layout

```
semperwake                     create, check and run agents with Docker
agents/README.md               the guide to building an agent
agents/example/                the profile that `new` copies
agents/<name>/                 your agents (gitignored)
compose.yaml, Dockerfile       the Docker install
docker/entrypoint.sh           starts and restarts the scripts in place of systemd
install.sh                     idempotent installer; generates the runtime scripts
prompts/BOOTSTRAP-PROMPT.txt   the agent's brain (template: you must edit it)
.env.example                   chat and pacing options, documented
docs/ARCHITECTURE.md           the five parts, the producer contract, why each exists
docs/FAILURE-MODES.md          the full catalogue of what goes wrong
docs/PROMPT-GUIDE.md           how to write a bootstrap prompt that holds up
test/run-tests.sh              hermetic test suite: stubs every binary, touches nothing real
CLAUDE.md                      how to work on this repository, for AI coding agents
```

`install.sh` generates each agent's runtime files. In Docker it runs on every start and writes them
to `agents/<name>/`. Natively it writes them to `~/<agent>/`, plus these:

```
~/.local/bin/<agent>-{bootstrap,attach}
~/.config/systemd/user/<agent>-*.{service,timer}
```

The generated files in the working directory are:

```
agent.env                     single source of truth; every script sources it
scripts/run.sh                tmux + claude + auto-bootstrap
scripts/nudger.sh             debounced wake on actionable events
scripts/watchdog.sh           liveness checks
scripts/notify.sh             provider-agnostic "send a message"
scripts/signal-filter.py      firehose → tagged signal
scripts/<provider>-listener.mjs   installed only for Slack or Discord
```

---

## Tests

```bash
./test/run-tests.sh
```

The suite is hermetic. It stubs `tmux`, `systemctl`, `loginctl`, `claude`, `curl` and `docker`, runs
everything in a throwaway `HOME`, and asserts real behaviour:

- the no-chat, Slack and Discord tiers, and `.env` loading and precedence
- signal-filter tagging across mixed providers, and cursor semantics under rotation
- nudge debounce under burst, and notify routing per provider
- every watchdog path, including alert dedupe
- container supervision and the `semperwake` command

It never touches your systemd, your network or your real agent, and section 12 asserts that.

The suite needs GNU tools, so on macOS, run it inside the image:

```bash
docker build -t semperwake:local .
docker run --rm -v "$PWD":/src:ro --entrypoint bash semperwake:local \
  -c 'cp -r /src /tmp/repo && cd /tmp/repo && ./test/run-tests.sh'
```

---

## Uninstall

### Docker

```bash
./semperwake down alpha                 # stop the agent
docker volume rm semperwake-alpha_home  # delete its Claude login
rm -rf agents/alpha                     # delete its memory, prompt and tokens
docker rmi semperwake:local             # delete the image, once no agent uses it
```

Back up the agent's folder first if you might want it again.

### Native

```bash
systemctl --user disable --now semp-claude semp-nudger semp-listener semp-liveness.timer
rm -f ~/.config/systemd/user/semp-*.service ~/.config/systemd/user/semp-*.timer
rm -f ~/.local/bin/semp-bootstrap ~/.local/bin/semp-attach
systemctl --user daemon-reload
tmux kill-session -t semp 2>/dev/null || true
```

This stops the agent but deliberately keeps `$HOME/semp`, with its memory, prompt and state. Remove
that directory, its event and cursor files, and its state directory only after you've backed up
anything you need. Substitute your `AGENT` value for `semp` throughout.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The two most valuable PRs are **a new entry in
[docs/FAILURE-MODES.md](docs/FAILURE-MODES.md)**, describing a way an always-on agent silently died
on you and the mechanical check that would have caught it, and **a new chat provider**, which is one
listener and a row in the table above.

## License

MIT — see [LICENSE](LICENSE).
