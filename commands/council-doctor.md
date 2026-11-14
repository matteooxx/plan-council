---
description: Check that plan-council can run here - scripts parse, config loads, planners are installed, and each pinned model is the one that actually answers.
argument-hint: "[--root <context-dir>] [--no-model-check]"
---

Run the plan-council self-check: $ARGUMENTS

1. Locate the scripts, and **check which copy you found**. A Glob for `council-doctor.sh` under `~/.claude/plugins/` can return several hits: the installed version under `cache/plan-council/plan-council/<version>/scripts/`, the marketplace clone under `marketplaces/plan-council/scripts/`, and **every older version still sitting in the cache**. Measured 2026-11-14: three copies, one of them a previous release. Running the wrong copy runs old code and says nothing about it.
   - Prefer the installed version. `claude plugin details plan-council` prints it on its first line; use `~/.claude/plugins/cache/plan-council/plan-council/<that version>/scripts/`.
   - Failing that, take the **highest** version directory, never a lower one, and say which copy you chose.
   - If the user works in a clone of the repository, its own `scripts/` is equally valid but can differ from the installed copy — ask which they want.
   - Do not rely on `${CLAUDE_PLUGIN_ROOT}`: it is unset in a plugin session, and in a POSIX shell on Windows the unresolved reference becomes a path inside the Git installation instead of an error. If it does resolve to a directory that exists, it is fine to use. Do not copy or rewrite the script.
   Run it with `sh`, and do not assume the user's OS or shell: on Windows, PowerShell and cmd have no `sh` on `PATH` and need the full path to Git's launcher (`<git-root>\bin\sh.exe`, never `usr\bin\sh.exe`, which cannot find `dirname` when started from PowerShell).
2. Run `sh "<scripts>/council-doctor.sh" $ARGUMENTS` and show the output as it is.
3. For every `FAIL` line, say in one sentence what to do. In particular:
   - Codex not installed: switch to two Claude models (`COUNCIL_PLANNERS="claude claude_alt"` in `<root>/.claude/plan-council.conf`; see the README).
   - A model probe that reports a different ID than requested: the pinned model is not the one running. Do not proceed with the council until it is resolved.
4. Do not change any configuration yourself unless the user asks.
