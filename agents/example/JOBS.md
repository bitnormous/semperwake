# JOBS.md — scheduled procedures

A producer starts one of these by adding a line to the event queue:

    {"kind":"job","job":"daily-summary","prompt_file":"/workspace/JOBS.md","prompt_anchor":"daily-summary"}

## daily-summary

Summarize what changed since the last run and report it with `scripts/notify.sh`.
