---
description: Cross-attack in parallel, then a read-only arbiter decides, verifying claims in the code.
argument-hint: "<run-dir> [--arbitrate-only] [--no-seat-check]"
---

Run the plan-council review phase for: $ARGUMENTS

1. Locate the scripts, and **check which copy you found**. A Glob for `council-review.sh` under `~/.claude/plugins/` can return several hits: the installed version under `cache/plan-council/plan-council/<version>/scripts/`, the marketplace clone under `marketplaces/plan-council/scripts/`, and **every older version still sitting in the cache**. Measured 2026-11-14: three copies, one of them a previous release. Running the wrong copy runs old code and says nothing about it.
   - Prefer the installed version. `claude plugin details plan-council` prints it on its first line; use `~/.claude/plugins/cache/plan-council/plan-council/<that version>/scripts/`.
   - Failing that, take the **highest** version directory, never a lower one, and say which copy you chose.
   - If the user works in a clone of the repository, its own `scripts/` is equally valid but can differ from the installed copy — ask which they want.
   - Do not rely on `${CLAUDE_PLUGIN_ROOT}`: it is unset in a plugin session, and in a POSIX shell on Windows the unresolved reference becomes a path inside the Git installation instead of an error. If it does resolve to a directory that exists, it is fine to use. Do not copy or rewrite the script.
   Run it with `sh`, and do not assume the user's OS or shell: on Windows, PowerShell and cmd have no `sh` on `PATH` and need the full path to Git's launcher (`<git-root>\bin\sh.exe`, never `usr\bin\sh.exe`, which cannot find `dirname` when started from PowerShell).
2. Run, in the background:
   `sh "<scripts>/council-review.sh" <run-dir>`
   Each planner attacks the other plans with its own model, all at once; then the arbiter runs with no edit or write tool and no shell, and its report lands in `<run-dir>/arbitration.md`. If only the arbiter failed, rerun with `--arbitrate-only`. If the arguments include `--no-seat-check`, pass it on: it skips the seat check, which calls each Claude seat once before each phase to confirm that a read of the run directory is refused and that no shell was detected, and `council.txt` then records `skipped`.
   Before each phase starts its seats it prints a line beginning `plan-council: staging directory`, ending with the directory where that phase's answers are written as `answer-*.md`: twice in all, with the same path. Note it. If the run never returns, copy `answer-*.md` out of that directory **before** you kill it: the script deletes the directory when it exits, and a kill can make it exit, taking the answers with it (see "A run that does not return" in the README). If it stops in the arbitration, the attacks are already in `<run-dir>` as `attack-<letter>.md` and the answer to copy is the arbiter's, `answer-arbiter.md`. Then end it with `/usr/bin/kill -f` on Windows.
3. Check the run yourself: one non-empty `attack-<letter>.md` per plan and a non-empty `arbitration.md`. Read the arbitration in full.
4. Report to the user: the verdict (PASS, FIX or RETHINK), the numbered decisions in one line each, and **every item in "Left for the human"** with its alternatives. Do not resolve those for them.
5. Then, if the verdict is PASS or FIX and the user has settled the open questions, write the final plan to `<run-dir>/final-plan.md`, following the arbiter's "Take from each plan" lists exactly. You are writing it, so you do not approve it: if the user wants a check, dispatch the `reviewer` agent on it. If the verdict is RETHINK, say so and propose a revised brief instead of writing a plan.
6. Suggest `/council-assign <run-dir>/final-plan.md` as the next step.
