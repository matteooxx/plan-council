---
description: Cross-attack in parallel, then a read-only arbiter decides, verifying claims in the code.
argument-hint: "<run-dir> [--arbitrate-only]"
---

Run the plan-council review phase for: $ARGUMENTS

1. Locate the scripts: find `council-review.sh` with Glob under `~/.claude/plugins/` and use that directory. Do not rely on `${CLAUDE_PLUGIN_ROOT}` — it is unset in a plugin session, and in a POSIX shell on Windows the unresolved reference becomes a path inside the Git installation instead of an error. If it does resolve to a directory that exists, it is fine to use.
   Run it with `sh`, and do not assume the user's OS or shell: on Windows, PowerShell and cmd have no `sh` on `PATH` and need the full path to Git's launcher (`<git-root>\bin\sh.exe`, never `usr\bin\sh.exe`).
2. Run, in the background:
   `sh "<scripts>/council-review.sh" <run-dir>`
   Each planner attacks the other plans with its own model, all at once; then the arbiter runs with no edit or write tool and its report lands in `<run-dir>/arbitration.md`. If only the arbiter failed, rerun with `--arbitrate-only`.
3. Check the run yourself: one non-empty `attack-<letter>.md` per plan and a non-empty `arbitration.md`. Read the arbitration in full.
4. Report to the user: the verdict (PASS, FIX or RETHINK), the numbered decisions in one line each, and **every item in "Left for the human"** with its alternatives. Do not resolve those for them.
5. Then, if the verdict is PASS or FIX and the user has settled the open questions, write the final plan to `<run-dir>/final-plan.md`, following the arbiter's "Take from each plan" lists exactly. You are writing it, so you do not approve it: if the user wants a check, dispatch the `reviewer` agent on it. If the verdict is RETHINK, say so and propose a revised brief instead of writing a plan.
6. Suggest `/council-assign <run-dir>/final-plan.md` as the next step.
