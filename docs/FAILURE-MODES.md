# Failure modes

A catalogue of how always-on agents die, and the mechanical check that catches each one.

These are from production, not from imagination. They're grouped by family, because the families
repeat: once you've seen three instances of *silence read as health*, you start recognising the
fourth before it costs you anything.

> **The meta-lesson, stated once up front:** naming a failure mode provides **zero** protection
> against committing it. In one shift an agent wrote a rule into its own memory file after making an
> error, then made the same class of error twice more within the hour. Articulating a rule is not a
> control. **Only the mechanical step protects you** — run the query, check the counter, open the
> file. Every entry below therefore ends in something you *run*, not something you remember.

---

## Family 1 — silence read as health

The worst shape of measurement error available. A false alarm costs attention; **a false all-clear
costs the incident.**

### A restarted session with no prompt idles forever, looking perfect

`systemctl status` says `active (running)`. `tmux has-session` exits 0. The process list is clean.
And the agent is doing nothing at all, because nothing ever gave it instructions.

This is the single most common way this architecture fails, and it's invisible to every standard
health check.

**The check:** read the pane and look for evidence the loop is *armed*, not that the process exists.

```bash
tmux capture-pane -p -t "$SESSION" | grep -qiE "loop|wake|queue|cursor" || re_bootstrap
```

### A process blocked on a file that never appears looks identical to a healthy one

A nudger waiting on its queue file, a worker waiting on a socket, a consumer waiting on a topic. If
the wait starts before the first log line, "silently broken" and "quietly healthy" emit the same
thing: nothing.

Cost in production: about six weeks of a completely dead wake path, while every check read green.

**The check:** log *before* you block, always.

```bash
while [ ! -f "$QUEUE" ]; do
    log "waiting for $QUEUE to appear"    # <- before the sleep, not after
    sleep 5
done
```

### `Restart=always` means a crash-loop never reaches `failed`

A service restarting 18 times a minute reports `active (running)` with a fresh pid on every check.
A sweep like `systemctl list-units | grep -v running` will never see it. One such loop burned ~67% of
a core for two days, rotating three 5MB log files, entirely unnoticed.

**The check:** the uptime column, not the state word.

```bash
systemctl --user show "$UNIT" -p NRestarts --value              # authoritative
systemctl --user show "$UNIT" -p ActiveEnterTimestamp --value   # when THIS run began
```

Anything whose uptime is under ~3 minutes on **two consecutive checks** is crash-looping, not
starting up.

### A metric that drops to exactly zero is a rotation suspect, not good news

An error counter went `294 → 0` with no recovery event. It read as "the vendor fixed it". The log had
simply hit `maxsize` and rotated; the real count was 295, sitting in `.log.1.gz`.

Then the *fix* for that broke the same day, because it hardcoded `.1.gz` — a second rotation moved
the data to `.2.gz` and the formula reported 295 when the truth was 526.

**The check:** sum live plus *every* archive, resolved at run time.

```bash
count_log() { local P="$1" T=0 C
  C=$(grep -hc "$P" app.log 2>/dev/null | head -1); T=$((T + ${C:-0}))
  for f in app.log.*.gz; do [ -f "$f" ] || continue
    C=$(zgrep -hc "$P" "$f" 2>/dev/null | head -1); T=$((T + ${C:-0})); done
  echo "$T"; }
```

Corollary for cursor-based readers: **`cursor > filesize` means rotation.** Reset to zero and
re-read. Treating it as "nothing new" silently drops everything after the rotation — which is why
`signal-filter.py` has that check.

### Silence is recovery only if you're still calling

An error stream went quiet for 2.5 hours. Nothing had recovered — the calls had stopped being made.
What proved it was never the error count: the *outcome* metric hadn't moved either.

**The check:** prefer the **outcome** metric to the **error** metric. Error counts can fall because
the thing stopped running; outcome counts cannot. And enumerate a dependency's event types before
trusting any single counter:

```bash
grep -h -oP '<vendor>\.[a-z._]+' app.log | sort | uniq -c | sort -rn
```

That one-liner surfaced two *other* live failures hiding behind the quiet one — neither matching the
event name being watched.

### Never suppress stderr on a health readout; a blank count is an error, not a zero

A fleet sweep with `2>/dev/null` on its list command reported "0 open items" when 33 were open. The
auth token had silently expired. Stderr suppression turned a loud failure into a confident wrong
answer.

**The check:** treat blank as BROKEN, never as none.

