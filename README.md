# plan-council

A Claude Code plugin that plans a change with a **council of rival models**
and then runs the plan under strict execution discipline:

1. Two or more planners (Claude and Codex by default) get **the same brief at
   the same time** and each writes its own plan **without seeing the other's**.
2. Each planner then **attacks the other's plan**, all at once, so no
   critic inherits another critic's targets.
3. A **read-only arbiter** decides, checking the cited code itself instead
   of believing the more convincing attack.
4. Every task in the final plan is **assigned to an executor and model by
   risk**: how expensive a wrong result is to notice, and what happens if it
   is not noticed. No invented success percentages.
5. Execution follows fixed rules: one writer at a time, the writer never
   approves, every test proven by a mutation, and no agent commits, pushes,
   deploys or touches production.

The value is **disagreement between models**, not parallelism. Two planners
that agree because they read the same opinion have produced nothing; the
plugin is built so that they cannot read each other, and so that every
disagreement is checked against the code.

## When it is worth the cost

A council run costs **several times a single plan**: with two planners,
that is two strong-model plans, two strong-model attacks and one arbitration.
That is five long runs where you would otherwise have one, plus the
assignment. It is worth it when a wrong design is expensive and slow to find
out:

- schema changes and data migrations;
- anything touching authentication, permissions or data deletion;
- a data pipeline whose wrong output would go unnoticed for weeks;
- a refactor across many modules where the first plan's choices constrain
  everything after.

It is **not** worth it when the change is small, local or easy to undo; when
a test suite will catch a bad design within minutes; or when there is only
one reasonable approach, because then two plans just agree at twice the price.
For those, plan once and use the execution discipline alone.

## Install

At the prompt of a Claude Code terminal session:

```
/plugin install plan-council --marketplace matteooxx/plan-council
```

Answer `y` to add the marketplace, then choose a scope (user scope makes it
available in every project). From a shell:

```
claude plugin install plan-council --marketplace matteooxx/plan-council
```

To try it from a local checkout without installing:

```
claude --plugin-dir ./plan-council
```

Then set it up, once:

```
/council-setup
```

