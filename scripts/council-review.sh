#!/bin/sh
# Cross-attack, then arbitration, on a run produced by council-plan.sh.
#
# Usage: council-review.sh RUN_DIR [--arbitrate-only] [--no-seat-check]
#   RUN_DIR           the directory council-plan.sh printed
#   --arbitrate-only  reuse the attack-*.md files already in RUN_DIR and run
#                     only the arbiter (for when the arbiter failed)
#   --no-seat-check   skip calling each claude seat once, before each phase,
#                     to read the CLI's record of a refused read of RUN_DIR
#
# Each planner attacks the other plans with its own model. The attacks run in
# parallel and are published only when all have finished, so no critic reads
# another critic's targets. The arbiter then reads everything, verifies in the
# code, and reports to stdout, which lands in RUN_DIR/arbitration.md.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
PLUGIN_ROOT=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '2,13p' "$SCRIPT_DIR/council-review.sh" | sed 's/^# \{0,1\}//'; }

RUN=""
ARBITRATE_ONLY=0
SEAT_CHECK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --arbitrate-only) ARBITRATE_ONLY=1; shift ;;
    --no-seat-check) SEAT_CHECK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) council_die "unknown option: $1" ;;
    *) [ -z "$RUN" ] || council_die "only one run directory"; RUN=$1; shift ;;
  esac
done
[ -n "$RUN" ] || { usage >&2; exit 2; }

RUN=$(council_absdir "$RUN") || council_die "run directory not found: $RUN"
MANIFEST="$RUN/council.txt"
[ -f "$MANIFEST" ] || council_die "not a council run (no council.txt): $RUN"
[ -s "$RUN/brief.md" ] || council_die "brief.md missing or empty in $RUN"

# --- A run directory git can read is refused ----------------------------------
# The seats keep git log, git show and git status, and the rule that denies
# them the run directory is matched against the text of a command, not the
# path it resolves to, so a command that spells the path another way walks
# past it (measured 2026-11-18). Those three read only what git has: git log
# and git show print what git tracks, and git status names what it does not
# ignore. Under the default layout ROOT/.council holds a .gitignore of "*" and
# nothing in it is tracked, and there all three printed nothing about a run
# (measured 2026-11-18). But council-plan.sh --out places a run anywhere, a
# tracked path included, and there council.txt, which maps each letter to its
# planner, is one git show away.
#
# So git is asked, from inside the run directory, for every file in it that
# it tracks (--cached) or does not ignore (--others --exclude-standard): the
# files git log and git show can print and the ones git status would name.
# Any answer at all stops the review, for the attacks and for
# --arbitrate-only alike, since the arbiter keeps the same three tools. A run
# directory outside every git work tree passes: there is nothing there for
# them to read. There is no override, on purpose.
#
# Not checked: the history. A file that was committed and then removed from
# the index stays readable to git log and git show, and this asks only about
# the index and the working tree.
if RUN_IN_GIT=$(cd "$RUN" && git rev-parse --is-inside-work-tree 2>/dev/null) \
  && [ "$RUN_IN_GIT" = true ]; then
  RUN_GIT_SEEN=$(cd "$RUN" && git ls-files --cached --others --exclude-standard -- .) \
    || council_die "the run directory $RUN is inside a git work tree, and git could not be asked which files in it it tracks or does not ignore, so whether git log, git show and git status can read it is unknown. Nothing has been run."
  if [ -n "$RUN_GIT_SEEN" ]; then
    council_die "the run directory $RUN is inside a git work tree, and git tracks or does not ignore files in it (for example: $(printf '%s\n' "$RUN_GIT_SEEN" | head -n 5 | paste -s -d ' ' -)). The attackers and the arbiter keep git log, git show and git status, and the rule that denies them the run directory is matched against the text of a command, not the path it resolves to, so those three walk past it: git log and git show can print a tracked file there, council.txt included, which maps each letter to its planner, and git status can name any file there that git does not ignore. The blindness the review phase claims would not hold. Move the run directory outside the repository and review it there, or place it where git ignores it and tracks nothing in it, as the default ROOT/.council layout does. A file there that was ever committed stays in the history whatever is done now. There is no option to skip this check. Nothing has been run."
  fi
fi
ROOT=$(council_manifest_get "$MANIFEST" root)
ROOT=$(council_absdir "$ROOT") || council_die "context root from council.txt no longer exists: $ROOT"