```bash
c=$(some_query --json | jq 'length')
[ -z "$c" ] && { echo "ERROR: auth/access — NOT zero"; exit 1; }
```

### A first-run screen turns the auto-paste into a restart loop

A fresh agent stopped at the bypass-permissions warning, whose default answer is `No, exit`. The
paste's Enter chose it, `claude` exited, the unit restarted, and the same thing happened again. No
turn ever ran.

Logged out was quieter still. There's no error text, only a login picker, so the watchdog matched
nothing, called the session un-armed, pasted the prompt into the login flow and logged `ok` on every
pass.

Neither appears in a stubbed test. Both were found by running the real `claude` in a clean container.

**The check:** read the pane before typing into it, and alert on anything only a human can answer.

```bash
tmux capture-pane -p -t "$SESSION" \
  | grep -qiE 'select login method|paste code here|yes, i accept' && alert_a_human
```

### The watchdog and the auto-paste can both arm the same session

A session in its first 25 seconds shows a splash with no loop markers, which is exactly what
"un-armed" looks like. If the watchdog fires in that window, it pastes, and then the runner pastes
again.

**The check:** don't judge a session younger than the auto-paste delay.

```bash
tmux display-message -p -t "$SESSION" '#{session_created}'
```

---

## Family 2 — the agent is confidently wrong about its own numbers

These don't kill the agent. They're worse: the agent keeps working and starts *reporting fiction*,
which costs you the trust that made it useful.

### Never infer "now" from your own scheduled wake

Tracking a 1/min failure rate, an agent bucketed by hour, read `3` in the current hour against `60`
in the previous, and was one sentence from reporting recovery. It was 3 minutes into the hour. Three
errors in three minutes *is* 1/min. Nothing had changed.

Event-driven wakes routinely arrive early, so **your wake deadline is an intention, not a clock.**

**The check:** `date -u`, every time. And never compare a partial bucket against a full one — convert
to a rate, or compare the same offset into both periods. A per-minute histogram beats hour buckets
for judging any trend:

```bash
cut -c12-17 app.log | uniq -c      # twelve consecutive 1s is unmistakable
```

### Count distinct entities, never matching lines

A vendor ticket claimed "205 failed calls on the live rail". The real number of distinct failing
operations was **5** — five stale rows re-polled ~190 times each by a retry job. Retries are not
incidents. Inflated volume is the direction that gets a ticket tested, found not to hold, and
dismissed.

**The check:** group by the identifying field before any count goes outward.

```bash
grep -h "$(date -u +%F)" app.log | grep -oP '"endpoint":"[^"]*"' \
  | sed -E 's/[0-9]{4,}/<id>/' | sort | uniq -c | sort -rn
```

Say both numbers when they differ: *"959 log lines, 5 affected rows."*

Same error wears other costumes: a **multi-day total quoted as a single day** (517 over 3 days
reported as one day's 500 — the real story was 43/422/201, and the day-over-day version was both
smaller and far more persuasive because the reader could check it).

### Read the authoritative counter instead of grepping for a number that already exists

An agent reported a service "restarted 16× today". It restarted **8** times. The grep pattern matched
both the start line and the exit line — two per restart, so exactly 2× the truth.

What makes this entry worth keeping: **16 is a plausible number.** No absurd result caught it. The
only thing that caught it was re-deriving a second way.

**The check:** ask whether the system already counts it. `NRestarts`, `systemctl show`, `/proc`
counters, DB aggregates and vendor dashboards are exact. When you must grep, count **one line per
event**, never a state-transition pair.

### "It fired" is not "it worked"

A scheduled job was reported as working because the timer showed it had run 47 minutes earlier. It
had exited 1 with a parse error.

```bash
systemctl --user show "$UNIT" -p Result --value   # 'success' or 'exit-code' — THIS is the answer
systemctl --user list-timers                      # only says WHEN. Says nothing about outcome.
```

Sweep the whole set before reporting on any of them:

```bash
for u in $(systemctl --user list-timers --all --no-legend | awk '{print $NF}'); do
  printf '%-46s %s\n' "$u" "$(systemctl --user show "$u" -p Result --value)"; done | grep -v success
```

### Filter process counts on the executable, never the command line

`pgrep -f X` matches the whole command line — including wrapper processes (`/bin/sh -c …`,
`flock …`) and **your own shell command, which contains the pattern you just typed.**

One agent "proved" its own session had launched a rogue process this way. Another reported 6–7
concurrent schedulers when the real count was 2, and recommended a fix for a duplication that did
not exist.

