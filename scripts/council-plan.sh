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
# Codex echoes this prompt into the stderr log that council_codex_announced_model
# reads the planner's model from, and that parser trusts the banner only up to
# the first line that is not shaped like a field. The prompt's first line must
# therefore not be shaped like one, or the echo would carry on the banner's run
# of fields: checked here, on the bytes every planner will get, before any is
# called. Only the first line: when it is not a field the parser reads no line
# of the prompt at all, whatever follows.
if council_prompt_opens_with_field "$PROMPT"; then
  council_die "the prompt's first line, which is the first line of $PLUGIN_ROOT/prompts/plan.md, is shaped like a field of Codex's stderr banner (lower-case words, a colon and a space). Codex echoes the prompt into the log the run record reads Codex's model from, so a prompt that opens like a field could let the brief be read as part of that banner. Make the first line of prompts/plan.md something else, such as the Markdown heading it ships with. Nothing has been run."
fi

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
council_assert_not_root "$ROOT" "$COUNCIL_DENY" "$COUNCIL_DENY2"
export COUNCIL_DENY COUNCIL_DENY2 COUNCIL_PHASE
council_require_deny_used "$FNS"

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
  # The mode that dealt the seats (empty: no mode, the by-hand path), and the
  # ladder it drew from. council-review.sh reads mode= to decide whether to
  # check that each Claude planner still attacks on the model it planned with.
  printf 'mode=%s\n' "$COUNCIL_MODE_APPLIED"
  printf 'ladder=%s\n' "$COUNCIL_MODEL_LADDER"
} > "$OUT/council.txt"
# Which model each planner ran, as far as plan-council can know it. Every
# model.<letter>= line has a model.<letter>.from= line saying where the value
# came from, because none of them is proof of what answered:
#   claude, claude_alt  the setting in effect, which the plugin's own planner
#                       functions pass as --model (a project config that
#                       redefines planner_<name> may pass something else, and
#                       this script cannot see that);
#   codex               the model Codex ANNOUNCED in its own stderr banner (see
#                       council_codex_announced_model), or 'unknown';
#   anything else       'unknown': its function is the config's business.
#
# There is deliberately no refusal when COUNCIL_MODEL_CODEX and the announced
# model differ. Measured 2026-11-15 (task R2): the banner echoes the -m value
# verbatim, even for an ID that does not exist, so pin and banner can only
# agree and such a check could never fire for the reason it would claim. The
# case it would be meant to catch -- an ID Codex does not have -- already makes
# Codex exit 101, so that planner fails and this run stops on its own. Record
# only.
i=0
for name in $COUNCIL_PLANNERS; do
  i=$((i + 1))
  letter=$(council_letter "$i")
  printf 'planner.%s=%s\n' "$letter" "$name" >> "$OUT/council.txt"
  case "$name" in
    claude)
      _pm=$COUNCIL_MODEL_CLAUDE
      _pf="the setting COUNCIL_MODEL_CLAUDE in effect for this run, which the plugin's own planner_claude passes as --model; what was asked for, not proof of what answered" ;;
    claude_alt)
      _pm=$COUNCIL_MODEL_CLAUDE_ALT
      _pf="the setting COUNCIL_MODEL_CLAUDE_ALT in effect for this run, which the plugin's own planner_claude_alt passes as --model; what was asked for, not proof of what answered" ;;
    codex)
      _pm=$(council_codex_announced_model "$STAGE/stderr-$letter.log")
      if [ "$_pm" = unknown ]; then
        _pf="no model read: logs/plan-stderr-$letter.log does not start with a complete Codex banner (Codex's first line, a separator, field lines only, a closing separator) whose model lines give one well-formed value"
      else
        _pf="announced by Codex in the banner of logs/plan-stderr-$letter.log; what was asked for, not proof of what answered"
      fi ;;
    *)
      _pm=unknown
      _pf="plan-council cannot tell which model planner_$name runs" ;;
  esac
  printf 'model.%s=%s\n' "$letter" "$_pm" >> "$OUT/council.txt"
  printf 'model.%s.from=%s\n' "$letter" "$_pf" >> "$OUT/council.txt"
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
