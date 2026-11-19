---
description: First-run setup. Establishes the OS and shell, asks how the models should be chosen -- a mode for the situation, with a ranking the user confirms, or by hand, with how deep each phase should think -- checks what this machine actually has when the user does not know, writes the project config, and only then asks what to plan.
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
  account may have more models than the default names, Claude Fable among
  them, and they cost differently.

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
  one one-word call per candidate model, one for the guard check, and, if
  Codex is logged in, one Codex call asking for one word, made with the model
  and reasoning effort in the user's own Codex config (it can be `xhigh`), to
  read what its banner announces: say so first, since each costs a little and
  the Codex one costs more the higher its effort is set.
- **They know** — take their answers, and still run it with
  `--no-model-check` so the OS, tools and roster are not guessed.

Read the machine-readable summary at the end. Report what was found in plain
terms, including anything that failed.

- If `CLAUDE_INSTALLED=no`, stop: nothing else matters until it is installed.
- `DENY_RULE_EFFECTIVE` is the verdict for the layout the plugin permits: a
  run directory git ignores and tracks nothing in. The refused layout is
  probed too and printed above the summary, but it does not change this value.
- If `DENY_RULE_EFFECTIVE=no`, say plainly that the arbiter cannot be kept from
  reading which planner wrote which plan on this machine, so that blindness
  rests on the prompt alone. Let the user decide whether to continue.
- If `DENY_RULE_EFFECTIVE=untested`, say that the check could not establish
  whether the rule holds: neither that it does nor that it does not. It is not
  a pass, and must not be reported as one.
- If `CODEX=no` or `absent`, the second planner must be another Claude model.

## 4. Which models

Explain the one rule that matters before asking: **disagreement is the
product.** Two planners on the same model produce two plans that agree, at
twice the price.

State the cost difference honestly. Per million tokens: Claude Fable 5.2 is
$8 in / $40 out; Claude Opus 5.5 is $4 / $20; Claude Sonnet 5.5 is $2 / $10;
Claude Haiku 5.5 is $0.10 / $0.50. Fable 5.2 costs about twice Opus 5.5 per
token. These are prices, not a measurement of which model plans or judges
better, and nothing in the plugin has measured that. If the user is on a
subscription rather than API billing, say these figures are the scale, not a
bill.

Then ask how the models should be chosen:

- **A mode.** One question about the situation sets how deep each phase thinks
  and which seat takes the first model on a list the user ranks. The modes are
  the files in `config/modes/` under the plugin directory, the directory above
  the scripts found in section 2. Read each file's header and relay its
  `# Sets:`, `# Promises:` and `# Does not protect against:` blocks as written,
  naming the mode by the situation on its first line.
- **By hand.** No mode and no list: the user names the model for each seat.

**On the mode path, say this plainly before anything is ranked: the order the
user confirms is their own ranking, not a benchmark.** The probe measured only
which model IDs answer; nothing measured which one plans or judges better. A
mode deals the seats by position on that list and compares nothing else, and
the list is only as current as the date written with it.

**The mode path, in this order.**

0. **Ask which situation they are in**, unless the user already chose one
   when the modes were offered above. Otherwise relay each mode file's header
   in the same way and ask which situation fits. `<mode>` is the chosen
   file's name without `.conf`.
1. **Show what the probe found, in its order.** If the probe was skipped
   (`PROBED_ON=skipped`), there is nothing to rank: offer to run it now, as
   described in section 3, or take the by-hand path. Otherwise list
   `MODELS_AVAILABLE` from the summary of section 3 exactly in the order
   printed, then every model in `MODELS_NOT_ANSWERING` with what the probe
   printed for it (`NOT available` or `MISMATCH`). The order is the probe's
   own list, `PROBE_MODELS` in `council-detect.sh`, which by default is the
   per-token price above, highest first; say so, and do not present it as a
   judgement. Ask the user to confirm the order, reorder it, or drop models.
   The result, first rung first, is the ladder. Write it as the IDs separated
   by single spaces. Put on it only models that answered.