```bash
ps -eo comm,args --no-headers | awk '$1 ~ /^php/ && /artisan schedule:run/' | wc -l
```

### Sample, never snapshot, on a contended or degraded box

CPU steal read `0.0%`, then `36.0%` a few minutes later. Reporting the first one produced "contention
completely gone" — wrong, and it changed the story given to a human.

```bash
vmstat 5 25 | awk '$17 ~ /^[0-9]+$/ {s+=$17; n++;
  if(n==1){mn=$17;mx=$17} else {if($17<mn)mn=$17; if($17>mx)mx=$17}}
  END {printf "steal n=%d min=%d%% max=%d%% mean=%.1f%%\n", n, mn, mx, s/n}'
```

The `$17 ~ /^[0-9]+$/` guard is load-bearing: `vmstat` reprints its header row on long runs, and
that row's column 17 is the literal string `st`, which poisons the min/max comparison. The guardless
version worked fine at n=10 and broke silently at n=25 — exactly when you most want the wider sample.

Report the **mean plus min/max spread**, never a single instant. A wide spread is itself the finding.

And: **a number from a tool that can time out is not data.** Under starvation, `docker ps -q`
returned 0 containers and nearly triggered stopping a whole healthy stack.

---

## Family 3 — the agent acts on something it never looked at

### Never advise on an artifact you haven't opened

An agent recommended *against* sending a prepared report, reasoning from a summary of it. Opening the
file took ninety seconds and reversed the advice: the document already contained the analysis being
presented as new, and already pre-empted the objection being raised. **The only thing blocking a
correct, ready deliverable for three days was that advice — about a defect that wasn't in it.**

This bites hardest when the summary is *good*, which is what makes substituting it feel safe.

**The check:** before recommending for or against any document, PR, ticket or config — open it. A
summary, a ledger entry, or another agent's description is not the artifact.

Related, same investigation: **before asserting a system's trigger, find it.** "It fires on X" is a
claim to verify (grep the dispatcher, read the job), never to infer from a plausible upstream count.

### A release checkout is a shallow clone — its git history is a lie

Investigating an error, an agent attributed it to a deploy 40 minutes earlier. `git log -- <file>`
named the commit; `git show --stat` reported "1 file changed, +312 insertions" with a diff opening
`+<?php` — the textbook signature of a new file.

Pure artifact. With **one** commit visible, every file looks created by it.

```bash
git rev-parse --is-shallow-repository   # true
git rev-list --count HEAD               # 1
```

**What made it dangerous was that it fit.** The fabricated evidence named a real commit that really
had deployed 40 minutes before the error. *A false lead consistent with the timeline is far worse
than an obviously wrong one*, because nothing about it invites a second look.

### A permissive dry-run is worse than no dry-run

A `canProvision()` predicate returned `true` for an asset the real execution path could never handle:
the predicate built its candidate list as *matched providers ∪ {default}*, while the real resolver
returned the *matched* provider and only fell back to default on a miss. The UI advertised a rail
that could never work. Users saw a normal flow; the failure landed somewhere nobody was watching.

It survived **five months.**

**The check:** where a `canX()` / `supportsX()` / `isAvailable()` predicate sits beside a real
execution path, verify they resolve **identically**. Any extra fallback or looser match in the
predicate is a silent-failure generator. And **test the predicate against a known-BAD input** —
running it on working cases alone proves nothing.

### When the logs have expired, ask what the database and config still remember

That five-month bug was believed invisible without raising the log level. It was never invisible: it
was sitting in config and a one-line checker, plus database state (zero rows ever for that asset,
while the pool held 20 free addresses under providers the routing map never consults).

**A long-lived blocker can survive simply because the investigation stayed in the layer where the
evidence expires.** State and config persist; log lines rotate.

---

## Family 4 — alerts that train you to ignore them

### An alert that is critical most of the time is telling you about itself

A CPU guard fired `critical` on **65 of 73 runs in one day** — 89% — while the box was healthy. Its
threshold was `steal > 0`, but on a shared hypervisor some steal is the permanent baseline.

That alert is precisely the machine that trains "these are just noise" — and that conclusion is what
caused a *different*, real message to go unread for 55 minutes.

**The check:** before acting on any alert, count how often it has fired recently. Then fix the
threshold — that **is** fixing the failure mode.

### An alert whose prescribed remedy you'd never take is already broken

The same guard reported `dominant_slice: system.slice` on every fire, while its own runbook said
system.slice means production and *"needs a real fix, not a cap — never throttle production."* It
raised an emergency, pointed at production, and forbade the only lever it named.

