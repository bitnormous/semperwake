# CLAUDE.md

Guidance for AI coding agents working on this repository. Read it before changing anything.

## What this is

semperwake keeps Claude Code running as an always-on autonomous agent. It's mostly bash: an installer,
a prompt template, a small CLI and Docker files. There is no application server or build step, and
`claude` is the only agent process.

It runs two ways, and both use the same generated scripts:

- **Docker** (`SUPERVISOR=container`): `./semperwake` drives `compose.yaml`, and
  `docker/entrypoint.sh` keeps the scripts alive. Works anywhere Docker runs.
- **Native** (`SUPERVISOR=systemd`, the default): `install.sh` writes systemd user units. Linux only.

**This repository is public.** See [Never commit](#never-commit).

## Commands

```bash
# Tests. Needs GNU sed and stat, so on macOS run them in the image:
docker build -t semperwake:local .
docker run --rm -v "$PWD":/src:ro --entrypoint bash semperwake:local \
  -c 'cp -r /src /tmp/repo && cd /tmp/repo && ./test/run-tests.sh'

# On Linux:
./test/run-tests.sh
KEEP=1 ./test/run-tests.sh      # keep the sandbox for inspection

# Syntax checks, which CI also runs
for f in install.sh semperwake docker/entrypoint.sh test/run-tests.sh; do bash -n "$f"; done
```

The first image build takes several minutes. `docker build` needs no buildx.

## Where things live

| Path | What it is |
|---|---|
| `install.sh` | Generates every runtime script from heredocs. **Most runtime logic lives here** |
| `semperwake` | Developer CLI. Only drives `docker compose`; nothing depends on it at runtime |
| `docker/entrypoint.sh` | Container's stand-in for systemd: one restart loop per process |
| `compose.yaml`, `Dockerfile` | Docker install. One Compose project per agent: `semperwake-<agent>` |
| `prompts/BOOTSTRAP-PROMPT.txt` | Agent behaviour template. The docs call this the actual product |
| `agents/example/` | Profile copied by `semperwake new` |
| `agents/README.md` | Developer guide to building an agent |
| `test/run-tests.sh` | Hermetic suite, one numbered section per area |
| `docs/` | `ARCHITECTURE.md`, `FAILURE-MODES.md`, `PROMPT-GUIDE.md` |

### Generated files: edit the source

`run.sh`, `nudger.sh`, `watchdog.sh`, `notify.sh`, `signal-filter.py`, the listeners and the
`<agent>-attach` and `<agent>-bootstrap` helpers **do not exist in this repo as files**. They are
heredocs in `install.sh`, written to `<workspace>/scripts/` and `~/.local/bin/` at install time.

Check the heredoc's quoting before editing:

- `<<'SCRIPT'` is quoted, so `$VAR` is literal and expands when the script runs.
- `<<EOF` is unquoted, so `$VAR` expands at install time, and runtime variables need `\$VAR`. The
  attach and bootstrap helpers and the systemd units use this form.

Every generated script sources `agent.env`. To add a setting, add it to the config block and the
`agent.env` heredoc in `install.sh`, and document it in `.env.example`. Section 1 of the tests checks
the main settings. `agent.env` is sourced unquoted, so its values can't contain spaces.

### How a start works in Docker

`entrypoint.sh` runs any explicit command and exits. Otherwise it runs `install.sh`, sources
`agent.env`, and waits until the prompt has no placeholders. It then supervises `run.sh`, the nudger
and the listener, plus a watchdog loop.

`run.sh` starts tmux and `claude`, pastes the prompt after `BOOTSTRAP_DELAY_SECS`, then blocks until
the session ends. The watchdog restarts `claude` by killing the tmux session, which makes `run.sh`
exit into its loop. `unit_active`, `unit_start` and `unit_restart` in the watchdog are the only code
that differs by supervisor.

## Rules that must stay in sync

Nothing enforces these except tests and care, so change every location together:

| Value | Locations |
|---|---|
| Prompt placeholders `<OWNER_NAME\|FILL IN\|ONE PARAGRAPH>` | `PLACEHOLDERS` in `semperwake`, `placeholders` in `docker/entrypoint.sh`, the template, and the `fill` helper and `sed` in tests |
| Human-only screens: `select login method`, `paste code here`, `yes, i accept` | `run.sh` and `watchdog.sh`, both in `install.sh` |
| Paste delay (25s) must stay below the watchdog's boot grace (60s) | `run.sh` and check 5 in `watchdog.sh` |
| `IDLE_STALL_SECS` (2400) must exceed the longest idle wake (600s) | `.env.example`, `install.sh`, the prompt |
| Template substitutions | `install.sh` step 2 and `cmd_new` in `semperwake` |
| Docker queue and state paths | `compose.yaml` and `cmd_new` in `semperwake` |
| Watchdog cadence (90s, 120s) | `entrypoint.sh` defaults and the systemd timer in `install.sh` |

## Code style

Follow `CONTRIBUTING.md`. In short:

- `set -euo pipefail`, except the watchdog, which must survive a failing check.
- Quote everything. No dependencies beyond coreutils, `tmux` and `python3`, plus `node` for listeners.
- **Comment the why.** Most lines here prevent a specific failure that isn't visible from reading
  them. Check for a comment before removing anything that looks redundant.
- `semperwake` runs on the host, so it must work on **macOS's bash 3.2**: no `mapfile`, associative
  arrays or `${var,,}`. It must also work with BSD `sed`, so use `sed -i.bak`.
- `install.sh` must stay idempotent, and `semperwake new` must never overwrite a user's file.
- **Don't add a runtime.** No supervisor, broker, daemon or web service between the host and `claude`.
  New event producers are welcome: they only append JSON lines to the queue.

## Testing changes

**Any behavioural change needs a test.** Add it to the matching section of `test/run-tests.sh`. The
suite must stay hermetic: stub binaries, use the sandbox, and never touch real systemd, tmux, Docker
or the network.

**Stubs can't catch everything.** The stubs have hidden real failures here before, so for anything
touching tmux, `claude` or Docker, also run the real stack:

```bash
./semperwake new swtest --owner Tester
sed -i '' -e '/<ONE PARAGRAPH/,/>$/d' -e '/<FILL IN/,/>$/d' agents/swtest/BOOTSTRAP-PROMPT.txt   # macOS
printf 'ANTHROPIC_API_KEY=sk-ant-fake0000000000000000000000000000\nWATCHDOG_BOOT_SECS=20\nWATCHDOG_EVERY_SECS=20\n' >> agents/swtest/.env
```

To skip the first-run screens with that fake key, pre-seed the volume before `up`:

```bash
AGENT=swtest docker compose run --rm -T agent python3 -c '
import json,os
k=os.environ["ANTHROPIC_API_KEY"][-20:]
json.dump({"hasCompletedOnboarding":True,"customApiKeyResponses":{"approved":[k],"rejected":[]}},open(os.path.expanduser("~/.claude.json"),"w"))
os.makedirs(os.path.expanduser("~/.claude"),exist_ok=True)
json.dump({"skipDangerousModePermissionPrompt":True},open(os.path.expanduser("~/.claude/settings.json"),"w"))'
./semperwake up swtest
```

Leave the seeding out to test the screens themselves. A fake key ends in a correct `login-expired`
alert once the agent tries to think, so this proves supervision, not a real Claude turn.

Clean up afterwards, and leave other containers on the machine alone:

```bash
./semperwake down swtest
docker volume rm semperwake-swtest_home
rm -rf agents/swtest
```

`./semperwake check` runs a real container, so it creates a `semperwake-<agent>_home` volume even
when the agent is never started.

## Behaviour worth knowing

- `docker compose restart` keeps the old `.env` and mounts, so `semperwake restart` recreates the
  container instead.
- A restart loses the live Claude conversation. Only memory files carry over, so don't restart
  `claude` to fix a problem in a helper process.
- The bypass-permissions warning defaults to `No, exit`, so typing Enter on it kills `claude`. Never
  pre-accept it in code: `semperwake login` makes a human accept it, and the watchdog alerts if not.
- The nudger runs for every Docker agent, but natively only with a chat provider.
- An agent's `.env` is read by Compose, so a blank value overrides the shared root `.env`.
- `AGENT_UID` and `AGENT` are Compose interpolation values. They work from the shell or root `.env`,
  not from `agents/<name>/.env`.
- `/agents/*` is gitignored, and only `agents/README.md` and `agents/example/` are public.
- `.dockerignore` is an allowlist, so a new file the image needs must be added there too.

## Never commit

The repository is public, and agents hold private data.

- Don't commit anything under `agents/<name>/` except `agents/example/`. Before committing, confirm
  with `git status --short` and `git check-ignore`.
- Don't commit `.env` files, tokens, real channel or user IDs, hostnames or internal service names.
  Use obvious placeholders such as `xoxb-...` in code and fixtures.
- Don't put private project details in this file. It's public too.

Commit and push only when the user asks. `main` is the PR base branch, and work happens on `develop`.

## When you change behaviour

Update whichever of these apply: `README.md`, `agents/README.md`, `docs/ARCHITECTURE.md`, `.env.example`.
If you find a new way for an agent to fail silently, add it to `docs/FAILURE-MODES.md` with a runnable
check. Don't state a cause or platform behaviour in a comment or doc unless you've tested it.
