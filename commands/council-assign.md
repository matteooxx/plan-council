---
description: Assign every task of a final plan to an executor agent and model by risk, never by "complexity" and never with invented percentages.
argument-hint: "<final-plan.md> [--root <context-dir>]"
---

Produce the assignment table for: $ARGUMENTS

1. Locate the scripts: find `council-assign.sh` with Glob under `~/.claude/plugins/` and use that directory. Do not rely on `${CLAUDE_PLUGIN_ROOT}` — it is unset in a plugin session, and in a POSIX shell on Windows the unresolved reference becomes a path inside the Git installation instead of an error. If it does resolve to a directory that exists, it is fine to use.
   Run it with `sh`, and do not assume the user's OS or shell: on Windows, PowerShell and cmd have no `sh` on `PATH` and need the full path to Git's launcher (`<git-root>\bin\sh.exe`, never `usr\bin\sh.exe`).
2. Use the same context root as the planning run (it is the `root=` line in the run's `council.txt`).
3. Run, in the background:
   `sh "<scripts>/council-assign.sh" <final-plan.md> --root <root>`
   The roster comes from the agents' frontmatter, so the models in the table are the ones the agents are pinned to.
4. Read the resulting `assignment.md` and check it against the rules before showing it:
   - every justification answers *how expensive is it to notice if this is wrong* and *what happens if it goes unnoticed*, not "complex" or "simple";
   - nothing touching data integrity, silent data loss, security or production is below the risk floor;
   - every writing task is followed by a review task on an agent with no write tool, never the same agent;
   - no success percentages anywhere.
   If any rule is broken, say which rows and fix the table yourself, marking what you changed.
5. Show the table to the user. Execution follows the `execution-discipline` skill.