**If no reachable action follows from an alert firing, it is not actionable and should not be
critical.**

### An alert with no entity id in its payload is unactionable — and that's why it survives

`whatsapp.session_token.request_rejected` fired hourly, exactly 3600s apart, zero recoveries, **for
28 days**. The payload was `{"path":…,"status":401}` — no account id, no user id. A reader could not
have fixed it even if they saw it.

And the 395 log lines were **one account**. One stuck row, not a storm.

**The check:** when triaging any long-lived alert, ask whether its payload names the thing that is
broken. If not, **that omission is the primary defect — fix it before the symptom.**

Sibling of the above: an alert you *cannot* act on and an alert you *would not* act on both decay
into noise.

### Triage by consecutive repeats, not by severity

A census of one alert channel found **307 RECOVERED against 361 incidents** — mostly flap pairs. In
that channel a P2 repeating 31 times outranked a P1 that recovered in ninety seconds.

**The check:** compare each incident name's count against its recovery count. Roughly equal means
flapping — that's the floor. Incidents materially exceeding recoveries means something is genuinely
still down.

### When you re-measure something you wrote off, amend the note in the same pass

That CPU guard was eventually recalibrated to a sane threshold: 1,009 fires, only 78 critical (7.7%).
The memory entry saying "this alert is noise" then became the hazard it warned about — left
unamended, it would have had the agent dismiss a *working* alert for months.

**A stale dismissal is indistinguishable from an informed one.**

---

## Family 5 — scoped narrower than reality

### A hardcoded list decays; enumerate instead

A monitor scanning 3 repositories reported "zero open PRs" while five were open elsewhere. The fix
was a hardcoded list of 7. That list then reported **37 open when 41 were open** — and one of the
four it couldn't see was the exact durable fix for an earlier incident, sitting untouched for 34
days.

**A list of names is a snapshot; the fleet is a query.**

```bash
for r in $(gh repo list ORG --limit 100 --json name,isArchived \
            --jq '.[]|select(.isArchived|not)|.name'); do ...
```

### Lazily-computed fields need a second query

A cold query returned `24 UNKNOWN / 8 UNSTABLE / 4 CLEAN`. Re-running seconds later gave the truth:
`15 CLEAN / 13 DIRTY / 9 UNSTABLE`. **A number from a tool still computing is not data** — same
family as the `vmstat` snapshot and the `docker ps` timeout.

### Paginated APIs cap silently

`--json files` on a large PR caps at 100 and the migrations fall off the end — making a test failure
look like it was failing on the base branch. Paginate whenever the list matters.

### A 404 on a versioned API: check the body type before blaming the resource

| version | HTTP | body | meaning |
|---|---|---|---|
| v21 | 404 | **HTML** | endpoint doesn't exist — version retired |
| v22 | 401 | **JSON** | live API, just unauthenticated |

**An HTML 404 means you're off the API surface entirely; a JSON error means the API answered you.**
Compare against a neighbouring version before concluding a resource was deleted. Also check the auth
binary exists at all — in one case the CLI the script shelled out to wasn't installed on the box, so
fixing only the version would have left it just as dead.

### Never `head` a search used to rule something out

`grep -iE 'oom|kill|tar|backup' | head -15` was used to conclude "not an OOM". **`tar` matches
"S-tar-ting"** — it hit 82 systemd `Starting…` lines and `head` truncated away the answer. A filter
used to rule something *out* must be exhaustive, or it proves nothing.

---

## The five controls that actually work

After an unusually bad shift — five narrow reads reported as complete ones, with new rules written
into memory between them that didn't prevent the next — these were what held. They're mechanical and
take seconds:

1. **Prefer the authoritative counter to a grep.**
2. **Group by distinct entity before believing any count.**
3. **Enumerate the categories before trusting the one you came for.**
4. **Never `head` a search used to rule something out.**
5. **Re-run the query scoped to the window the reader will use, before the number goes outward.**

---

## Contributing an entry

The most valuable PR to this repo is a new entry here. The shape that makes one useful:

- **What you saw** — the reading that looked fine, or the number you reported
- **What was true** — and how much the two differed
- **Why it was invisible** — the mechanism, not just "I wasn't careful"
- **The check** — something runnable that would have caught it

Entries that generalise beyond one stack are the best ones. "Silence is only recovery if you're still
calling" applies to a payment vendor, a queue consumer, and an agent's own heartbeat alike.