2. **Codex, if `CODEX=yes`.** State the model its banner announced,
   `CODEX_MODEL` (what Codex was asked for, not proof of what served; it may
   be `unknown`), and its announced effort, `CODEX_EFFORT`, which a mode's
   depth does not change. Say that Codex **cannot be ranked**: it takes a
   planner seat but never a rung, so it is not on the ladder and the ladder
   says nothing about it. Ask whether to seat it, as in
   `COUNCIL_PLANNERS="claude codex"`, or to use a second Claude model, as in
   `COUNCIL_PLANNERS="claude claude_alt"`. If it is seated and `CODEX_MODEL`
   is not `unknown`, offer to pin `COUNCIL_MODEL_CODEX` to that model: with
   the pin the plugin passes it to Codex as `-m`, without it Codex runs
   whatever its own config names on the day. The pin is the user's choice,
   not a requirement. Without Codex, the planners are `claude claude_alt`.
   Under a mode no other planner name can be seated.
3. **Show the deal by running the doctor, never by working it out.** Run this
   yourself, with `<plugin>` the directory above the scripts found in
   section 2 and `<PROBED_ON>` the date from the same summary:

   ```sh
   COUNCIL_CONFIG="<plugin>/config/council.conf" \
   COUNCIL_MODE="<mode>" \
   COUNCIL_MODEL_LADDER="<ladder>" \
   COUNCIL_MODEL_LADDER_DATE="<PROBED_ON>" \
   COUNCIL_PLANNERS="<planners>" \
   sh "<plugin>/scripts/council-doctor.sh" --root "<root>" --no-model-check
   ```

   `COUNCIL_CONFIG` must point at the plugin's own config. Without it the
   doctor loads `<root>/.claude/plan-council.conf` when that exists, and the
   seat lines of an older project config fill seats before the deal, which
   then shows them as `(kept)`: the deal shown would not be the deal the new
   config makes. An exported value survives the config, so nothing has to be
   written first.

   Show the user the seats as the output prints them: the load's own line,
   `plan-council: mode <mode> seats: ...`, and the doctor's line under
   `Config`, `seats dealt by mode <mode>: ...; ladder dated <PROBED_ON>`.
   Because `COUNCIL_CONFIG` is set, the same section says `the config is one
   you chose` and names the plugin's config as loaded: that describes this
   preview, not the user's project. Other `FAIL` lines are about this
   machine, not the deal; report them, and fix them in section 7.
4. **On a refusal, relay the message.** A refusal is a line starting
   `plan-council: error:`, with no seats line after it. Quote it as printed,
   then offer three exits:
   - **Pin that seat by hand.** A seat that already holds a model keeps it
     and takes no rung. Offer only a model that answered. Before offering any
     pin, run the command in step 3 with the pin added (for example
     `COUNCIL_MODEL_CLAUDE_ALT="<id>"`) and offer it only if the seats line
     comes back. Do not decide this by reading the ladder: a pinned seat does
     not take its model out of the ladder, so the other seats still take it
     from the top, and a pin that looks free can put both Claude planners on
     one model, which the plugin refuses.
   - **Go by hand entirely**: the by-hand path below, with no mode.
   - **Stop**, writing nothing.
5. **What to write.** In section 7's file, above the line that sources the
   plugin's config, write the mode, the planners, the ladder and its date:

   ```sh
   COUNCIL_MODE="${COUNCIL_MODE-<mode>}"
   COUNCIL_PLANNERS="${COUNCIL_PLANNERS:-<planners>}"
   COUNCIL_MODEL_LADDER="${COUNCIL_MODEL_LADDER:-<ladder>}"
   COUNCIL_MODEL_LADDER_DATE="${COUNCIL_MODEL_LADDER_DATE:-<PROBED_ON>}"
   ```

   `COUNCIL_MODE` has no colon because its empty value means "no mode". Write
   **no seat line** except one for each seat the user pinned, including
   `COUNCIL_MODEL_CODEX` if they took the pin offered in step 2, in the form
   section 7 gives for it. A Claude seat line written anyway
   (`COUNCIL_MODEL_CLAUDE`, `COUNCIL_MODEL_CLAUDE_ALT` or
   `COUNCIL_MODEL_ARBITER`) fills its seat before the deal, which then skips
   it; the deal never touches `COUNCIL_MODEL_CODEX`. Skip section 5, "How
   deep each phase should think", entirely, and leave out section 7's four
   effort lines: the mode sets the efforts, and an effort line in the project
   config would override it. The cap in section 6 still applies.

**The by-hand path.** No mode and no ladder. Then ask:

- **Planner A and planner B.** Offer only what the probe found available. If
  Codex is connected, it can be the second planner: a different vendor, not
  merely a different model. If it is not, use two different Claude models
  (`COUNCIL_PLANNERS="claude claude_alt"`).
