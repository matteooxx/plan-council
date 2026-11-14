#!/bin/sh
# Cross-attack, then arbitration, on a run produced by council-plan.sh.
#
# Usage: council-review.sh RUN_DIR [--arbitrate-only]
#   RUN_DIR           the directory council-plan.sh printed
#   --arbitrate-only  reuse the attack-*.md files already in RUN_DIR and run
#                     only the arbiter (for when the arbiter failed)
#
# Each planner attacks the other plans with its own model. The attacks run in
# parallel and are published only when all have finished, so no critic reads
# another critic's targets. The arbiter then reads everything, verifies in the
# code, and reports to stdout, which lands in RUN_DIR/arbitration.md.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
PLUGIN_ROOT=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '2,11p' "$SCRIPT_DIR/council-review.sh" | sed 's/^# \{0,1\}//'; }

RUN=""
ARBITRATE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arbitrate-only) ARBITRATE_ONLY=1; shift ;;
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

STAGE=$(council_stage "$ROOT")
trap 'rm -rf "$STAGE"' EXIT
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
  council_check_deny_used "$FNS" || true
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
council_check_deny_used arbiter || true
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
