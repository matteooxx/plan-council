---
description: Check that plan-council can run here - scripts parse, config loads, planners are installed, and each pinned model is the one that actually answers.
argument-hint: "[--root <context-dir>] [--no-model-check]"
---

Run the plan-council self-check: $ARGUMENTS

1. Locate the scripts: find `council-doctor.sh` with Glob under `~/.claude/plugins/` and use that directory. Do not rely on `${CLAUDE_PLUGIN_ROOT}` — it is unset in a plugin session, and in a POSIX shell on Windows the unresolved reference becomes a path inside the Git installation instead of an error. If it does resolve to a directory that exists, it is fine to use.
   Run the script with `sh`. Do not assume the user's OS or shell: on Windows, PowerShell and cmd have no `sh` on `PATH` and need the full path to Git's launcher (`<git-root>\bin\sh.exe`, never `usr\bin\sh.exe`, which cannot find `dirname` when started from PowerShell). `council-detect.sh` prints the right form for each shell.
2. Run `sh "<scripts>/council-doctor.sh" $ARGUMENTS` and show the output as it is.
3. For every `FAIL` line, say in one sentence what to do. In particular:
   - Codex not installed: switch to two Claude models (`COUNCIL_PLANNERS="claude claude_alt"` in `<root>/.claude/plan-council.conf`; see the README).
   - A model probe that reports a different ID than requested: the pinned model is not the one running. Do not proceed with the council until it is resolved.
4. Do not change any configuration yourself unless the user asks.