- **The arbiter.** Prefer a model that is neither planner, and say why: by
  default the arbiter is the same model as a planner, and although it is never
  told which plan is whose, a model that may be judging its own work is a
  weaker check than one that cannot be.

## 5. How deep each phase should think

On the mode path, skip this section. The mode has set the four efforts, and
the doctor's `effort:` line in step 3 of section 4 shows them.

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
means no cap, which is the shipped default: nothing is capped unless asked for.

Say as well that a cap is **not a one-way door**, because a user who declines
one for fear of being stuck with it has been told the wrong thing. It can be
lifted for good by editing the one line, and for a single run by exporting an
empty value:

```sh
COUNCIL_BUDGET_USD= council-plan.sh brief.md --root .
```

If the user says cost is not a concern, write no cap and say so plainly rather
than writing a large number, which only looks like a limit.

## 7. Write the config

Write `<root>/.claude/plan-council.conf`. It is a **small delta**, not a copy:
it sets what the user chose and then sources the plugin's config, inheriting
every planner function. Copying the whole file is how a plain assignment
spreads, and a plain assignment silently overrides an exported value.

Every line uses the `${VAR:-...}` form, except the colon-less lines noted
below, so an exported value still wins for a single run. The scripts now
refuse to start when a config overrides an exported value, so a plain
assignment here would break those runs.

```sh
# plan-council, written by /council-setup on <date>.
# A delta over the plugin's config: set what was chosen, inherit the rest.
COUNCIL_PLANNERS="${COUNCIL_PLANNERS:-<chosen planners>}"
COUNCIL_MODEL_CLAUDE="${COUNCIL_MODEL_CLAUDE:-<chosen>}"
COUNCIL_MODEL_CLAUDE_ALT="${COUNCIL_MODEL_CLAUDE_ALT:-<chosen>}"
COUNCIL_MODEL_ARBITER="${COUNCIL_MODEL_ARBITER:-<chosen>}"
COUNCIL_MODEL_CODEX="${COUNCIL_MODEL_CODEX-<chosen or empty>}"
COUNCIL_PLANNER_EFFORT="${COUNCIL_PLANNER_EFFORT:-<chosen>}"
COUNCIL_ATTACK_EFFORT="${COUNCIL_ATTACK_EFFORT:-<chosen>}"
COUNCIL_ARBITER_EFFORT="${COUNCIL_ARBITER_EFFORT:-<chosen>}"
COUNCIL_ASSIGN_EFFORT="${COUNCIL_ASSIGN_EFFORT:-<chosen>}"
COUNCIL_BUDGET_USD="${COUNCIL_BUDGET_USD-<chosen or empty>}"
COUNCIL_RISK_FLOOR="${COUNCIL_RISK_FLOOR:-implementer}"

. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
```

**On the mode path** the file instead holds the four lines from step 5 of
section 4, no effort lines, and a seat line only for each seat the user
pinned, `COUNCIL_MODEL_CODEX` included.
The `COUNCIL_BUDGET_USD` and `COUNCIL_RISK_FLOOR` lines and the `.` line that
sources the plugin's config stay as above.

**Note the lines without the colon.** `COUNCIL_BUDGET_USD`,
`COUNCIL_MODEL_CODEX`, `COUNCIL_AGENT_DIRS` and, on the mode path,
`COUNCIL_MODE` are the settings whose **empty value means something** — no
cap, Codex's own default model, no extra agent directories, no mode. With
`${VAR:-default}` an exported empty value counts as unset and
the default comes back, so a user who set a cap could never say "no cap for
this run": the run would instead refuse to start, reporting that the config
overrode the environment. Written with `${VAR-default}`, this works:

```sh
COUNCIL_BUDGET_USD= council-plan.sh brief.md --root .
```

Every other setting keeps `${VAR:-default}`.

If the chosen planner set needs a function the plugin does not ship, write it
into this file above the `.` line, keeping the contract in
`config/council.conf` exactly: prompt on stdin, answer into `$1`, read-only,
and `"$COUNCIL_DENY"` passed to the CLI. A function that drives `claude` must
also call `$(council_seat_flags)`, unquoted, on its command line, as the
shipped ones do: without it the function loads the host's settings, hooks and
connector tools, and answers a different question from the seats the plugin
ships.

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
  form that works in the shell they named in section 1.

If the change is small, local, cheap to undo, or has only one reasonable
approach, say so and recommend against a council. Two plans that agree are
worth less than one, and they cost more.
