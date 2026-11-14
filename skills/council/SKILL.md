---
name: council
description: Plan a significant change with a council of rival models - blind parallel plans, a parallel cross-attack, a read-only arbiter that verifies in the code, and a risk-based assignment of every task to an executor and model. Use when the user asks for a council, rival or competing plans, a second model's plan, or a plan for a change where a wrong design is expensive (schema, migrations, security, data pipelines, multi-file refactors). Not for small or easily reversed changes.
---

# The council method

The value of this method is **disagreement between models**, not parallelism. Two planners that agree because they read the same opinion have produced nothing. Every rule below protects independent disagreement, then forces it to be checked against the code.

It costs several strong-model runs per plan: with N planners, **2N + 1** long runs, plus one for the assignment. Two levers change that bill without changing the method. `--effort` sets how long each model reasons and is chosen **per phase** (`COUNCIL_PLANNER_EFFORT`, `COUNCIL_ATTACK_EFFORT`, `COUNCIL_ARBITER_EFFORT`, `COUNCIL_ASSIGN_EFFORT`) — pay for arbitration, save on assignment. `COUNCIL_BUDGET_USD` caps each child run outright, at the price that a run which hits the cap stops instead of finishing. Codex takes neither flag. Say the cost before starting, and do not use the method when:

- the change is small, local, or cheap to undo;
- a test suite will catch a wrong design quickly anyway;
- there is only one reasonable approach. Two plans then just agree at twice the price.

## Before the first run: assume nothing about the machine

A fresh install knows none of what it needs, and two deductions have already
produced advice that simply failed:

- **The operating system and the shell.** The scripts are POSIX `sh` and run on
  Windows, macOS and Linux, but what the user must type differs. On Windows,
  PowerShell and cmd have no `sh` on `PATH`; they need Git's launcher at
  `<git-root>\bin\sh.exe` (not `usr\bin\sh.exe`, which cannot find `dirname`
  when started from PowerShell), and plain `bash` there is usually WSL, whose
  path translation mangles Windows paths in silence. Ask which shell the user
  types into; the shell you run tools in is not necessarily theirs.
- **The models.** Which Claude models an account has, and whether Codex is
  connected, differ per user. The shipped config names Opus because that is
  the broadest entitlement, not because it is the best model available. An
  account may have Claude Fable, which is more capable and costs more.

`/council-setup` asks all of it, offers `scripts/council-detect.sh` for
whatever the user does not know, and writes the answers to
`<root>/.claude/plan-council.conf`. It asks what to build **last**, after the
setup is settled. Run it before the first council on a machine.

## The phases and their commands

| Phase | Command | What runs |
|---|---|---|
| 0a. Set up, once per machine or project | `/council-setup` | asks, then `scripts/council-detect.sh` |
| 0b. Check the setup (after upgrades) | `/council-doctor` | `scripts/council-doctor.sh` |
| 1. Blind parallel planning | `/council-plan <brief> --root <dir>` | `scripts/council-plan.sh` |
| 2. Cross-attack, then arbitration | `/council-review <run-dir>` | `scripts/council-review.sh` |
| 3. The final plan | you write `final-plan.md` from the arbitration | nobody approves their own writing |
| 4. Risk-based assignment | `/council-assign <final-plan>` | `scripts/council-assign.sh` |
| 5. Execution | the `execution-discipline` skill | the executor agents |

The planners, attackers and arbiter run as **child CLI processes** started by the scripts, never as in-session subagents. Reasons: Codex and other providers are not Claude subagents; a child process takes an exact model ID while the in-session dispatch may take only a family alias; and the arbiter's lack of write access is set by the CLI's tool flags, by construction, not by asking it nicely.

## 1. Blind parallel planning

