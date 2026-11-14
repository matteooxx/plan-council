---
description: Assign every task of a final plan to an executor agent and model by risk, never by "complexity" and never with invented percentages.
argument-hint: "<final-plan.md> [--root <context-dir>]"
---

Produce the assignment table for: $ARGUMENTS

1. Locate the scripts, and **check which copy you found**. A Glob for `council-assign.sh` under `~/.claude/plugins/` can return several hits: the installed version under `cache/plan-council/plan-council/<version>/scripts/`, the marketplace clone under `marketplaces/plan-council/scripts/`, and **every older version still sitting in the cache**. Measured 2026-11-14: three copies, one of them a previous release. Running the wrong copy runs old code and says nothing about it.
   - Prefer the installed version. `claude plugin details plan-council` prints it on its first line; use `~/.claude/plugins/cache/plan-council/plan-council/<that version>/scripts/`.
   - Failing that, take the **highest** version directory, never a lower one, and say which copy you chose.
   - If the user works in a clone of the repository, its own `scripts/` is equally valid but can differ from the installed copy — ask which they want.
   - Do not rely on `${CLAUDE_PLUGIN_ROOT}`: it is unset in a plugin session, and in a POSIX shell on Windows the unresolved reference becomes a path inside the Git installation instead of an error. If it does resolve to a directory that exists, it is fine to use. Do not copy or rewrite the script.
   Run it with `sh`, and do not assume the user's OS or shell: on Windows, PowerShell and cmd have no `sh` on `PATH` and need the full path to Git's launcher (`<git-root>\bin\sh.exe`, never `usr\bin\sh.exe`, which cannot find `dirname` when started from PowerShell).
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