council_load_config "$ROOT" "$PLUGIN_ROOT"
type arbiter >/dev/null 2>&1 || council_die "no arbiter function in $COUNCIL_CONFIG_USED"

LETTERS=$(sed -n 's/^planner\.\([A-H]\)=.*/\1/p' "$MANIFEST" | tr '\n' ' ')
COUNT=0
for L in $LETTERS; do
  council_answer_ok "$RUN/plan-$L.md" || council_die "plan-$L.md is missing or empty; rerun the planning"
  name=$(council_manifest_get "$MANIFEST" "planner\\.$L")
  type "planner_$name" >/dev/null 2>&1 || council_die "planner_$name (Plan $L) is no longer in the config"
  COUNT=$((COUNT + 1))
done
[ "$COUNT" -ge 2 ] || council_die "need at least two plans, found $COUNT"

# --- Each planner attacks with its own model ----------------------------------
# The config is reloaded here and planner_<name> is called with whatever is in
# effect now, while this script promises that each planner attacks with the
# model it planned with. Under a mode the seats are dealt on every load, so a
# one-run COUNCIL_MODE=, or a mode file whose COUNCIL_STRONGEST_FOR changed,
# moves a Claude planner to another model in silence. So the model in effect for
# each Claude planner is compared with the model.<letter>= council-plan.sh
# recorded, and a difference stops the review here, before anything is paid
# for. The scope is Decision 7's, and each clause has its reason:
#   - only with a mode, recorded or current: without one the by-hand path is
#     what the first arbitration left it;
#   - only when attacks will run: --arbitrate-only calls no planner;
#   - only when council.txt records planner models at all, so a run made before
#     those lines existed still reviews.
# Only claude and claude_alt are compared: Codex's recorded model is what it
# announced, which this script cannot know until Codex has been called.
if [ "$ARBITRATE_ONLY" -eq 0 ]; then
  RUN_MODE=$(council_manifest_get "$MANIFEST" mode)
  if [ -n "$RUN_MODE" ] || [ -n "${COUNCIL_MODE-}" ] || [ -n "${COUNCIL_MODE_APPLIED-}" ]; then
    if grep -q '^model\.[A-H]=' "$MANIFEST"; then
      MOVED=""
      for L in $LETTERS; do
        name=$(council_manifest_get "$MANIFEST" "planner\\.$L")
        case "$name" in
          claude)     seat=COUNCIL_MODEL_CLAUDE ;;
          claude_alt) seat=COUNCIL_MODEL_CLAUDE_ALT ;;
          *) continue ;;
        esac
        grep -q "^model\\.$L=" "$MANIFEST" || council_die "council.txt records a model for some planners but not for Plan $L ($name), so whether it would attack on the model it planned with cannot be checked. The manifest has been edited or truncated; rerun the planning."
        was=$(council_manifest_get "$MANIFEST" "model\\.$L")
        eval "now=\${$seat-}"
        [ "$was" = "$now" ] || MOVED="$MOVED Plan $L ($name) planned on '$was' and would attack on '$now' ($seat);"
      done
      if [ -n "$MOVED" ]; then
        if [ "$RUN_MODE" = "${COUNCIL_MODE_APPLIED-}" ]; then
          # Same mode, so the mode is not what moved the seat. Say what else
          # can be seen to differ: the ladder the seats were dealt from.
          if grep -q '^ladder=' "$MANIFEST"; then
            RUN_LADDER="ladder '$(council_manifest_get "$MANIFEST" ladder)'"
          else
            RUN_LADDER=""
          fi
          if [ -z "$RUN_LADDER" ]; then
            # council-plan.sh writes ladder= beside mode=, so a manifest with
            # mode= and no ladder= has been edited or truncated. There is no
            # recorded ladder to compare with or to put back.
            WHY="council.txt records no ladder (it has no ladder= line, although council-plan.sh writes one beside mode=, so the manifest has been edited or truncated), so whether the ladder is what moved the seat cannot be told from here; the ladder in effect now is '${COUNCIL_MODEL_LADDER-}'. Pin the seat by hand for this review to the model council.txt records."
          elif [ "$RUN_LADDER" = "ladder '${COUNCIL_MODEL_LADDER-}'" ]; then
            WHY="council.txt records $RUN_LADDER, and that is the ladder in effect now too, so something else in effect now moved the seat, such as a seat pinned by hand in the config or the environment, or the mode file's COUNCIL_STRONGEST_FOR. Pin the seat by hand for this review to the model council.txt records."
          else
            WHY="council.txt records $RUN_LADDER; the ladder in effect now is '${COUNCIL_MODEL_LADDER-}'. Put the recorded ladder back for this review if that is what changed, or pin the seat by hand for this review to the model council.txt records."
          fi
          council_die "a planner would attack with a different model than the one it planned with:${MOVED%;}. The run was planned under mode '${RUN_MODE}' and this review loads the same mode, so the mode is not what changed. $WHY Each planner is meant to attack with its own model. Nothing has been run."
        fi
        council_die "a planner would attack with a different model than the one it planned with:${MOVED%;}. The run was planned under mode '${RUN_MODE}' (council.txt mode=, empty means no mode); this review loads mode '${COUNCIL_MODE_APPLIED-}' (empty, again, means no mode). Each planner is meant to attack with its own model. Review under the mode the run was planned with, or pin the seat by hand for this review to the model council.txt records. Nothing has been run."
      fi
    fi
  fi
