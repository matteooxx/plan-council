---
description: First-run setup. Establishes the OS and shell, asks which models and how deep each phase should think, checks what this machine actually has when the user does not know, writes the project config, and only then asks what to plan.
argument-hint: "[--root <context-dir>]"
---

Set up plan-council for: $ARGUMENTS

A fresh install knows none of what it needs. The operating system, the shell
the user types into, which Claude models their account has, whether Codex is
connected, how deep each phase should think, and what a run may cost are all
per-user facts. **Do not infer any of them.**

Two deductions in particular have already produced broken advice and must not
be repeated:

- **Do not assume the operating system or the shell.** These scripts are POSIX
  `sh` and run on Windows, macOS and Linux, but the command the user has to
  type differs, and a command for the wrong shell simply fails. The shell *you*
  run tools in is not necessarily the shell *they* type into.
- **Do not pick a model.** The shipped config names Opus because that is the
  broadest entitlement, not because it is the best model available here. An
  account may have Claude Fable, which is more capable and costs more.

Ask in the order below. Keep each round short, and never ask about something a
check could settle without first offering the check.

## 1. Operating system and shell, before any command is suggested

Ask the user — do not deduce — which shell they will run these commands in,
offering what is plausible for their machine:

- **Windows**: PowerShell, cmd.exe, Git Bash / MSYS, or WSL.
- **macOS or Linux**: the default shell (`sh`, `bash`, `zsh` — all fine).

Then give the invocation for *that* answer and no other. The detection script
prints the right form for each shell on the detected OS; use its output rather
than writing a path from memory.

Facts that decide these forms, each measured on 2026-11-14:

- On Windows, **PowerShell and cmd have no `sh` on `PATH`**, so a bare
  `sh scripts/...` fails there. They need the full path to Git's launcher:
  `& "C:\Program Files\Git\bin\sh.exe" "scripts/council-plan.sh" ...`
- Use `<git-root>\bin\sh.exe`, **not** `<git-root>\usr\bin\sh.exe`. The second
  one inherits the caller's `PATH` and, started from PowerShell, cannot find
  `dirname`: the script dies on its second line.
- On Windows, plain `bash` is usually `C:\Windows\system32\bash.exe`, which is
  **WSL** — a different machine. Its path translation mangles Windows paths
  silently, so a run there can fail in ways that look like nothing at all.
- In WSL, the planner CLIs must be installed and logged in *inside* WSL;
  otherwise they are the Windows binaries reached through `/mnt/c`.
- On macOS and Linux, `sh scripts/council-plan.sh ...` is right as it stands.

## 2. Locate the scripts

`${CLAUDE_PLUGIN_ROOT}` is **not** reliable: it is unset in a plugin session,
and in a POSIX shell on Windows the unresolved reference becomes a path inside
the Git installation rather than an error. So:

1. Find `council-detect.sh` with Glob under `~/.claude/plugins/` and use that
   directory. If the user is working in a clone of the repository, its own
   `scripts/` directory is equally good — ask which, if both exist, because
   they can differ.
2. If `${CLAUDE_PLUGIN_ROOT}` does resolve to a directory that exists, it is
   fine to use. Verify it exists before relying on it.

## 3. Does the user know their own setup?

Ask: do they know which Claude models their account has and whether Codex is
connected, or should it be checked?

- **Check it** — offer this first, it is the safe answer. Run
  `council-detect.sh --root <root>` in the background. It reports the OS, the
  invocation for each shell, the required tools, the CLIs, Codex's login state,
  which models actually answer, the agent roster, and whether the rule that
  keeps the arbiter blind is honoured on this machine. The model probe makes
  one one-word call per candidate model plus one for the guard check: say so
  first, since it costs a little.
- **They know** — take their answers, and still run it with
  `--no-model-check` so the OS, tools and roster are not guessed.

Read the machine-readable summary at the end. Report what was found in plain
terms, including anything that failed.

- If `CLAUDE_INSTALLED=no`, stop: nothing else matters until it is installed.
- If `DENY_RULE_EFFECTIVE=no`, say plainly that the arbiter cannot be kept from
  reading which planner wrote which plan on this machine, so that blindness
  rests on the prompt alone. Let the user decide whether to continue.
- If `CODEX=no` or `absent`, the second planner must be another Claude model.

## 4. Which models

Explain the one rule that matters before asking: **disagreement is the
product.** Two planners on the same model produce two plans that agree, at
twice the price. Then ask:

- **Planner A and planner B.** Offer only what the probe found available. If
  Codex is connected it is the strongest second planner, because it is a
  different vendor and not merely a different model. If it is not, use two
  different Claude models (`COUNCIL_PLANNERS="claude claude_alt"`).
- **The arbiter.** Prefer a model that is neither planner, and say why: by
  default the arbiter is the same model as a planner, and although it is never
  told which plan is whose, a model that may be judging its own work is a
  weaker check than one that cannot be.