**This matters more than it sounds.** A fresh install cannot know which Claude
models your account has, whether Codex is connected, what shell you type into,
or how deep you want each phase to think — and the shipped config names Opus
because that is the broadest entitlement, not because it is the best model
available to you. `/council-setup` asks, checks whatever you do not know, and
writes your answers to `<your-project>/.claude/plan-council.conf`. It asks what
you want to plan **last**. It can also set a **mode**, which deals the models
you rank yourself to the seats: see [Modes](#modes).

If you would rather just see what this machine has:

```
sh scripts/council-detect.sh
```

It reports your OS and the invocation for each shell on it, the required tools,
both planner CLIs and Codex's login state, which models actually answer, the
agent roster, and whether the rule that keeps the arbiter blind is honoured
here — each by running something, not by assuming. Afterwards, or after any
upgrade:

```
/council-doctor
```

### Updating, and why the version number is the delivery mechanism

```
claude plugin marketplace update plan-council
claude plugin update plan-council
```

**`claude plugin update` compares versions, not content.** Measured
2026-11-14: a fix merged to `main` without raising the version in
`.claude-plugin/plugin.json` produced
`✔ plan-council is already at the latest version (0.2.0)` and refreshed
nothing, while `marketplace update` *did* fetch it. The installed copy and the
published one then held different code under one version number — and the
commands' rule for choosing between copies ("prefer the installed version,
else the highest") picks the stale one, because the number cannot tell them
apart.

So: **every published change raises the version.** A merge without a bump is
not a delivery. `/council-doctor` now fails when it finds another copy that
declares this same version and holds different code, which is the one case the
version rule cannot resolve on its own.

### Requirements

- Claude Code (verified against 2.1.325).
- A POSIX shell with `awk`, `sed`, `cmp`, `mktemp`, `cut`, `tr` and `git`. No
  Python, Node or `jq` is needed.
- Optional: the [Codex CLI](https://github.com/openai/codex), logged in. Without it, see
  [Two Claude models instead of Codex](#two-claude-models-instead-of-codex).

**Any OS, but not any shell.** The scripts are POSIX `sh` and run on Linux,
macOS and Windows. What differs is how you invoke them, so nothing here
assumes your platform:

| You type into | Command |
|---|---|
| Linux / macOS (`sh`, `bash`, `zsh`) | `sh scripts/council-plan.sh <brief> --root <dir>` |
| Git Bash / MSYS on Windows | `sh scripts/council-plan.sh <brief> --root <dir>` |
| PowerShell | `& "C:\Program Files\Git\bin\sh.exe" "scripts/council-plan.sh" <brief> --root <dir>` |
| cmd.exe | `"C:\Program Files\Git\bin\sh.exe" "scripts/council-plan.sh" <brief> --root <dir>` |

Three Windows traps, each measured rather than assumed:

- PowerShell and cmd have **no `sh` on `PATH`**, so the bare command fails
  there with "not recognized".
- Use `<git-root>\bin\sh.exe`, **not** `<git-root>\usr\bin\sh.exe`. The second
  inherits the caller's `PATH` and, started from PowerShell, cannot find
  `dirname`: the script dies on its second line.
- Plain `bash` on Windows is usually `C:\Windows\system32\bash.exe`, which is
  **WSL** — a different machine. Its path translation turns a Windows working
  directory into a string with the separators eaten, silently. In WSL, install
  and log in to the planner CLIs *inside* WSL.

`council-detect.sh` prints the right line for your machine.

**Do not let anything rewrite the line endings.** `.gitattributes` pins `*.sh`
and `*.conf` to LF because CRLF kills them — unevenly, which is worse than
plainly: a CRLF copy still runs under Git Bash's `sh` but dies under `dash` on
the second line with `set: Illegal option -`, naming neither the file nor the
cause. A clone made on Windows with `core.autocrlf=true` and then used on
Linux, in WSL or in a container is exactly that case.

## What is in the box

```
plan-council/
  .claude-plugin/plugin.json       manifest
  .claude-plugin/marketplace.json  makes the repository installable
  skills/council/                  the planning method (phases 1-4)
  skills/execution-discipline/     the execution rules (phase 5)
  agents/scout.md                  read-only, cheapest model, no shell
  agents/worker.md                 mechanical edits, mid-priced model
  agents/implementer.md            the risk floor, pinned to Opus 5.5
  agents/reviewer.md               no editor; reviews, never writes
  commands/council-setup.md        /council-setup   (the first-run interview)
  commands/council-plan.md         /council-plan
  commands/council-review.md       /council-review
  commands/council-assign.md       /council-assign
  commands/council-doctor.md       /council-doctor
  scripts/council-detect.sh        what this machine has, by running things
  scripts/*.sh                     what the commands run
  prompts/*.md                     the planner, attacker, arbiter and assigner prompts
  config/council.conf              models, effort per phase, budget, planners, risk floor
  config/modes/*.conf              the preset modes: see Modes
  hooks/register.ts                the safety hook
  hooks/register.test.ts           its tests: claude plugin test ./plan-council
```

**Why two skills:** execution discipline applies to any delegated work,
council or not, and loads when you execute rather than when you plan, so it
is its own skill.

**Why no planner or arbiter agent files:** planners, attackers and the
arbiter run as child CLI processes started by the scripts, not as in-session
subagents. Codex is not a Claude subagent. A child process takes an exact
model ID, while in-session dispatch may accept only a family alias. And the
arbiter's lack of write access is set by the CLI's tool flags, so it holds
by construction. An agent-file version of the same roles would be a second
path without those guarantees.

## Worked example

A web app's `orders` table stores money as floating-point `total`. You want
it moved to integer cents without losing a cent of history.

**1. Write a brief** at `<your-project>/docs/brief-cents.md`:

```markdown
# Move order totals to integer cents

Goal: orders.total (REAL, in currency units) becomes orders.total_cents
(INTEGER). Every existing row converts exactly; the API keeps returning the
same JSON shape; no downtime longer than a deploy.

Constraints: PostgreSQL 15; the app is in app/, migrations in app/migrations/.
Notes on rounding incidents are in docs/notes/.

Out of scope: multi-currency.
```

**2. Plan.** The code is in `<your-project>/app` and the notes in
`<your-project>/docs`, so the context root is `<your-project>`, the
directory holding both:

```
/council-plan docs/brief-cents.md --root .
```

Both planners start from `<your-project>` with byte-identical prompts. Their
answers are captured in a temporary directory outside the project and
published only when both have finished:

```
<your-project>/.council/20260310-141502/
  brief.md      copy of the brief
  prompt.md     the one prompt every planner received
  plan-A.md     claude's plan
  plan-B.md     codex's plan
  council.txt   root, brief, config, which planner is which letter, and the
                model each was run on as far as the plugin can know it
  logs/
```

Say Plan A proposes a single migration with `ROUND(total * 100)`, and Plan B
proposes a shadow column, dual writes, a backfill and a later cut-over.

**3. Review.**

```
/council-review .council/20260310-141502
```

Both attacks run at once. Plan A's author concedes that a single migration
holds a long lock on a large table. Plan B's author concedes that dual
writes add a window where the two columns can disagree. Each attack lists
that disagreement as a *choice* with its price, not as an error. Then
the arbiter, which knows only "Plan A" and "Plan B", reads
`app/migrations/` and the order model itself and writes `arbitration.md`:

```markdown
### Decisions
1. Shadow column with backfill (Plan B), not a single migration. Evidence:
   `app/models/order.py:41` writes total on every status change, so the
   table is hot; `SELECT count(*) FROM orders` is not available to me, so
   table size is left for the human (see below).
2. Rounding: ROUND(total * 100) half-away-from-zero as Plan A specifies;
   Plan B's CAST truncates. Verified: `app/billing.py:88` rounds half-up
   today; truncation would change historical totals.
...
### Left for the human
- Table size. Under ~1M rows, Plan A's single migration is simpler and
  the lock is short; above, Plan B. Changes: steps 3-6 exist or not.
### Assumptions I verified myself
- `grep -rn "\.total\b" app/` -> 14 hits, listed; all reads go through
  Order.total_display except app/reports/daily.py:17.
### Verdict
FIX
```

You answer the open question, and the orchestrator writes
`final-plan.md` from the take-lists. The arbiter did not write it, and the
orchestrator does not approve it.

**4. Assign.**

```
/council-assign .council/20260310-141502/final-plan.md
```

```markdown
| # | Task | Agent | Model | If wrong, cost to notice | If unnoticed, consequence | Verified by |
|---|---|---|---|---|---|---|
| 1 | List every read of orders.total | scout | claude-haiku-5-5 | cheap: rerun the grep | a missed reader shows old data | task 2's review |
| 4 | Backfill migration | implementer | claude-opus-5-5 | expensive: wrong cents look plausible | silent corruption of history | mutation on the round-trip test; task 5 |
| 5 | Review task 4 | reviewer | claude-opus-5-5 | - | - | - |
| 7 | Rename display helper | worker | claude-sonnet-5-5 | cheap: type check fails | none beyond the build | `make test` green |
```

Task 4 looks small (one SQL statement) and still sits at the risk floor,
because its failure would be silent and would hit data integrity.

**5. Execute** following the `execution-discipline` skill: one writer at a
time, a reviewer after each delivery, every test proven by breaking the code
once, and you, not an agent, run the deploy.

## Configuration

The defaults live in `config/council.conf`. For one project, write
`<your-project>/.claude/plan-council.conf` — `/council-setup` writes it for
you. To use one file everywhere, point `COUNCIL_CONFIG` at it. The file is
POSIX shell, and each planner is one function:

**Write a project config as a delta, not a copy.** Set the few values you care
about and then source the plugin's, inheriting every planner function:

```sh
COUNCIL_MODEL_CLAUDE="${COUNCIL_MODEL_CLAUDE:-claude-fable-5-2}"
COUNCIL_ARBITER_EFFORT="${COUNCIL_ARBITER_EFFORT:-xhigh}"
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
```

Copying the whole file is how a plain assignment spreads, and a plain
assignment is what silently overrode an exported value for as long as that bug
lived.

### Seat functions and the order of lines

Before a phase starts, each seat function is checked for what every seat must
carry: `"$COUNCIL_DENY"`, `$(council_seat_flags)` unquoted, and `Bash` in
`--disallowedTools`. It is a text check of the config, and it reads the
definition the shell keeps, which is the last one executed. So where a line
sits matters:

- **A seat the plugin ships, if you redefine it, goes below the `.` line.**
  Above it, the plugin's config defines the seat again and yours never runs.
  Every phase refuses such a config, and `council-doctor.sh` names both lines,
  until the definition is moved below the `.` line or deleted. That holds
  whatever form the definition takes: in column 1, inside an `if`, indented,
  or written with `function`.
- **A function the plugin does not ship can sit above the `.` line**, as
  `/council-setup` writes it: that line cannot change it.
- **Any other `.` or `source` after the last definition of a seat makes that
  seat unknown, and the run is refused.** The check does not follow the file,
  so it cannot tell whether that file defines the seat. A helper sourced below
  the plugin's line, even one that holds only values, stops every run until
  its `.` line moves above, or the seat is defined again below it. A `.`
  inside any function body does the same wherever the function is, indented
  or not, with its `{` or `(` on the definition line or the next, since the
  text cannot say when that function is called. To find where a body ends,
  the check recognises quotes, comments, heredocs, parameter expansions,
  command substitutions, backslash escapes and `case` patterns, without
  running or expanding anything; what it still reads wrongly is in the list
  mentioned below.
- **The plugin's `.` line counts only on its own, first on its line, outside
  any block**, and spelled `"$COUNCIL_PLUGIN_ROOT/config/council.conf"`,
  `"${COUNCIL_PLUGIN_ROOT}/config/council.conf"` or the literal path. Written
  after `[ -f ... ] &&`, inside an `if`, or with `${COUNCIL_PLUGIN_ROOT:?}`, it
  makes unknown every seat it defines that is not defined again below it.
- **A body is read to its first `}` in column 1**, or, when it is written on
  its definition line, only if that line has exactly one `{` and one `}`, no
  `#`, an even count of each quote, and ends in `; }` or `& }`. What is read
  must also end on the line where the shell closes the body, which a heredoc
  or a quoted string can move. A body the check cannot read to its end is
  unknown.

Unknown is refused, there is no option to skip it, and the message names the
line. The check reads text, not the running shell, and it can still be wrong:
the comments above `council_function_body` and `council_definition_scan` in
`scripts/lib.sh` list the shapes known to be read wrongly.

**The seat check.** The text check reads the config; the seat check reads
a record the CLI writes. Before the seats of each phase are paid for,
`council-plan.sh` and `council-review.sh` call each seat the text check
judged to drive `claude` once, by name, from the context root, with
`--output-format json` added for that call only, and ask it to read a file
planted in the run directory. The phase goes on only if the CLI's own record
of that call, its `permission_denials` field, names a refused `Read`, and the
file's content appears nowhere in what the seat printed. Anything else stops
the run, names the cause, and says that the text check had passed. It costs
one call per `claude` seat per phase: before the planners, before the
attacks and before the arbiter. `council.txt` records the outcome as
`seatcheck.plan=`, `seatcheck.attack=` and `seatcheck.arbitrate=`, each with
a `.from=` line saying what was measured.

What a pass does not show is which rule refused the read. With the run
directory inside the context root, `--restricted` alone does not refuse it,
so something else did. With a run directory outside the root, as `--out` can
place it, `--restricted` alone refuses the read with no deny rule at all, and
the record says that it does not show a deny rule did it. It shows that one
read, in a separate process, just before the phase, was refused; it is no
record of the calls that follow. Nor does it check that `Bash` is denied.
A seat whose function does not run `claude` itself is not probed, and the
record lists it. `--no-seat-check`
skips the check, and `council.txt` then records `skipped`. `council-assign.sh`
does not run it.

The tests of both checks ship with the plugin, so you can run them on your
own shell:

```sh
sh <plugin>/scripts/tests/definitions.sh
dash <plugin>/scripts/tests/definitions.sh
sh <plugin>/scripts/tests/permission-denials.sh
dash <plugin>/scripts/tests/permission-denials.sh
sh <plugin>/scripts/tests/canary.sh
dash <plugin>/scripts/tests/canary.sh
```

with `<plugin>` the plugin's directory.

**They take a while, and `canary.sh` takes the longest.** Measured on Git
Bash on Windows, 2026-11-20: `canary.sh` ran its 504 assertions in 1368
seconds under `sh` and 1174 under `dash`, because each assertion runs
`council-detect.sh`. The others are minutes. Nothing is wrong if one sits
there for twenty minutes, and on another machine the numbers will differ.
`canary.sh` takes `T_ONLY` to run one case and `T_SHELLS` to run one shell.

They write only to a temporary
directory, which they remove, and they run `council-assign.sh` and
`council-doctor.sh` with a stand-in `claude` first on `PATH`, so no model is
called; `permission-denials.sh` runs `council-plan.sh` and
`council-review.sh` the same way, and `canary.sh` runs `council-detect.sh`
with a stand-in `claude` that carries out the canary's probes itself and a
stand-in `codex` that is not logged in. When `bash` is installed, one section of
`definitions.sh` sources every test config in
bash and compares the definition bash keeps with the one the check names;
bash is used there only because it can say where a kept function was
defined, and agreeing with bash is not agreeing with every shell. The exit
status is non-zero when any assertion failed.

Every setting also **defers to the environment**, so a single run can be changed
without editing a file:

```sh
COUNCIL_PLANNERS="claude claude_alt" council-plan.sh brief.md
```

What survived that way is printed before the run starts
(`from the environment, and still in effect after the config: COUNCIL_PLANNERS`).
It is announced in both directions on purpose: a value dropped in silence and a
stray export in a shell profile steering a run are the same failure wearing
different clothes.

The announcement reports the **outcome**, not the intention, and that
distinction was a bug. An earlier version noted which names arrived from the
environment and never looked again, so a config using a plain assignment made
the run say the environment had won while the config had overridden it — the
silently ignored setting, wearing a line that denied it. A run now **refuses to
start** when a config overrides an exported value, and names both values and
the line to write. So if you add a setting, keep the `VAR="${VAR:-default}"`
form.

### What the prompts say about your repository

No seat has a shell, so no seat can run git to say which commit it read. The
runner reads it and puts it in the prompt:

- **At planning**, one block at the end of the shared prompt: `HEAD`
  (`git rev-parse HEAD`), the branch, and `git status --porcelain` verbatim,
  or `clean`, or `not a git work tree`. It is read once and is part of the
  bytes every planner receives, so the check that the planners' prompts are
  identical covers it: planners told different facts about the tree would be
  comparing situations, not plans. `council.txt` records the same facts as
  `head=`, `branch=`, `tree=` and one `tree.<n>=` per status line.
- **At review**, every attack prompt and the arbiter's prompt carry two
  blocks: the repository at planning, read back from `council.txt`, and the
  repository now. When both HEADs are commits and they differ, the second
  block also carries `git diff --stat <HEAD at planning> <HEAD now>`, so a
  seat checking a claim against code that has moved is told it moved.
- **Assignment** gets no such block.

**The price: file names reach the prompts verbatim.** Every path
`git status --porcelain` prints, and every path `git diff --stat` prints,
goes to every seat, and from there to the model provider behind it, Codex
included. `git status --porcelain` names untracked files unless git ignores
them, so a scratch file in the tree, such as `notes-for-me.txt`, is named in
the prompt. It lists the whole repository, not only the context root, when
the root is a subdirectory. Only names: no file's content is added this way.
If a name should not leave the machine, ignore the file (`.gitignore` or
`.git/info/exclude`) or move it out of the repository before a run.

Run directories: under the default layout `<root>/.council` holds a
`.gitignore` of `*`, so no run is ever named. A run placed with `--out` at a
path git does not ignore is named once it holds files, by default as its
directory (`?? runs/`); an earlier run there is named that way in a later
run's prompts. This run's own directory is empty when the planning block is
read, and git does not list an empty directory. At review it holds files, so
the review prompts name it the same way, and since 2026-11-20 the review no
longer refuses a run directory git can see (see
[Limitations](#limitations)). Committed between the two HEADs, its files are
named one by one in `git diff --stat`. Names only: a prompt can say
`?? runs/` or name `council.txt`, never what `council.txt` maps.

Not a git work tree, no commits yet, a detached HEAD and `git` missing from
`PATH` are all said in the block, in words; none of them stops a run.

### Effort per phase, and a spending cap

How deep each model reasons is set per phase, because one planner function
serves both planning and attacking:

| Setting | Default | What it governs |
|---|---|---|
| `COUNCIL_PLANNER_EFFORT` | `high` | writing the plan |
| `COUNCIL_ATTACK_EFFORT` | `high` | attacking the other plans |
| `COUNCIL_ARBITER_EFFORT` | `high` | deciding, and verifying in the code |
| `COUNCIL_ASSIGN_EFFORT` | `medium` | filling the assignment table |

Levels are `low`, `medium`, `high`, `xhigh`, `max`. Each level up means more
reasoning tokens, and reasoning bills as output, which is five times the input
rate — so this is the main cost lever inside one model. Pay for arbitration;
save on assignment. `max` is for when correctness matters more than cost, and
is rarely the right default for all four phases at once.

`COUNCIL_BUDGET_USD` caps **each child run** through the CLI's own
`--max-budget-usd`. Empty means no cap, and empty is the shipped default:
nothing is capped unless you ask for it. With N planners a council is 2N + 1
long runs plus one for the assignment, so a cap of 2 holds the Claude side of
a two-planner council near 8. The cap's price: a run that reaches it stops
instead of finishing.

**A cap is not a one-way door.** Lift it permanently by editing the line, or
for a single run by exporting an empty value:

```sh
COUNCIL_BUDGET_USD= council-plan.sh brief.md --root .
```

That works because four settings are written `"${VAR-default}"`, without the
colon: `COUNCIL_BUDGET_USD`, `COUNCIL_MODEL_CODEX`, `COUNCIL_AGENT_DIRS` and
`COUNCIL_MODE` are the ones whose **empty value means something** — no cap,
Codex's own default model, no extra agent directories, no mode. With
`"${VAR:-default}"` an exported empty value counts as unset and the default
returns, so "no cap for this run" could not be expressed at all: measured
2026-11-14, the run refused to start and reported that the config had
overridden the environment. The same holds for a mode: with
`COUNCIL_MODE="${COUNCIL_MODE-standard}"` in a project config,
`COUNCIL_MODE= council-plan.sh brief.md` runs once with no mode, and with the
colon that run refuses to start (measured 2026-11-18). Every other setting
keeps the colon.

Codex takes neither flag. Its depth comes from its own model and config, so
pin `COUNCIL_MODEL_CODEX` if you want it fixed.


```sh
COUNCIL_PLANNERS="claude codex"

planner_claude() {
  claude -p --model "$COUNCIL_MODEL_CLAUDE" \
    --effort "$(council_effort)" \
    --permission-mode default \
    $(council_budget_flags) \
    $(council_seat_flags) \
    --disallowedTools Edit Write NotebookEdit Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" \
    > "$1"
}
```

The contract every planner function keeps:

| | |
|---|---|
| stdin | the prompt, byte-identical for every planner |
| `$1` | absolute path of the file its final answer must land in |
| working directory | the context root (the script `cd`s there first) |
| exit status | 0 on success |
| writes | nothing but `$1`. Planners are read-only. |

The same function is reused for that planner's cross-attack. The `arbiter`
function, which also drafts the assignment table, has the same contract.

### Two Claude models instead of Codex

If Codex is not installed, set:

```sh
COUNCIL_PLANNERS="claude claude_alt"
```

`planner_claude_alt` ships in the default config, pinned to a different
Claude model than `planner_claude`. Keep them different: disagreement is the
product, and the same model twice gives you mostly the same plan twice.
Everything else (blind planning, parallel attacks, arbitration) works
unchanged.

### Adding a third planner

Add one function and its name:

```sh
COUNCIL_PLANNERS="claude codex gemini"

planner_gemini() {
  gemini --model <model-id> > "$1"   # reads the prompt on stdin
}
```

For a CLI that writes its answer to a file instead of stdout, pass `"$1"`
as that file. **Always** feed the prompt on stdin: briefs with embedded plans
exceed the command-line length limit on some platforms, and that failure
looks like an empty answer. The Gemini line above is an illustration I
could not run. Check the tool's own `--help` for its non-interactive and
read-only flags.

### Models

**Planner and arbiter models** are settings, so the setup interview can write
them without touching a function: `COUNCIL_MODEL_CLAUDE`,
`COUNCIL_MODEL_CLAUDE_ALT`, `COUNCIL_MODEL_ARBITER` and
`COUNCIL_MODEL_CODEX`. They hold exact IDs rather than aliases, because an
alias moves under you and knowing which model answered is the point of the
method. `--model` does accept `fable`, `opus` and `sonnet` if you prefer the
latest of a line, but under a mode the model check described in
[Modes](#modes) compares exact IDs, so an alias passes only if the CLI bills
under that literal string; use exact IDs there.

The shipped defaults are Opus 5.5 for a planner and the arbiter and Sonnet 5.5
for the second Claude planner. **That is an entitlement guess, not a
recommendation.** If your account has Claude Fable 5.2, it is priced highest,
roughly twice Opus 5.5 per token, and `planner_fable` ships ready to use.
Which model plans or judges better is something nothing in this plugin has
measured, so it does not say. `council-detect.sh` probes each candidate and
reports which ones actually answer, so you need not guess which you have.

**Executor models** are pinned in each agent's frontmatter (`model:`), using
exact model IDs. To change them, edit your copy of the plugin, or copy an
agent into `~/.claude/agents/` under a new name and add that directory to
`COUNCIL_AGENT_DIRS` so `/council-assign` sees it. The risk floor is
`COUNCIL_RISK_FLOOR` (default `implementer`).

## Modes

A mode answers the technical questions from one question about your situation.
Two ship, in `config/modes/`, and each file's header says what the mode sets,
what it promises and what it does not protect against:

| Mode | The situation | Effort: plan, attack, arbitrate, assign | The first model on your ladder goes to |
|---|---|---|---|
| `standard` | a decision that is not cheap to undo | `high`, `high`, `high`, `medium` | the arbiter |
| `thorough` | a project I have not understood well yet | `xhigh`, `high`, `xhigh`, `medium` | the first Claude planner |

`/council-setup` asks which situation you are in and writes the choice. For a
single run, `COUNCIL_MODE=thorough council-plan.sh brief.md --root .` switches
the mode, and `COUNCIL_MODE= council-plan.sh brief.md --root .` runs with none.
A mode file may set the four efforts and `COUNCIL_STRONGEST_FOR` (`arbitration`
or `planning`) and nothing else: never a model ID, never the planner list,
never a dollar figure. It is one more link in the chain that already exists,
so the order stays environment, project config, mode, plugin defaults: a value
you set yourself still wins over the mode's.

**The ladder is your own order, not a measurement.** `COUNCIL_MODEL_LADDER`
is a list of exact model IDs separated by single spaces, first rung first.
`/council-setup` builds it from the models that answered its probe, in the
order the probe lists them (per-token price, highest first), and asks you to
confirm, reorder or drop; `COUNCIL_MODEL_LADDER_DATE` records the day of the
probe. Your ranking is not a benchmark, and the ladder is as old as its date.
Nothing in the plugin compares models: the deal counts along your line, and
position on it is all that "strongest" means here.

**The deal.** On every load the mode's seat order takes models from the top of
the ladder without replacement, so no model is dealt to two seats, and the
second Claude planner always picks last. The seats are the Claude planners
`claude` and `claude_alt`, in `COUNCIL_PLANNERS` order, and the arbiter. With
the ladder `m1 m2 m3`:

| Mode | `COUNCIL_PLANNERS` | `COUNCIL_MODEL_CLAUDE` | `COUNCIL_MODEL_CLAUDE_ALT` | `COUNCIL_MODEL_ARBITER` |
|---|---|---|---|---|
| `standard` | `claude codex` | `m2` | not in play | `m1` |
| `standard` | `claude claude_alt` | `m2` | `m3` | `m1` |
| `thorough` | `claude codex` | `m1` | not in play | `m2` |
| `thorough` | `claude claude_alt` | `m1` | `m3` | `m2` |

- **Codex takes a seat but never a rung.** Its model is its own config's
  business and the ladder cannot rank it. Where it stands in
  `COUNCIL_PLANNERS` changes nothing above: `codex claude` deals as
  `claude codex` does.
- **A seat that already holds a value keeps it and takes no rung**: one set in
  the environment, or pinned in your project config above the line that
  sources the plugin's. That is the only way to accept a ladder shorter than
  the seats in play.
- **The load refuses**, naming what it found: a ladder too short for the seats
  in play; a ladder entry listed twice, or holding anything but letters,
  digits, `.`, `_` and `-`; two Claude planners on one model ID, hand pins
  included; and any planner but `claude`, `claude_alt` and `codex`,
  because a function such as `planner_fable` pins its own ID and could
  quietly take a model the ladder already dealt.

Every load under a mode prints what it did, as
`plan-council: mode standard seats: ...` followed by the ladder's date, plus
a line for any seat not dealt from the ladder. `/council-doctor` shows the
same seats under `Config`. To see the deal a ladder would make before
writing anything, run the doctor with the settings exported, as section 4 of
`/council-setup` does, rather than working it out by hand.

**The model check.** Under a mode, before any planner is paid for,
`council-plan.sh` asks each distinct Claude model ID in play for one word with
JSON output, at most three calls and fewer when seats share an ID, and stops
unless the call exits 0 and the CLI billed exactly that ID. It is a gate,
never a selection: it chooses, reorders and substitutes nothing. Because the
comparison is exact, a seat holding an alias such as `opus` passes only if
the CLI bills under that literal string; an alias it resolves to a full ID is
refused as a possible fallback, so use exact IDs under a mode.
`--no-model-check` skips the check, and `council.txt` records
`modelcheck=passed` or `modelcheck=skipped`. A pass shows what answered when
planning started, not what served the planning calls, which run without JSON
output and leave nothing to read.

**What a run records.** Besides the root, the brief and the config,
`council.txt` holds `mode=` and `ladder=`, and for each letter
`planner.<letter>=` and `model.<letter>=`, with a `model.<letter>.from=` line
saying where that value came from. For a Claude planner it is the setting in
effect, which the shipped planner function passes as `--model`: what was asked
for, not proof of what answered. For Codex it is the model **announced** in
Codex's own banner, or `unknown`; the record calls it announced, what Codex
was asked for, and never claims it is what served. `/council-review` adds
`model.arbiter=` and, when a mode is involved, refuses before any model is
called if a Claude planner would attack on a different model from the one it
planned with.

**What the setup's probe reports.** The summary `council-detect.sh` ends with
holds `DENY_RULE_EFFECTIVE`, `OUTSIDE_ROOT_REFUSED` and `WRITE_REFUSED`, the
canary's three verdicts (`yes`, `no`, `untested` or `unknown`), then
`MODELS_AVAILABLE` and `MODELS_NOT_ANSWERING` (every probed ID that did
not answer as itself, a `MISMATCH` included), `PROBED_ON`, and, when Codex is
logged in and the probe runs, `CODEX_MODEL` and `CODEX_EFFORT` as its banner
announced them, or `unknown`.

## The safety hook

`hooks/register.ts` is a function-hooks module that the Claude Code engine
runs itself, so it needs no Python, Node or other runtime. It does two
things, and **fails open on any error**, because a broken guard must not stop
anyone working:

1. **Refuses an Agent dispatch with no explicitly chosen model.** A dispatch
   passes if it sets `model`, or if its agent type's definition pins
   `model:` (anything but `inherit`). The allow-list is rebuilt on every
   dispatch from the frontmatter of the plugin's `agents/`,
   `~/.claude/agents/` and `./.claude/agents/`. Forks pass, since they
   always run on the parent's model.
2. **Inside subagents, refuses Bash commands that change git state, open a
   remote shell, delete recursively, build or push images, change
   infrastructure, or deploy.** The main session (you, the orchestrator) is
   not restricted. This is a deny-list on command spellings: a guard rail
   against accidents, **not a security boundary**.

## Traps this plugin designs out

| Trap | How it is designed out |
|---|---|
| A planner given less context than its rival loses for the wrong reason | One context root for all planners; one prompt, byte-identical, checked with `cmp` before launch |
| A child agent's read outside its working directory is refused silently | Every child is started with `cd` to the context root; the brief and plans are embedded in the prompt, not read by path |
| A relative path checked, then read after `cd`, feeds an empty prompt | Every path is made absolute before any `cd`; the assembled prompt must be larger than the brief |
| A planner reads its rival's half-written plan | Answers are staged in a temp directory outside the root and published after every planner has finished |
| An attack inherits the other attack's targets | Attacks run in parallel and are published together |
| Exit code 0 with an empty answer looks like success | Any answer under `COUNCIL_MIN_BYTES` is a failure; closing words are checked |
| The judge edits what it judges | The arbiter is started with no edit or write tool; its stdout is the report |
| A backquote in a shell string opens a command substitution | The scripts contain none; `/council-doctor` runs `bash -n` on every script |
| A long prompt passed as an argument is truncated | Prompts always go on stdin |
| A pinned model silently falls back to another | `/council-doctor` asks each model and prints the IDs the CLI reports; under a mode, every run asks each seat's model before any planner is paid for |
| A dispatch runs on whatever the default model is | The hook refuses it |

Two traps cannot be designed out by a plugin, so here they are, stated plainly:

- **The agent registry is read at session start.** An agent definition you
  write during a session cannot be dispatched with the Agent tool in that
  same session. Start a new session, or run it as a child process with
  `claude -p`.
- **Model IDs.** Exact model IDs work in an agent's frontmatter. The
  in-session Agent tool's `model` parameter accepts only family aliases
  (`opus`, `sonnet`, `haiku`, `fable` on the build this was written
  against). To see which model actually ran:
  `printf 'ok' | claude -p --model <id> --output-format json`, then look for
  the model IDs in the output. `/council-doctor` does this for every model
  in the config and the agents.

## Version-sensitive flags

The planner and arbiter functions use `claude -p`, `--model`, `--effort`,
`--max-budget-usd`, `--permission-mode default`, `--disallowedTools`,
`--output-format json`, and `codex exec --sandbox read-only
--skip-git-repo-check --output-last-message -`. Every one of those was
confirmed present in Claude Code 2.1.325 and codex-cli 0.162.1 on
2026-11-14. The `claude` seats also carry `$(council_seat_flags)`:
`--restricted --tools Read,Glob,Grep --setting-sources project,local
--strict-mcp-config --disable-slash-commands`, measured as a set on
2026-11-19; the comment above `council_seat_flags` in `scripts/lib.sh` says
what each flag is for and which one was not measured on its own. They no
longer pass `--allowedTools`. `--effort` takes `low`, `medium`, `high`,
`xhigh` or `max`, and `--max-budget-usd` works only together with `--print`, which every function
here uses.

Two shapes matter beyond the names. `--allowedTools` and `--disallowedTools`
are **variadic**, so a prompt written after one of them is swallowed as more
tool names — which is one reason every prompt arrives on stdin. And a deny
rule takes a path: `Read(<dir>/**)` blocks `Grep` as well as `Read`, but only
when the path is written in the form the CLI accepts, which on Windows is the
`cygpath -m` form and not the MSYS one.

Permission modes in particular
**are not what their names suggest**, and their meanings have changed
between versions. A mode that sounds permissive can deny everything in a
non-interactive session, and an edit-accepting mode alone leaves every shell
command waiting for an approval that never comes. The read-only roles here
do not rely on an allow-list: measured 2026-11-19, `--allowedTools` is not
exclusive, and a child given only `Read` ran `git log`. They rely on
`--tools Read,Glob,Grep`, measured exclusive, so a `claude` seat holds
exactly `Glob`, `Grep` and `Read` and no shell. For a child **executor**
that must edit and run commands, the pattern that works is an edit-accepting mode, plus an explicit
allow-list of the commands it needs, plus a deny-list (commit, push, deploy,
remote shell, recursive delete). Check `claude --help` and `codex exec --help` on
the installed versions, and run `/council-doctor` after every upgrade.

## Limitations

Everything below was measured on 2026-11-14 against Claude Code 2.1.325 and
codex-cli 0.162.1, on Windows with Git Bash, unless it says otherwise. A
limitation that is wrong by understatement is still wrong, so what has since
been proved is stated as proved, and what broke is stated as broken.

**Run end to end with real models, once.** A full chain — two blind plans, two
parallel attacks, arbitration — ran on this repository with Claude Opus 5.5 and
Codex as planners: 3m35s for the planning phase, about 8 minutes in all, a
`PASS` verdict whose report carried all five required sections, zero
percentages, and 12 `path:line` citations. The attacks disagreed (one closed
`THIRD`, the other `A`), which is the method working rather than two plans
agreeing. One run is not a track record.

**Proved by measurement, not assumed:**

- **Marketplace install.** `claude plugin marketplace add matteooxx/plan-council`
  then `claude plugin install plan-council@plan-council` installs and enables
  it at user scope. The component inventory then lists 6 skills (the two skills
  plus the four commands) and 4 agents, so discovery by convention works.
- **Both hooks fire in a live session.** An `Agent` dispatch with no model was
  denied with this plugin's own message, which listed the pinned agents it
  found — the plugin's four, prefixed, plus the user's own from
  `~/.claude/agents`. A subagent's `ssh -V` was denied with the remote-connection
  message, and the subagent deferred to the orchestrator as the text tells it to.
- **The three invariants hold with three planners, not just two.** One prompt
  checksum across all three plans; each planner saw zero rival plans while
  writing; each attacker saw all three plans and zero rival attacks; the
  arbiter saw three plans and three attacks.
- **`/council-assign` runs**, builds the roster from the agents' frontmatter,
  validates the risk floor, and warns when a percentage appears in the table
  (proved with an assigner that emitted one).
- **A run leaves no trace in version control.** With the run directory inside
  the repository, `git status` stayed clean and `git check-ignore -v` named
  `.council/.gitignore:1:*` as the rule covering both the ignore file and the
  run's own files.
- **Portability beyond one shell.** The whole chain has run to the end under
  `dash` as well as under Git Bash's `sh`. Not every time: under Cygwin
  `dash` on Windows a run has also failed to return, three times in one day,
  for a cause not known (see **A run that does not return**, below). See the
  table in [Requirements](#requirements) for the per-shell invocation; the
  Windows traps there were each produced on purpose.

**Known false reports from the tooling, neither of which is a defect here:**

- `claude plugin validate` advises adding an install line that is already in
  this README, word for word. Validation passes regardless.
- `claude plugin details plan-council` reports **`Hooks (0)`** even though both
  hooks demonstrably deny a live dispatch. A `modules`-based hook is not
  counted there; the file has the same shape as a working plugin's. Do not
  conclude from that line that the hook is missing.

**Still not proved:**

- **WSL and native Linux or macOS.** `dash` on Windows is not the same thing.
  In WSL the planner CLIs resolve to the Windows binaries through `/mnt/c`
  unless installed inside WSL, and a working directory crosses that boundary
  with its separators eaten.
- **Adapters for a third provider** (Gemini CLI, Cursor, Aider). The shape is
  documented; none has been invoked.
- **The model probe's parsing.** The setup's probe and the model check read a
  reply with the same reader: only the `claude-...` keys of the `modelUsage`
  object in the JSON on stdout, from a call that exited 0. If a future
  version of the CLI stops billing under those keys, both will find no ID and
  refuse, rather than read the change as a pass. `/council-doctor` still
  lists every quoted `claude-...` string in stdout and stderr with `grep`,
  whatever the exit status, so a changed format can still leave its `ok`
  lines standing; see the probe bullet under Limitations.
- **Codex's model is not pinned** unless you set `COUNCIL_MODEL_CODEX`, and
  Codex takes neither `--effort` nor `--max-budget-usd`, so those settings do
  not reach it. A run records the model **Codex announced** in its own banner,
  or `unknown` when the banner cannot be read. The record calls it announced
  and never claims it is what served: the banner repeats what Codex was asked
  for, and measured 2026-11-15 it echoes a `-m` value verbatim even for an
  ID that does not exist.

**Real gaps that remain, now stated plainly:**

- **A run that does not return.** Three times in one day, on Windows under
  Cygwin `/usr/bin/dash`, a run stayed in the parallel runner's `wait` with
  its seats already finished: twice in `council-review.sh`, once in
  `council-plan.sh`. One of the three was measured: 4 h 31 min in `wait`, no
  live child process, an empty run directory, and a stand-in `claude` that
  answers in milliseconds, so it was not waiting for a model. `kill` and
  `kill -KILL` did nothing to it; `/usr/bin/kill -f` ended it.
  **Not known:** the cause; whether it happens under `sh`, with a real
  `claude`, or on Linux or macOS; and how often. The runs that did return
  were not counted, so three is a count with no denominator, not a rate, and
  nothing here says it is rare.
  **How to recognise it:** the run has printed a `started` line for each
  seat, no seat process (`claude`, `codex`) is left running under it, and no
  `done` or `FAILED` line follows.
  **What to do, in this order:** before it starts any seat, every phase
  prints one line that begins `plan-council: staging directory` and ends
  with that directory's path (a review prints it twice, once per phase, with
  the same path). Copy `answer-*.md` out of that directory **first**, and
  only then end the run with `/usr/bin/kill -f`. A kill can delete the
  directory: the run removes it on exit, and measured on a `council-plan.sh`
  under `dash`, killed with `/usr/bin/kill -f` while it waited on a slow
  stand-in, the directory was gone afterwards, `answer-*.md` with it. That
  run was killed in flight, not hung, because the hang cannot be produced on
  demand: the trap that deleted the answers is the same one, on the same
  shell, but the kill of a hung run has not itself been observed.
- **The context root is a boundary for a Claude seat, not for a Codex seat.**
  On 2026-11-14 a read-only child agent read an absolute path *outside* the
  root with no refusal at all. Earlier versions of this README and of
  `skills/council/SKILL.md` said such a read was silently refused; that was
  wrong then. With `$(council_seat_flags)`, which every `claude` seat the
  plugin ships now carries, a `claude` seat's read of an absolute path
  outside the root is refused by `--restricted`, and it has no tool that
  writes (measured 2026-11-19). A Codex seat is the reverse on
  reading: measured 2026-11-19, under `--sandbox read-only` it refused a
  write and **read an absolute path outside the root**, and `codex exec
  --help` offers nothing that restricts reads. So a Codex seat cannot write
  but can read outside the root; a Claude seat can do neither.
- **The arbiter's blindness is enforced for Claude children only.** The run
  directory holds `council.txt`, which maps each letter to its planner, and the
  config turns a planner name into an exact model in one more read. Each child
  is now given a deny rule covering that directory, and `council-detect.sh`
  probes the rule with a canary, route by route and tool by tool, each
  route beside a control that must be reached: it prints
  `DENY_RULE_EFFECTIVE=yes` only when every route was refused, and
  `untested`, which is not a pass, when any control failed. It runs at setup
  and by hand, not before each run. But the rule is a
  Claude Code permission rule: **it does not reach Codex**, whose read access is
  whatever that CLI grants. With Codex as a planner, nothing the plugin
  enforces keeps it out of the run directory during the attack phase, and no
  prompt in `prompts/` asks a seat to stay out of it. The seat check does not
  call a Codex seat either. `/council-doctor` names every function the rule
  cannot cover.
  A function that drives `claude` and simply **drops** the rule is a different
  case, and no longer a tolerated one: planning and both review phases refuse
  to start, naming the function, before a single model run is paid for. Only
  `/council-assign` continues with a warning, because no attribution is at
  stake there. Until 0.2.3 every call site ended in `|| true`, so the warning
  stopped nothing — found by the arbiter of a real council run, which grepped
  the scripts and said so.
  A deny rule written with an MSYS path (`/c/...`) matches nothing and blocks
  nothing, in silence — `cygpath -m` produces the form that is honoured, which
  is why `cygpath` is checked for on Windows.
- **A run directory git can read is reviewed.** Until 2026-11-20
  `/council-review` refused a run directory git tracked or did not ignore.
  It went because a measurement showed it protected nothing: on that date a
  `claude -p` seat that had a shell, with a deny rule on each of two run
  directories, printed an ignored run's `council.txt` with
  `cat .counci?/run1/council.txt` and a tracked run's with
  `cat run?/run2/council.txt`, whether git could see the directory or not.
  No seat the plugin ships has a shell. What does protect the attribution,
  and what does not, is listed in the comment on `$COUNCIL_DENY` in
  `config/council.conf`. Not protected, first: **an earlier run placed
  outside `<root>/.council`**. No rule denies it and a read inside the root
  is allowed, so a Claude seat can read its `council.txt`, and in a project
  that runs the same planners in the same order that is this run's mapping:
  keep runs in `<root>/.council`, or one run per `--out` parent. Then: the
  run directory's name in the review prompts (see
  [What the prompts say about your repository](#what-the-prompts-say-about-your-repository));
  a Codex seat; a Claude seat that holds a shell all the same; and a run
  directory you commit, whose `council.txt` then stays in your history.
- **The arbiter still defaults to the same model as a planner.** It is never
  told which plan is whose, and it can no longer look the mapping up, but a
  model that may be judging its own work is a weaker check than one that
  cannot be. `/council-setup` offers a third model for the job.
- **`${CLAUDE_PLUGIN_ROOT}` does not resolve.** It is absent from a session's
  environment; in a POSIX shell on Windows the unresolved reference becomes a
  path inside the Git installation rather than an error, so a live
  `/council-doctor` was handed `C:/Program Files/Git/council-doctor` and
  completed only through the documented Glob fallback. That fallback is
  load-bearing, not a safety net, and the commands now put it first.
- **The reviewer has a shell.** It has no Edit or Write tool, and its
  instructions forbid writing through the shell, but `Bash` can write files. It
  needs the shell to run tests. For a reviewer that cannot write at all, remove
  `Bash` from its `tools:` and run the tests yourself.
- **The subagent command guard is best effort.** It matches common spellings in
  command position. An agent determined to run `git push` from inside a script
  file will get through. The rule in the execution-discipline skill is the real
  control.
- **Cost is capped only if you cap it.** `COUNCIL_BUDGET_USD` is empty by
  default, and a council is 2N + 1 long runs plus one. Claude's side of a run
  reports no usage anywhere the plugin can read, because each planner's answer
  *is* its stdout, which rules out `--output-format json`; Codex, by contrast,
  prints its token count into the kept log. So a run cannot report its own
  Claude cost.
- **Model IDs go stale.** The agents pin exact IDs. When those models retire,
  update the frontmatter and the config; `/council-doctor`'s probe will show
  the failure. Whether an unknown ID fails loudly or falls back silently was
  not verified, which is why the probe exists.
- **Planner names and paths.** Planner names may use only letters, digits and
  `_`. `COUNCIL_AGENT_DIRS` is space-separated, so its paths cannot contain
  spaces.

**Modes: what they cost and what they cannot do.** Where a behaviour below
was measured, that was between 2026-11-15 and 2026-11-18 with stand-in CLIs,
so its costs are counted calls, not bills:

- **The ladder is not measured, and it goes stale.** It is your order,
  confirmed once, and it carries the date of the probe it came from. Nothing
  re-checks it: a model that gets better, worse or cheaper after that date
  moves nothing, and only the date printed with every seats line, or a fresh
  `council-detect.sh`, shows how old the order is. A ranking is only as good
  as the day it was made, and the plugin cannot tell you that day has passed.
- **The model check costs money before every council under a mode.** One
  one-word call per distinct Claude model ID in play, at most three, each a
  full CLI session billed as such; the run prints the `costUSD` figures it
  finds after each. `--no-model-check` skips it, at the price of not knowing
  what answered. The setup's probe in `council-detect.sh` costs separately: one
  one-word call per candidate model, one for the guard check (a long one: it
  carries every probe of the canary) and a second, short one when its write
  probe needs its control, and, when Codex
  is logged in, one Codex call that runs at the model and reasoning effort of
  your own Codex config, which can be `xhigh`.
- **The setup's probe holds for the reply it read, and `/council-doctor` is
  not the model check.** `council-detect.sh` reads each reply with the model
  check's own reader, `council_billed_ids` in `scripts/lib.sh`, and judges
  it as the check does: the call must exit 0, stderr is not read for IDs,
  and the exact ID asked for must be among the `modelUsage` keys. So a failed
  call whose error names the ID, a fallback announced on stderr, the ID named
  outside `modelUsage`, and a dated or suffixed key are each reported as not
  answering, as the check refuses them. Measured with stand-in CLIs, the two
  reach the same verdict on every reply shape the test harness has. That
  holds for the same reply: a model the probe listed can still be refused at
  a later council if the CLI answers differently by then, which is why the
  ladder carries the probe's date. `/council-doctor` reads more loosely, on
  purpose, so that its output stays what it was: it reads stdout and stderr
  together, ignores the exit status, takes any quoted `"claude-..."` string
  as reported, and accepts a reported ID that only starts with the one asked
  for, so its `ok` line is not a pass of the model check.
- **The arbiter's model is checked at planning, not again at the review.**
  Under a mode, the model check asks the arbiter's ID along with the
  planners', before any planner is paid for. A review then records
  `model.arbiter=` from the setting in effect for that review and does not
  re-check it against what planning verified. So a change to the ladder, to
  the mode or to `COUNCIL_MODEL_ARBITER` between the two phases can seat an
  unverified model as arbiter. The run stays traceable, because
  `model.arbiter.from=` says the value came from the setting in effect for
  the review, but nothing refuses it. Keep the ladder, the mode and that
  setting as they were for the planning, or read `model.arbiter=` against
  the `modelcheck.<n>` lines in `council.txt` before you trust the
  arbitration. A run with `--no-model-check` never checked it at all.
- **Under `standard`, the first model on your ladder also drafts the
  assignment table**, because the arbiter's model is the one
  `/council-assign` runs. The mode's assignment effort is the only lever on it.
- **A two-model account without Codex needs one hand pin to use a mode at
  all.** Two Claude planners and the arbiter are three seats, and a two-rung
  ladder runs out: the load stops. Pinning the arbiter to one of the two models
  lets it load; the plugin allows an arbiter that shares a planner's model and
  only discourages it.
- **The situation question comes after the paid probe.** `/council-setup` asks
  which mode fits only once the probe has run, so the probe is paid for before
  you have said what you are planning for. A reviewer judged this a missing
  feature rather than a defect, and it ships as it is.
- **No "no council" answer is offered before the probe.** Section 8 of
  `/council-setup` and the mode headers do say when a council is not worth
  it, but late, after the probe has been paid for. Same judgement, same
  treatment.
- **Lines below the one that sources the plugin's config come after the
  deal.** A project config is a delta that sources the plugin's, and the deal
  runs inside that source line, so:
  - a `COUNCIL_PLANNERS` line placed below it changes the planners after the
    deal has fixed its seat list. The run still refuses a seat in play that
    took no rung and holds no pin, but the seats line, the load's and
    `/council-doctor`'s alike, can then leave out a seat that is in play or
    list one that is not. Keep that line above the source line;
  - a line below it that writes the plugin's own fallback string, such as a
    pasted `COUNCIL_MODEL_CLAUDE_ALT="${COUNCIL_MODEL_CLAUDE_ALT:-claude-sonnet-5-5}"`
    or a whole copy of an older `council.conf`, cannot be told apart from a
    deliberate hand pin on that model, and it loads, on a model the ladder
    never named. That is the price of letting a deliberate late pin work;
  - a line below it that reads a seat the deal did not reach, such as
    `COUNCIL_MODEL_CLAUDE_ALT` with planners `claude codex`, must write
    `${COUNCIL_MODEL_CLAUDE_ALT-}`: the bare `$COUNCIL_MODEL_CLAUDE_ALT` stops
    the load as an unset variable. That one fails loudly, and only under a
    mode.

## License

MIT. See [LICENSE](LICENSE).