fi

STAGE=$(council_stage "$ROOT")
trap 'council_seat_unplant; rm -rf "$STAGE"' EXIT
trap 'exit 130' INT TERM

plans_block() {
  for P in $LETTERS; do
    printf '\n\n---\n\n# Plan %s\n\n' "$P"
    cat "$RUN/plan-$P.md"
  done
}

# The run directory holds council.txt, which maps each letter to its planner,
# and with the config that is one read away from the model. Every child agent
# here is handed what it needs in its own prompt, so the directory is denied
# outright. Measured 2026-11-14: without this an agent with the arbiter's own
# flags found and read council.txt unaided.
COUNCIL_DENY=$(council_deny_rule "$RUN")
# And every earlier run too: an arbiter refused this run's directory then read
# an earlier run's council.txt and reported its mapping, which in a project
# that always runs the same planners in the same order is this run's mapping.
COUNCIL_DENY2=$(council_deny_all_runs "$ROOT")
council_assert_not_root "$ROOT" "$COUNCIL_DENY" "$COUNCIL_DENY2"
export COUNCIL_DENY COUNCIL_DENY2

# --- Cross-attack -------------------------------------------------------------
if [ "$ARBITRATE_ONLY" -eq 0 ]; then
  for L in $LETTERS; do
    [ ! -e "$RUN/attack-$L.md" ] || council_die "attack-$L.md already exists; use --arbitrate-only or a fresh run"
  done
  JOBS=""
  FNS=""
  for L in $LETTERS; do
    name=$(council_manifest_get "$MANIFEST" "planner\\.$L")
    {
      cat "$PLUGIN_ROOT/prompts/attack.md"
      printf '\n**Your own plan is Plan %s.**\n\n---\n\n# The brief\n\n' "$L"
      cat "$RUN/brief.md"
      plans_block
      printf '\n'
    } > "$STAGE/prompt-$L.md"
    JOBS="$JOBS $L:planner_$name"
    FNS="$FNS planner_$name"
  done
  COUNCIL_PHASE=attack
  export COUNCIL_PHASE
  council_require_deny_used "$FNS"
  # The seat check (council_seat_check in lib.sh), on the run directory as it
  # is now, with the plans in it: each claude attacker is called once and the
  # CLI's record must show a read there refused. Recorded in council.txt as
  # seatcheck.attack.
  if [ "$SEAT_CHECK" -eq 1 ]; then
    council_seat_check "$ROOT" "$RUN" "$STAGE"
  else
    council_seat_skip
  fi
  council_seat_record_into "$MANIFEST" attack
  council_say "cross-attack: $COUNT attacks in parallel, from $ROOT (effort $COUNCIL_ATTACK_EFFORT)"
  # shellcheck disable=SC2086
  council_run_parallel "$ROOT" "$STAGE" $JOBS
  STATUS=$?
  for L in $LETTERS; do
    if council_answer_ok "$STAGE/answer-$L.md"; then
      cp "$STAGE/answer-$L.md" "$RUN/attack-$L.md"
      word=$(council_last_word "$RUN/attack-$L.md")
      case "$word" in
        OWN|THIRD|[A-H]) council_say "attack by the author of Plan $L closes with: $word" ;;
        *) council_say "WARNING: attack-$L.md does not close with OWN, THIRD or a plan letter (last line: '$word')" ;;
      esac
    fi
  done
  council_keep_logs "$STAGE" "$RUN" "attack-"
  [ "$STATUS" -eq 0 ] || council_die "at least one attack failed; not arbitrating on a partial picture"
  rm -f "$STAGE"/*.log "$STAGE"/answer-*.md "$STAGE"/prompt-*.md
fi

for L in $LETTERS; do
  council_answer_ok "$RUN/attack-$L.md" || council_die "attack-$L.md is missing or empty"
done

# --- Arbitration ----------------------------------------------------------------
# Record the arbiter's model, written just before the arbiter is called so the
# line exists only for a review that reached arbitration. A rerun with
# --arbitrate-only replaces it rather than adding a second line, so the record
# names the model of the arbitration now in arbitration.md.
#
# Both refusals below come after the attacks, which are in RUN by then, so
# each says how to get the arbitration without paying for them again. grep's
# exit 1 only means it kept no line; exit 2 means the manifest could not be
# read (gone, or unreadable), and writing the two arbiter lines alone would
# replace the run record with them.
KEEP=$(grep -v -e '^model\.arbiter=' -e '^model\.arbiter\.from=' "$MANIFEST")
[ "$?" -le 1 ] || council_die "cannot read $MANIFEST to record model.arbiter, so it was not rewritten and the arbiter was not called. The attacks are in $RUN (attack-*.md): once council.txt can be read again, rerun with --arbitrate-only to arbitrate on them without running the attacks again."
{
  [ -z "$KEEP" ] || printf '%s\n' "$KEEP"
  printf 'model.arbiter=%s\n' "$COUNCIL_MODEL_ARBITER"
  printf 'model.arbiter.from=%s\n' "the setting COUNCIL_MODEL_ARBITER in effect for this review, which the plugin's own arbiter function passes as --model; what was asked for, not proof of what answered"
} > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST" || { rm -f "$MANIFEST.tmp"; council_die "cannot record model.arbiter in $MANIFEST, so the arbiter was not called. The attacks are in $RUN (attack-*.md): once council.txt can be written, rerun with --arbitrate-only to arbitrate on them without running the attacks again."; }
[ ! -e "$RUN/arbitration.md" ] || mv "$RUN/arbitration.md" "$RUN/arbitration.$(date +%Y%m%d-%H%M%S).old.md"
{
  cat "$PLUGIN_ROOT/prompts/arbiter.md"
  printf '\n---\n\n# The brief\n\n'
  cat "$RUN/brief.md"
  plans_block
  for L in $LETTERS; do
    printf '\n\n---\n\n# Attack by the author of Plan %s\n\n' "$L"
    cat "$RUN/attack-$L.md"
  done
  printf '\n'
} > "$STAGE/prompt-arbiter.md"

COUNCIL_PHASE=arbitrate
export COUNCIL_PHASE
council_require_deny_used arbiter
# The seat check for the arbiter, recorded as seatcheck.arbitrate; a rerun
# with --arbitrate-only replaces those lines.
if [ "$SEAT_CHECK" -eq 1 ]; then
  council_seat_check "$ROOT" "$RUN" "$STAGE"
else
  council_seat_skip
fi
council_seat_record_into "$MANIFEST" arbitrate
council_say "arbitration: running from $ROOT (effort $COUNCIL_ARBITER_EFFORT)"
council_run_parallel "$ROOT" "$STAGE" "arbiter:arbiter"
STATUS=$?
council_keep_logs "$STAGE" "$RUN" "arbiter-"
[ "$STATUS" -eq 0 ] || council_die "the arbiter failed; rerun with --arbitrate-only"
cp "$STAGE/answer-arbiter.md" "$RUN/arbitration.md"

VERDICT=$(council_last_word "$RUN/arbitration.md")
case "$VERDICT" in
  PASS|FIX|RETHINK) council_say "verdict: $VERDICT" ;;
  *) council_say "WARNING: arbitration.md does not close with PASS, FIX or RETHINK (last line: '$VERDICT')" ;;
esac
council_say "arbitration: $RUN/arbitration.md"
council_say "next: write the final plan from the arbiter's decisions (the arbiter does not write it), then council-assign.sh"
printf '%s\n' "$RUN/arbitration.md"
