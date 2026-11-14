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

Then run the self-check once:

```
/council-doctor
```

It checks that the scripts parse, the config loads, the planners' CLIs are
installed, and, with one tiny request per model, that **each pinned model is
the model that actually answers**.

### Requirements

- Claude Code (written against 2.1.x).
- A POSIX shell with `awk`, `sed`, `cmp`, `mktemp` and `git` (on Windows, Git
  Bash provides all of them). No Python, Node or `jq` is needed.
- Optional: the [Codex CLI](https://github.com/openai/codex), logged in. Without it, see
  [Two Claude models instead of Codex](#two-claude-models-instead-of-codex).

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
  commands/council-plan.md         /council-plan
  commands/council-review.md       /council-review
  commands/council-assign.md       /council-assign
  commands/council-doctor.md       /council-doctor
  scripts/*.sh                     what the commands run
  prompts/*.md                     the planner, attacker, arbiter and assigner prompts
  config/council.conf              planners, arbiter, risk floor
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

The defaults live in `config/council.conf`. To change them for one project,
copy it to `<your-project>/.claude/plan-council.conf`. To use one copy
everywhere, point `COUNCIL_CONFIG` at it. The file is POSIX shell, and each
planner is one function:

Every setting also **defers to the environment**, so a single run can be changed
without editing a file:

```sh
COUNCIL_PLANNERS="claude claude_alt" council-plan.sh brief.md
```

Whatever arrived that way is printed before the run starts
(`from the environment, not the config: COUNCIL_PLANNERS`). It is announced in
both directions on purpose: a value dropped in silence and a stray export in a
shell profile steering a run are the same failure wearing different clothes. If
you add a setting, keep the `VAR="${VAR:-default}"` form — a plain assignment
would override the environment without saying so.


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

Executor models are pinned in each agent's frontmatter (`model:`), using
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

The planner and arbiter functions use `claude -p`, `--model`,
`--permission-mode default`, `--allowedTools`, `--disallowedTools`,
`--output-format json`, and `codex exec --sandbox read-only
--skip-git-repo-check --output-last-message`. Permission modes in particular
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

- **Run end to end with stand-in planners, never with real models.** What was
  actually exercised, with shell-function planners that need no model:
  `council-plan.sh` publishes `plan-A.md` and `plan-B.md`; `council-review.sh`
  runs both attacks in parallel, extracts each one's closing preference, and
  reaches a verdict from the arbiter. Three invariants were checked rather than
  assumed: both planners receive a **byte-identical prompt** (same `cksum`
  recorded from inside each planner); the arbiter sees only *Plan A* and *Plan B*,
  with authorship kept out of the plan files and recorded in `council.txt`; and a
  planner that **exits 0 having written nothing** is caught, the run fails with
  status 1, and nothing is published. The JSON files parse, the scripts pass
  `bash -n`, `claude plugin validate` passes, and the hook passes 7 of 7 tests
  under `claude plugin test` (`hooks/register.test.ts`, each guard proven by a
  mutation that turned it red).
  **Not** exercised: a council with real models, and the hook inside a live
  session. Run `/council-doctor`, then a council on a small throwaway brief,
  before relying on it.
- **`claude plugin validate` advises adding an install line that is already
  there.** `README.md` carries the exact `/plugin install ... --marketplace`
  line it asks for. The advice does not change the verdict, and validation
  passes.
- **Agents, commands and skills are discovered by convention.**
  `claude plugin validate` reports the manifest and the hooks module; it does
  not list `agents/`, `commands/` or `skills/`, so their discovery was not
  confirmed by a tool.
- **CLI flags are unverified against your installed versions.** The Claude
  Code and Codex flags above come from their documented interfaces at the
  time of writing and were not executed. In particular: that
  `claude -p --permission-mode default` denies (rather than waits on)
  anything outside `--allowedTools`; that `--disallowedTools` removes
  Edit/Write from the arbiter entirely; and that `codex exec -` reads the
  prompt from stdin.
- **The model probe parses JSON with grep.** It lists every `claude-*` ID in
  the CLI's JSON output. If a future version reports models differently,
  the probe will say it found none; it will not report a false pass.
- **Model IDs go stale.** The agents pin exact IDs (`claude-opus-5-5`,
  `claude-sonnet-5-5`, `claude-haiku-5-5`). When those models are retired,
  update the frontmatter and the config; `/council-doctor` will show the
  failure. Whether an unknown ID in frontmatter fails loudly or falls back
  silently was not verified, which is why the probe exists.
- **Codex runs on its own configured default model** unless you add
  `-m <model>` to `planner_codex`. No Codex model ID is pinned, because I
  could not verify one.
- **The reviewer has a shell.** It has no Edit or Write tool, and its
  instructions forbid writing through the shell, but `Bash` can write files.
  It needs the shell to run tests. If you need a reviewer that cannot write
  at all, remove `Bash` from its `tools:` and run the tests yourself.
- **The arbiter defaults to the same model as the Claude planner.** It never
  learns which planner wrote which plan, which reduces but does not remove
  self-preference. Use a third model if you have one.
- **The subagent command guard is best effort.** It matches common
  spellings in command position. An agent determined to run `git push` via a
  script file will get through. The rule in the execution-discipline skill
  is the real control.
- **Skill and command frontmatter.** The skills use `name` and `description`,
  the commands `description` and `argument-hint`, and the commands refer to
  `${CLAUDE_PLUGIN_ROOT}`, with a fallback that finds the scripts by
  searching `~/.claude/plugins/`. These conventions were not confirmed
  against the installed version's plugin loader.
- **Cost is not capped.** Nothing stops a run from spending what the models
  spend. With N planners a run is 2N + 1 long model runs, plus one for the
  assignment.
- **Planner names and paths.** Planner names may use only letters, digits
  and `_`. `COUNCIL_AGENT_DIRS` is space-separated, so its paths cannot
  contain spaces.

## License

MIT. See [LICENSE](LICENSE).
