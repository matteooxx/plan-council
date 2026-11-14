#!/bin/sh
# Blind parallel planning: every configured planner receives the same prompt
# at the same time and writes its own plan without seeing the others.
#
# Usage: council-plan.sh BRIEF [--root DIR] [--out DIR]
#   BRIEF       a Markdown file describing what to plan
#   --root DIR  the context root: the directory holding the code AND the
#               working material around it (notes, earlier plans). Every
#               planner is started from here and can read only under it.
#               Default: the current directory.
#   --out DIR   where the run is published. Default: ROOT/.council/<timestamp>
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
PLUGIN_ROOT=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '2,12p' "$SCRIPT_DIR/council-plan.sh" | sed 's/^# \{0,1\}//'; }

BRIEF=""
ROOT="."
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || council_die "--root needs a directory"; ROOT=$2; shift 2 ;;
    --out)  [ $# -ge 2 ] || council_die "--out needs a directory"; OUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) council_die "unknown option: $1" ;;
    *) [ -z "$BRIEF" ] || council_die "only one brief, got '$BRIEF' and '$1'"; BRIEF=$1; shift ;;
  esac
done
[ -n "$BRIEF" ] || { usage >&2; exit 2; }

# Absolute paths first, before anything changes directory.
BRIEF_ABS=$(council_absfile "$BRIEF") || council_die "brief not found: $BRIEF"
[ -s "$BRIEF_ABS" ] || council_die "brief is empty: $BRIEF_ABS"
ROOT=$(council_absdir "$ROOT") || council_die "context root not found: $ROOT"

council_load_config "$ROOT" "$PLUGIN_ROOT"
council_check_planners

if [ -z "$OUT" ]; then
  council_ignore_dir "$ROOT/.council"
  OUT="$ROOT/.council/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT" || council_die "cannot create $OUT"
OUT=$(council_absdir "$OUT") || council_die "cannot resolve $OUT"
[ -z "$(ls -A "$OUT")" ] || council_die "output directory is not empty: $OUT"

STAGE=$(council_stage "$ROOT")
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 130' INT TERM

# One prompt, built once. Every planner gets these exact bytes; the output
# path is not in the prompt at all, it is the runner's business.
PROMPT="$STAGE/prompt.md"
{
  cat "$PLUGIN_ROOT/prompts/plan.md"
  printf '\n'
  cat "$BRIEF_ABS"
  printf '\n'
} > "$PROMPT"
[ "$(council_size "$PROMPT")" -gt "$(council_size "$BRIEF_ABS")" ] || council_die "prompt assembly failed: $PROMPT"

# Jobs are labelled by letter, never by planner name: the stage files and the
# published logs then carry a letter, so no log attributes a plan to a model.
JOBS=""
FNS=""
i=0
for name in $COUNCIL_PLANNERS; do
  i=$((i + 1))
  letter=$(council_letter "$i")
  cp "$PROMPT" "$STAGE/prompt-$letter.md"
  JOBS="$JOBS $letter:planner_$name"
  FNS="$FNS planner_$name"
done
# Belt and braces: prove the prompts are byte-identical before spending.
i=0
for name in $COUNCIL_PLANNERS; do
  i=$((i + 1))
  letter=$(council_letter "$i")
  cmp -s "$PROMPT" "$STAGE/prompt-$letter.md" || council_die "prompt for planner $letter differs"
done

# Keep every planner out of the run directory. Nothing it needs is in there,
# and once the plans are published the attribution is.
COUNCIL_DENY=$(council_deny_rule "$OUT")
# Planning deliberately leaves earlier runs readable: the prompt invites a
# planner to use prior council runs as working material, and this run's
# directory holds nothing yet.
COUNCIL_DENY2=$COUNCIL_DENY
COUNCIL_PHASE=plan
export COUNCIL_DENY COUNCIL_DENY2 COUNCIL_PHASE
council_check_deny_used "$FNS" || true

council_say "context root: $ROOT"
council_say "config:       $COUNCIL_CONFIG_USED"
council_say "effort:       planners $COUNCIL_PLANNER_EFFORT${COUNCIL_BUDGET_USD:+, budget cap \$$COUNCIL_BUDGET_USD per run}"
council_say "planners:     $COUNCIL_PLANNERS (in parallel; this can take many minutes)"

# shellcheck disable=SC2086
council_run_parallel "$ROOT" "$STAGE" $JOBS
STATUS=$?

# Publish only now that every planner has finished: nobody could have read
# a rival's plan while writing.
cp "$PROMPT" "$OUT/prompt.md"
cp "$BRIEF_ABS" "$OUT/brief.md"
{
  printf 'root=%s\n' "$ROOT"
  printf 'brief=%s\n' "$BRIEF_ABS"
  printf 'config=%s\n' "$COUNCIL_CONFIG_USED"
  printf 'created=%s\n' "$(date)"
} > "$OUT/council.txt"
i=0
for name in $COUNCIL_PLANNERS; do
  i=$((i + 1))
  letter=$(council_letter "$i")
  printf 'planner.%s=%s\n' "$letter" "$name" >> "$OUT/council.txt"
  if council_answer_ok "$STAGE/answer-$letter.md"; then
    cp "$STAGE/answer-$letter.md" "$OUT/plan-$letter.md"
  fi
done
council_keep_logs "$STAGE" "$OUT" "plan-"

if [ "$STATUS" -ne 0 ]; then
  council_say "at least one planner failed; the comparison is not valid until every plan exists."
  council_say "run directory (partial): $OUT"
  exit 1
fi

council_say "plans published in $OUT (plan-A.md, plan-B.md, ...; which planner is which is in council.txt)"
council_say "next: council-review.sh \"$OUT\""
printf '%s\n' "$OUT"