- **Write a brief**, a Markdown file: the goal, the constraints, what is out of scope, and where the relevant material is. Do not include your own preferred solution. A brief that leans toward one answer gets two plans that lean the same way.
- **Choose the context root** carefully. It is the directory every planner starts in, and the one its relative paths resolve against. It must hold the code *and* the surrounding working material: notes, earlier plans, prior council runs. If the code is in `<your-project>/app` and the notes in `<your-project>/docs`, the root is `<your-project>`. A planner with less context than its rival loses for the wrong reason.
- **The root is not a boundary.** Measured 2026-11-14: a read-only child agent read an absolute path outside the root with no refusal at all. Earlier versions of this file claimed such a read was refused silently; that was wrong. What must stay unreadable is denied by an explicit rule, which the scripts build for the run directory and pass to each child as `$COUNCIL_DENY`. The rule is a Claude Code permission rule, so it does not reach a planner driven by another CLI such as Codex; `/council-doctor` names any function it cannot cover.
- The script builds **one prompt** and gives every planner the same bytes. The output path is not in the prompt: each answer is captured to a temporary directory outside the root and published only after every planner has finished, so no planner can read a rival's half-written plan.
- The prompt tells each planner a rival is working in parallel, and what follows: write what you believe and say why; declare choices as choices; a plan that hides its choices loses even when right; do not widen the scope.
- Plans are published as `plan-A.md`, `plan-B.md`, ... The mapping to planners is in `council.txt`. Do not tell the arbiter which is which.
- After the run, **look**: one non-empty plan per planner. An exit code of 0 with an empty plan is the commonest silent failure; the script treats it as one, but check.

Do not summarise, rank or compare the plans for the user at this point. Your opinion, read by the arbiter or by the user before the arbiter, is the contamination this method exists to avoid.

## 2. The cross-attack

Each planner reads all plans and attacks the others', with its own model. **The attacks run in parallel, never in sequence**: a critic who has read the other's attack inherits its targets.

Each attack has fixed sections:

1. Where the other plan is right and mine is wrong. First, without hedging. A critique that concedes nothing is not believed.
2. What is wrong in the other plan, why, and the fix, with `path:line` where checked in the code.
3. Differences that are choices, not errors, and the price of each road. The arbiter needs this section most.
4. What is worth keeping from my plan.
5. What was measured or read versus what was inferred.
6. One word: `OWN`, the rival's letter, or `THIRD`.

## 3. The arbiter

A third model decides, with **no edit or write tool**. Its answer goes to stdout and the script saves it. It must verify in the code the claims its decisions depend on, opening the cited line, not trusting the more eloquent attack. Its report has numbered decisions, explicit **take-from-each-plan lists**, the questions **left for the human** with what each alternative changes, the **assumptions it verified itself, with the command and its result**, and one word: `PASS`, `FIX` or `RETHINK`.

Then:

- Bring every "left for the human" question to the user. Do not answer them yourself.
- **Whoever writes never approves.** You (or a planner with write access) write `final-plan.md` by following the take-lists exactly; the arbiter does not write it, and you do not approve it. For a second look, dispatch the `reviewer` agent.
- `RETHINK` means plan again with a better brief, not patch the better of two bad plans.

## 4. Risk-based assignment

Every task goes to an executor agent with a pinned model. The justification is **never "this is complex"**. It answers two questions:

- **If it comes back wrong, how expensive is it to notice?** Cheap (a test goes red, a grep finds nothing) means the task may go to a cheaper model.
- **If the error goes unnoticed, what happens?** If the answer touches data integrity, silent data loss, security or production, the task **does not go below the risk floor**, however simple it looks.

**Never give success percentages.** Nobody measured them; a made-up number is worse than an explicit criterion. If asked for them, decline and give the criterion.

The default roster (the plugin's agents; models in their frontmatter):

| Agent | Tools | For |
|---|---|---|
| `scout` | Read, Glob, Grep. No shell. | reconnaissance and listing, cheapest model |
| `worker` | read, edit, shell | mechanical, well-specified edits whose errors are cheap to notice |
| `implementer` | read, edit, shell | schema, migrations, security, data integrity, multi-file design. **The default risk floor.** |
| `reviewer` | read, shell; no editor | review of every significant delivery, never by the agent that wrote it |

The floor is `COUNCIL_RISK_FLOOR` in the config.

## Adding or swapping planners

Planners are shell functions in the config (`config/council.conf`, overridable per project at `<root>/.claude/plan-council.conf`). Claude and Codex work out of the box. Without Codex, set `COUNCIL_PLANNERS="claude claude_alt"`: two **different** Claude models. Any other CLI agent is one function that reads the prompt on stdin and makes its answer land in the file named by `$1`. See the README.
