---
description: Check that plan-council can run here - scripts parse, config loads, planners are installed, and each pinned model is the one that actually answers.
argument-hint: [--root <context-dir>] [--no-model-check]
---

Run the plan-council self-check: $ARGUMENTS

1. Locate the scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/` (if that does not resolve, find `council-doctor.sh` with Glob under `~/.claude/plugins/`).
2. Run `sh "<scripts>/council-doctor.sh" $ARGUMENTS` and show the output as it is.
3. For every `FAIL` line, say in one sentence what to do. In particular:
   - Codex not installed: switch to two Claude models (`COUNCIL_PLANNERS="claude claude_alt"` in `<root>/.claude/plan-council.conf`; see the README).
   - A model probe that reports a different ID than requested: the pinned model is not the one running. Do not proceed with the council until it is resolved.
4. Do not change any configuration yourself unless the user asks.
