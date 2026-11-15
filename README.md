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
you want to plan **last**.

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
  agents/worker.md                 mechanical edits, mid model
  agents/implementer.md            the risk floor, strongest model
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
  council.txt   root, brief, config, and which planner is which letter
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

That works because three settings are written `"${VAR-default}"`, without the
colon: `COUNCIL_BUDGET_USD`, `COUNCIL_MODEL_CODEX` and `COUNCIL_AGENT_DIRS`
are the ones whose **empty value means something** — no cap, Codex's own
default model, no extra agent directories. With `"${VAR:-default}"` an
exported empty value counts as unset and the default returns, so "no cap for
this run" could not be expressed at all: measured 2026-11-14, the run refused
to start and reported that the config had overridden the environment. Every
other setting keeps the colon.

Codex takes neither flag. Its depth comes from its own model and config, so
pin `COUNCIL_MODEL_CODEX` if you want it fixed.


```sh
COUNCIL_PLANNERS="claude codex"

planner_claude() {
  claude -p --model claude-opus-5-5 --permission-mode default \
    --allowedTools Read Glob Grep "Bash(git log:*)" ... \
    --disallowedTools Edit Write NotebookEdit \
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
latest of a line.

The shipped defaults are Opus 5.5 for a planner and the arbiter and Sonnet 5.5
for the second Claude planner. **That is an entitlement guess, not a
recommendation.** If your account has Claude Fable 5.2 it is the most capable
model available and roughly twice the price of Opus 5.5; `planner_fable` ships
ready to use. `council-detect.sh` probes each candidate and reports which ones
actually answer, so you need not guess at all.

**Executor models** are pinned in each agent's frontmatter (`model:`), using
exact model IDs. To change them, edit your copy of the plugin, or copy an
agent into `~/.claude/agents/` under a new name and add that directory to
`COUNCIL_AGENT_DIRS` so `/council-assign` sees it. The risk floor is
`COUNCIL_RISK_FLOOR` (default `implementer`).

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
| A pinned model silently falls back to another | `/council-doctor` asks each model and prints the IDs the CLI reports |
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
`--max-budget-usd`, `--permission-mode default`, `--allowedTools`,
`--disallowedTools`, `--output-format json`, and `codex exec --sandbox
read-only --skip-git-repo-check --output-last-message -`. Every one of those
was confirmed present in Claude Code 2.1.325 and codex-cli 0.162.1 on
2026-11-14; `--effort` takes `low`, `medium`, `high`, `xhigh` or `max`, and
`--max-budget-usd` works only together with `--print`, which every function
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
rely on a plain allow-list in non-interactive mode, where anything not
allowed is denied. For a child **executor** that must edit and run commands,
the pattern that works is an edit-accepting mode, plus an explicit
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
- **Portability beyond one shell.** The whole chain runs under `dash` as well
  as Git Bash's `sh`. See the table in [Requirements](#requirements) for the
  per-shell invocation; the Windows traps there were each produced on purpose.

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
- **The model probe's parsing** still lists every `claude-*` ID in the CLI's
  JSON output with `grep`. If a future version reports models differently the
  probe will say it found none; it will not report a false pass.
- **Codex's model is not pinned** unless you set `COUNCIL_MODEL_CODEX`, and
  Codex takes neither `--effort` nor `--max-budget-usd`, so those settings do
  not reach it.

**Real gaps that remain, now stated plainly:**

- **The context root is not a boundary.** A read-only child agent read an
  absolute path *outside* the root with no refusal at all. Earlier versions of
  this README and of `skills/council/SKILL.md` said such a read was silently
  refused. That was wrong. The root decides where an agent starts and what its
  relative paths mean, nothing more.
- **The arbiter's blindness is enforced for Claude children only.** The run
  directory holds `council.txt`, which maps each letter to its planner, and the
  config turns a planner name into an exact model in one more read. Each child
  is now given a deny rule covering that directory, and `council-detect.sh`
  proves the rule works with a canary before you trust it. But the rule is a
  Claude Code permission rule: **it does not reach Codex**, whose read access is
  whatever that CLI grants. With Codex as a planner, the attack phase's
  blindness rests on the prompt. `/council-doctor` names every function the rule
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

## License

MIT. See [LICENSE](LICENSE).
