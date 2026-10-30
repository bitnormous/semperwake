# Contributing

## The most valuable contribution

**A new entry in [docs/FAILURE-MODES.md](docs/FAILURE-MODES.md).**

If you have run an always-on agent and it died quietly on you, that story is worth more than a
feature. The shape that makes one useful:

- **What you saw** — the reading that looked fine, or the number you reported
- **What was true** — and how much the two differed
- **Why it was invisible** — the mechanism, not "I wasn't careful enough"
- **The check** — something runnable that would have caught it

Entries that generalise past one stack are the best ones. *"Silence is only recovery if you are
still calling"* applies equally to a payment vendor, a queue consumer, and an agent's own heartbeat.

If the failure can be defended against in code rather than in prose, send that too — a watchdog
check, a guard in the installer, a line in the prompt template.

## Running the tests

```bash
./test/run-tests.sh          # ~10 seconds
KEEP=1 ./test/run-tests.sh   # keep the sandbox to poke at
```

The suite is hermetic: it stubs `tmux`, `systemctl`, `loginctl`, `claude`, `jq` and `curl`, installs
into a throwaway `HOME`, and asserts behaviour rather than output formatting. It will not touch your
systemd units, your tmux sessions, your network, or your real agent. Section 8 asserts that.

**Any behavioural change needs a test.** The whole premise of this repo is that silent failure is
the enemy, so a change you cannot demonstrate is a change that might be doing nothing.

## What makes a good PR here

**Shell style.** `set -euo pipefail` (the watchdog deliberately drops `-e`, since it must survive a
failing check and keep going). Quote everything. Prefer POSIX-ish bash over clever bash. No
dependencies beyond coreutils, `tmux`, `python3` — plus `node`/`jq` for the optional Slack source.

**Comment the *why*, not the *what*.** The codebase is deliberately heavy on comments explaining why
a line exists, because most lines exist to prevent a specific failure that isn't obvious from
reading them:

```bash
# Two calls, not one: `send-keys "." Enter` races Claude's input buffering
# and the "." can be swallowed, leaving a bare Enter that does nothing.
tmux send-keys -t "$SESSION" "."
sleep 0.1
tmux send-keys -t "$SESSION" Enter
```

If you remove something that looks redundant, check whether a comment explains what it is defending
against. If there is no comment and you believe the code is pointless, say so in the PR — a missing
rationale is itself a bug worth fixing.

**Keep the installer idempotent.** It must be safe to re-run. In particular it must never clobber a
user's edited `BOOTSTRAP-PROMPT.txt`, `MEMORY.md`, or `agent.env`. There is a test for this.

**Don't add a runtime.** The point of this project is that there is no framework between systemd and
`claude`. A PR that introduces a supervisor, a broker, a daemon, or a web service to manage the agent
is solving a different problem — and probably one of the problems this repo exists to avoid. New
*event producers* are very welcome; they just append JSON lines to a file.

## Things I would merge happily

- **`launchd` support** so this works on macOS. The tmux + prompt + nudge core is already portable;
  only the unit files and `loginctl` are Linux-specific.
- **More event producers**: GitHub webhooks, Discord, Matrix, email, a log tailer, a webhook sink.
  One file, appends JSON lines, ships with its own `signal-filter` variant.
- **A prompt library** — `prompts/` variants for different agent roles (SRE, release manager,
  on-call triage, research assistant) with the safety section intact.
- **Multi-agent examples**: two or three agents with disjoint scopes that name each other's
  boundaries, which is how they stay out of each other's way with no coordination layer.
- **A better armed-loop check.** The current one greps the pane for loop markers, which is a
  heuristic. Something more reliable would be a real improvement.

## Security

The safety model is: `--dangerously-skip-permissions` is unavoidable for an unattended agent, so the
controls are (a) the prompt's authorisation gate and (b) a dedicated unix user with least privilege.

If you find a way to weaken (a) — prompt injection through an event payload, a confirmation-word
bypass, an identity-spoofing path — that is a genuine security issue and a very welcome PR. Open an
issue, or email the maintainer if you would rather not disclose publicly first.

Please do not include real tokens, channel IDs, hostnames, or internal service names in issues,
PRs or test fixtures. Use obvious placeholders (`xoxb-...`, `CXXXXXXXXXX`, `example.com`).

## Code of conduct

Be straightforward and technical. Disagree about the engineering, not about the person. Reports of
things that broke are a gift — treat them that way.
