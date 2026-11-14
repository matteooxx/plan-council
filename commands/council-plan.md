---
description: Blind parallel planning - every configured planner writes its own plan for the same brief, at the same time, without seeing the others.
argument-hint: <brief.md> [--root <context-dir>]
---

Run the plan-council planning phase for: $ARGUMENTS

1. Locate the plugin's scripts. They are in `${CLAUDE_PLUGIN_ROOT}/scripts/`. If that path does not resolve in your shell, find `council-plan.sh` with Glob under `~/.claude/plugins/` and use that directory. Do not copy or rewrite the script.
2. Settle the **context root** before running anything. It must be the directory that contains everything a planner needs to read: the code *and* the working material around it (notes, earlier plans). If the code sits in a subdirectory and the notes beside it, the root is the parent. Pass it with `--root`. If the user did not say and it is not obvious, ask. A planner started from too narrow a root cannot see what it needs, and the refusal is silent.
3. Confirm the brief file exists and is not empty. If the user gave the brief inline instead of a file, write it to `<root>/.council/brief-<short-name>.md` first.
4. Run, in the background (it takes several minutes and several strong-model runs):
   `sh "<scripts>/council-plan.sh" <brief> --root <root>`
5. When it finishes, check it yourself, don't just trust the exit code: the run directory it printed must contain one non-empty `plan-<letter>.md` per planner. Read the last lines of `logs/` for any planner that failed.
6. Report: the run directory, the planner-to-letter mapping from `council.txt`, and the size of each plan. Do **not** summarise or compare the plans yet, and do not tell the user which you prefer: that is the arbiter's job, after the cross-attack. Suggest `/council-review <run-dir>` as the next step.
