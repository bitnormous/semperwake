# Build your own agent

Each folder here is one agent. It has its own identity, memory, login and event queue, and it's
mounted at `/workspace` in the agent's container.

```bash
./semperwake new alpha --owner "Your Name"
```

Then describe the agent, and let `check` tell you what's left:

```bash
./semperwake check alpha
./semperwake login alpha
./semperwake up alpha
```

Use lowercase letters, digits and hyphens for the name. If you already have a folder here, `new`
adds only what's missing and keeps your files.

## What to edit

| File | What it's for |
|---|---|
| `IDENTITY.md` | Name, role and voice |
| `SOUL.md` | Principles, and what the agent owns |
| `BOOTSTRAP-PROMPT.txt` | Instructions and safety rules. **Fill in every placeholder**: the agent won't start until you do |
| `MEMORY.md` | Facts it should always know. The agent adds to this |
| `INSTINCTS.md` | IF→THEN reflexes. The agent adds to this |
| `HEARTBEAT.md` | What to check on every wake |
| `JOBS.md` | Procedures it can run on request |
| `.env` | Chat provider, owner and tokens for this agent |

`memory/` holds the agent's daily ledgers. `agent.env`, `scripts/`, `config/` and `.run/` are
generated, so don't edit them.

## Connect chat

```bash
./semperwake new alpha --provider discord
```

This adds the settings Discord needs to `agents/alpha/.env`, and `slack` works the same way.
`.env.example` explains how to get each value. Give each agent its own bot, so that two agents never
answer the same message.

Values in a shared `.env` at the repository root apply to every agent. An agent's own `.env` wins,
even when its value is blank, so delete a line to fall back to the shared one.

## Give it projects to work on

An agent can only reach its own folder. To add more, create `agents/alpha/compose.yaml`:

```yaml
services:
  agent:
    volumes:
      - ~/code/my-app:/projects/my-app       # read and write
      - ~/code/docs:/projects/docs:ro        # read only
```

Then tell the agent about those paths in `MEMORY.md`, and run `./semperwake restart alpha`. This file
accepts anything Docker Compose does, such as ports, memory limits or extra environment variables.

Mount only what the agent needs, and prefer read only. **Never mount the Docker socket or your home
directory:** the agent runs without permission prompts, so anything it can reach, it can change.

## Run jobs on a schedule

Add a section to `JOBS.md`:

```markdown
## daily-summary

Summarize what changed since the last run and report it with `scripts/notify.sh`.
```

Run it with `./semperwake job alpha daily-summary`. To schedule it, add that command to your host's
crontab, using the full path to `semperwake`:

```cron
0 8 * * * /path/to/semperwake/semperwake job alpha daily-summary
```

## Keep secrets out

- Put tokens in `.env`, never in the prompt or memory files.
- Give the agent the narrowest token that does the job. Don't hand it your own passwords.
- Treat a write the agent can't do as a good thing: an agent with no publishing token can't publish.

## Keep it private

Everything here except `README.md` and `example/` is gitignored, because agents hold private notes
and tokens. To version an agent, give its folder its own private repository.
