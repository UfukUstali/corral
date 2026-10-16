---
name: corral
description: Query, start, stop, or restart development tasks and read their logs through a human's running Corral instance.
---

Run `corral agent` commands from the same directory where the human launched
Corral. That directory identifies the instance, even when tasks live in
nested projects. Use `corral agent --help` for command options.

Start with `corral agent list`. Narrow it with `--name`, `--status`, `--state`,
or `--config`. Use a returned task `id` with `show`, `start`, `stop`, `restart`,
or `logs`. Exact names work when unique; `--config` resolves duplicate names.
Read bounded logs with `corral agent logs <id> --lines 100`.

Responses are JSON. Check `ok` and the command's exit status. Stop and restart
acknowledge a request; use `show` to check `state`, `status`, and
`restart_pending` before claiming completion. Logs are retained terminal
scrollback, including earlier runs, rather than a durable log archive.

If `instance_not_running` or `instance_unavailable` is returned, tell the human
and wait for them to start or restore Corral in that directory. Never launch
the TUI, a replacement daemon, or the task commands yourself. A timed-out
control command may already have taken effect; query state after the human
restores the connection before deciding whether to retry.