State the cost difference honestly. Per million tokens: Claude Fable 5.2 is
$8 in / $40 out; Claude Opus 5.5 is $4 / $20; Claude Sonnet 5.5 is $2 / $10;
Claude Haiku 5.5 is $0.10 / $0.50. Fable 5.2 is the most capable and costs
about twice Opus 5.5. If the probe found it, offer it for planning and say
what it adds and what it costs. If the user is on a subscription rather than
API billing, say these figures are the scale, not a bill.

## 5. How deep each phase should think

`--effort` sets how long a model reasons before answering, so it moves both
the bill and the wall clock. It is the main cost lever inside one model. Ask
per phase, and give this table rather than a vague "higher is better":

| Phase | What it does | Sensible range |
|---|---|---|
| Planning | writes the plan the whole run rests on | `high`, `xhigh` if the design is genuinely hard |
| Cross-attack | finds the other plan's real faults | `high`; `medium` only to save money on a small brief |
| Arbitration | decides, and verifies claims in the code | `high` or `xhigh`; this is the one to pay for |
| Assignment | fills a table from a finished plan | `medium`; `low` is usually enough |

Levels are `low`, `medium`, `high`, `xhigh`, `max`. Each level up means more
reasoning tokens, and reasoning bills as output, which is five times the input
rate. `max` is for when correctness matters more than cost; it is rarely the
right default for all four phases at once. **Codex takes no effort flag**, so
the setting does not reach it: its depth comes from its own model and config.
Say that rather than implying otherwise.

## 6. A spending cap

Ask whether to cap each child run with `--max-budget-usd`. Explain the shape
of the spend first: with N planners a council is **2N + 1** long model runs,
plus one for the assignment. With two planners that is five plus one. A cap of
2 therefore caps the Claude side of a two-planner council at about 8. Say the
real cost of a cap too: a run that hits it stops rather than finishing. Empty
means no cap, which is the current default.

## 7. Write the config

Write `<root>/.claude/plan-council.conf`. It is a **small delta**, not a copy:
it sets what the user chose and then sources the plugin's config, inheriting
every planner function. Copying the whole file is how a plain assignment
spreads, and a plain assignment silently overrides an exported value.

Every line uses the `${VAR:-...}` form so an exported value still wins for a
single run. The scripts now refuse to start when a config overrides an
exported value, so a plain assignment here would break those runs.

```sh
# plan-council, written by /council-setup on <date>.
# A delta over the plugin's config: set what was chosen, inherit the rest.
COUNCIL_PLANNERS="${COUNCIL_PLANNERS:-<chosen planners>}"
COUNCIL_MODEL_CLAUDE="${COUNCIL_MODEL_CLAUDE:-<chosen>}"
COUNCIL_MODEL_CLAUDE_ALT="${COUNCIL_MODEL_CLAUDE_ALT:-<chosen>}"
COUNCIL_MODEL_ARBITER="${COUNCIL_MODEL_ARBITER:-<chosen>}"
COUNCIL_MODEL_CODEX="${COUNCIL_MODEL_CODEX:-<chosen or empty>}"
COUNCIL_PLANNER_EFFORT="${COUNCIL_PLANNER_EFFORT:-<chosen>}"
COUNCIL_ATTACK_EFFORT="${COUNCIL_ATTACK_EFFORT:-<chosen>}"
COUNCIL_ARBITER_EFFORT="${COUNCIL_ARBITER_EFFORT:-<chosen>}"
COUNCIL_ASSIGN_EFFORT="${COUNCIL_ASSIGN_EFFORT:-<chosen>}"
COUNCIL_BUDGET_USD="${COUNCIL_BUDGET_USD:-<chosen or empty>}"
COUNCIL_RISK_FLOOR="${COUNCIL_RISK_FLOOR:-implementer}"

. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
```

If the chosen planner set needs a function the plugin does not ship, write it
into this file above the `.` line, keeping the contract in
`config/council.conf` exactly: prompt on stdin, answer into `$1`, read-only,
and `"$COUNCIL_DENY"` passed to the CLI.

Then run `council-doctor.sh --root <root> --no-model-check` and show the
result. It must load the new config and report the chosen planners. Fix
anything it reports before going on.

## 8. Only now, ask what to build

With the setup settled, ask what the user actually wants planned or reviewed,
and say in one line what a council will cost at the settings they just chose.
Then:

- Help them write the brief as a file: the goal, the constraints, what is out
  of scope, and where the material is. **Do not put a preferred solution in
  it** — a brief that leans toward one answer gets two plans that lean the
  same way.
- Settle the context root: the directory holding the code *and* the working
  material around it. Note that the root decides where each planner starts,
  not what it can reach: a child agent can read an absolute path outside the
  root, so the root is not a boundary.
- Hand off to `/council-plan <brief> --root <root>`, giving the command in the
  form that works in the shell they named in step 1.

If the change is small, local, cheap to undo, or has only one reasonable
approach, say so and recommend against a council. Two plans that agree are
worth less than one, and they cost more.
