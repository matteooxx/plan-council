---
description: Blind parallel planning - every configured planner writes its own plan for the same brief, at the same time, without seeing the others.
argument-hint: "<brief.md> [--root <context-dir>]"
---

Run the plan-council planning phase for: $ARGUMENTS

1. Locate the scripts, and **check which copy you found**. A Glob for `council-plan.sh` under `~/.claude/plugins/` can return several hits: the installed version under `cache/plan-council/plan-council/<version>/scripts/`, the marketplace clone under `marketplaces/plan-council/scripts/`, and **every older version still sitting in the cache**. Measured 2026-11-14: three copies, one of them a previous release. Running the wrong copy runs old code and says nothing about it.
   - Prefer the installed version. `claude plugin details plan-council` prints it on its first line; use `~/.claude/plugins/cache/plan-council/plan-council/<that version>/scripts/`.
   - Failing that, take the **highest** version directory, never a lower one, and say which copy you chose.
   - If the user works in a clone of the repository, its own `scripts/` is equally valid but can differ from the installed copy — ask which they want.
   - Do not rely on `${CLAUDE_PLUGIN_ROOT}`: it is unset in a plugin session, and in a POSIX shell on Windows the unresolved reference becomes a path inside the Git installation instead of an error. If it does resolve to a directory that exists, it is fine to use. Do not copy or rewrite the script.
   Run it with `sh`, and do not assume the user's OS or shell: on Windows, PowerShell and cmd have no `sh` on `PATH` and need the full path to Git's launcher (`<git-root>\bin\sh.exe`, never `usr\bin\sh.exe`, which cannot find `dirname` when started from PowerShell).
2. Settle the **context root** before running anything. It must be the directory that contains everything a planner needs to read: the code *and* the working material around it (notes, earlier plans). If the code sits in a subdirectory and the notes beside it, the root is the parent. Pass it with `--root`. If the user did not say and it is not obvious, ask. A planner started from too narrow a root cannot find by a relative path what it needs. The root is **not** a boundary, though: a child agent can read an absolute path outside it, so do not treat the root as a way to keep anything unreadable.
3. Confirm the brief file exists and is not empty. If the user gave the brief inline instead of a file, write it to `<root>/.council/brief-<short-name>.md` first.
4. Run, in the background (it takes several minutes and several strong-model runs):
   `sh "<scripts>/council-plan.sh" <brief> --root <root>`
5. When it finishes, check it yourself, don't just trust the exit code: the run directory it printed must contain one non-empty `plan-<letter>.md` per planner. Read the last lines of `logs/` for any planner that failed.
6. Report: the run directory, the planner-to-letter mapping from `council.txt`, and the size of each plan. Do **not** summarise or compare the plans yet, and do not tell the user which you prefer: that is the arbiter's job, after the cross-attack. Suggest `/council-review <run-dir>` as the next step.
