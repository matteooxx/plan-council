#!/bin/sh
# Blind parallel planning: every configured planner receives the same prompt
# at the same time and writes its own plan without seeing the others.
#
# Usage: council-plan.sh BRIEF [--root DIR] [--out DIR] [--no-model-check]
#   BRIEF       a Markdown file describing what to plan
#   --root DIR  the context root: the directory holding the code AND the
#               working material around it (notes, earlier plans). Every
#               planner is started from here and can read only under it.
#               Default: the current directory.
#   --out DIR   where the run is published. Default: ROOT/.council/<timestamp>
#   --no-model-check  under a mode, skip asking each Claude model ID in play
#               for one word before the planners run (the identity gate)
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
PLUGIN_ROOT=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '2,13p' "$SCRIPT_DIR/council-plan.sh" | sed 's/^# \{0,1\}//'; }

BRIEF=""
ROOT="."
OUT=""
MODEL_CHECK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || council_die "--root needs a directory"; ROOT=$2; shift 2 ;;
    --out)  [ $# -ge 2 ] || council_die "--out needs a directory"; OUT=$2; shift 2 ;;
    --no-model-check) MODEL_CHECK=0; shift ;;
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
# The instructions first. Measured 2026-11-16: with prompts/plan.md removed,
# cat failed, the prompt held the brief and two newlines, the size check below
# still passed because that is larger than the brief, and both planners were
# called on a brief with no instructions at all. A file that is missing, or
# holds no text or cannot be read, is refused here, before anything is paid.
PLAN_MD="$PLUGIN_ROOT/prompts/plan.md"
[ -f "$PLAN_MD" ] || council_die "the planning instructions are missing: $PLAN_MD does not exist. Every planner's prompt starts with that file; without it each planner would be paid to read the brief with no instructions. Restore prompts/plan.md, or reinstall the plugin. Nothing has been run."
grep -q '[^[:space:]]' "$PLAN_MD" 2>/dev/null || council_die "the planning instructions are empty or unreadable: $PLAN_MD holds no text that can be read. Every planner's prompt starts with that file; without it each planner would be paid to read the brief with no instructions. Restore prompts/plan.md, or reinstall the plugin. Nothing has been run."
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

# The identity gate. Under a mode, each distinct Claude model ID in play is
# asked once for one word, before any planner is paid for, and the run stops
# unless the call exits 0 and the CLI billed exactly that ID. It is a gate and
# never a selection: it chooses, reorders and substitutes nothing, and on a
# mismatch it stops rather than fall back.
#
# Why: the planning calls run without JSON output and leave empty logs, so
# nothing afterwards can say which model served them, and whether a retired
# ID falls back silently is unverified. This narrows that gap, and only that
# far: it shows what answered the check when planning started, not what
# serves the planning calls. Its price is one one-word call per distinct ID,
# at most three per council, announced before the first is made; after each
# call, the costUSD figures found on its stdout are added up and printed.
#
# The seats in play are the Claude planners in COUNCIL_PLANNERS and the
# arbiter; two seats on one ID are one call. With no mode it does nothing and
# prints nothing: the seats are then the user's own business, as they are for
# council_recheck_seats. It runs after every check that costs nothing, so a
# run that would be refused anyway is refused before this spends.
MODELCHECK=""
GATE_N=0
if [ -n "${COUNCIL_MODE_APPLIED:-}" ]; then
  if [ "$MODEL_CHECK" -eq 0 ]; then
    MODELCHECK=skipped
    council_say "model check: skipped (--no-model-check). No Claude model ID in play has been asked whether it answers as itself; council.txt records that."
  else
    GATE_SEATS=""
    for name in $COUNCIL_PLANNERS; do
      case "$name" in
        claude)     GATE_SEATS="$GATE_SEATS COUNCIL_MODEL_CLAUDE" ;;
        claude_alt) GATE_SEATS="$GATE_SEATS COUNCIL_MODEL_CLAUDE_ALT" ;;
      esac
    done
    GATE_SEATS="$GATE_SEATS COUNCIL_MODEL_ARBITER"
    # Distinct IDs in seat order, each with the seats that hold it. A seat
    # value is a hand pin as often as a ladder rung and is not validated, so it
    # is only ever copied and compared here, never split or run as code.
    for seat in $GATE_SEATS; do
      eval "id=\${$seat-}"
      k=0
      dup=0
      while [ "$k" -lt "$GATE_N" ]; do
        k=$((k + 1))
        eval "prev=\$GATE_ID_$k"
        if [ "$prev" = "$id" ]; then
          eval "GATE_SEATS_$k=\"\$GATE_SEATS_$k \$seat\""
          dup=1
        fi
      done
      [ "$dup" -eq 1 ] && continue
      GATE_N=$((GATE_N + 1))
      eval "GATE_ID_$GATE_N=\$id"
      eval "GATE_SEATS_$GATE_N=\$seat"
    done
    # Values that cannot be a model ID are refused here, before the price line
    # and before any call: an empty seat has nothing to ask, and no model ID
    # holds whitespace. Without this, a spaced value was paid for and then
    # refused with a message saying it did not include itself.
    k=0
    while [ "$k" -lt "$GATE_N" ]; do
      k=$((k + 1))
      eval "id=\$GATE_ID_$k"
      eval "seats=\$GATE_SEATS_$k"
      [ -n "$id" ] || council_die "the model check found $seats empty, so there is no ID to ask. Nothing has been run: the model check made no call."
      case "$id" in
        *[[:space:]]*) council_die "$seats holds '$id', which contains whitespace (a space, a tab or a line break), so it cannot be a model ID. Pin the exact ID you mean. Nothing has been run: the model check made no call." ;;
      esac
    done
    if [ "$GATE_N" -eq 1 ]; then calls="one one-word call"; else calls="$GATE_N one-word calls"; fi
    council_say "model check: before any planner is paid for, each distinct Claude model ID in play is asked for one word with JSON output, to see that it answers as itself: $calls to the claude CLI (a council makes at most three). Each is a full CLI session, billed as such; after each, the costUSD figures found on its stdout are added up and printed. --no-model-check skips this."
    k=0
    while [ "$k" -lt "$GATE_N" ]; do
      k=$((k + 1))
      eval "id=\$GATE_ID_$k"
      eval "seats=\$GATE_SEATS_$k"
      # Only the call is shared with the doctor, which reads it its own way;
      # the reading below is shared with the setup's probe, and nothing else
      # is. stdout and stderr are kept apart and the status is taken at once:
      # a failed call can name the model it failed on, and a fallback can be
      # announced on stderr by name, so neither status nor stderr may be
      # passed over. What counts is what the CLI billed: the "claude-..." keys
      # of modelUsage on stdout. stderr is only quoted, never read for IDs.
      out=$(council_probe_call "$id" 2> "$STAGE/probe-err")
      rc=$?
      # The billed list is read with council_billed_ids in lib.sh, the one
      # reader of a reply, which the setup's probe in council-detect.sh uses
      # too, so both take the same billed list from the same reply. Its
      # comment says what it reads. It gives "!" for a stdout it cannot read
      # and nothing when no billed ID is named; both are refused below.
      rep=$(printf '%s\n' "$out" | council_billed_ids)
      # The cost line: the sum of every numeric costUSD figure on this call's
      # stdout, written "costUSD": with any spaces after the colon and then a
      # digit, wherever it sits: in modelUsage or beside it, in the object the
      # reader read or after it. It is deliberately not limited to what the
      # reader read: a call whose output is refused as unreadable was still
      # paid for, and that is when the figure matters most. It decides
      # nothing, and the messages say what it is: a sum of what was found,
      # not the price the CLI charged. A null, a string or a missing value is
      # no figure and is never read as 0. A figure written another way (a
      # space before the colon, a tab after it) is not found, so finding none
      # does not mean the CLI reported none.
      cost=$(printf '%s' "$out" | grep -o '"costUSD": *[0-9][0-9.eE+-]*' | sed 's/.*: *//' | awk '{ s += $1; n++ } END { if (n) printf "%.6g", s }')
      if [ -n "$cost" ]; then
        costmsg="The costUSD figures on that call's stdout add up to $cost USD."
      else
        costmsg="This check found no numeric costUSD figure on that call's stdout, so it cannot say what that call cost."
      fi
      excerpt=$({ printf '%s\n' "$out"; cat "$STAGE/probe-err" 2>/dev/null; } | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200)
      done_msg="No planner has been run: the model check made $k one-word call(s), and nothing else was called."
      [ "$rc" -eq 0 ] || council_die "the model check asked '$id' ($seats) for one word, and the claude CLI exited with status $rc: the call failed, so nothing it printed shows what answered. First 200 chars of its output: $excerpt. $costmsg $done_msg"
      [ "$rep" != "!" ] || council_die "the model check asked '$id' ($seats) for one word with JSON output, and what the CLI printed on stdout does not open with one complete JSON object, names modelUsage more than once among its own keys, or spells a key the check reads with a backslash escape, so what it billed cannot be read and whether '$id' answers as itself cannot be told. First 200 chars: $excerpt. $costmsg $done_msg --no-model-check runs without this check."
      [ -n "$rep" ] || council_die "the model check asked '$id' ($seats) for one word with JSON output and found no model ID among what the CLI billed (the keys of modelUsage in its JSON output), so whether '$id' answers as itself cannot be told. First 200 chars: $excerpt. $costmsg $done_msg --no-model-check runs without this check."
      # The gate's own comparison, exact: '$id' must equal one billed ID. It
      # does not share the doctor's prefix test, under which a report of
      # claude-x-10 alone passes a request for claude-x-1. The list is joined
      # by single spaces, and '$id' holds no whitespace (refused above), so it
      # can only match one whole entry.
      case " $rep " in
        *" $id "*) ;;
        *) council_die "the model check asked '$id' ($seats) for one word, and the CLI billed '$rep', which does not include '$id'. Another model may be answering for that ID: a fallback, a retired ID, or an alias. Pin the exact ID you mean; --no-model-check runs without this check. $costmsg $done_msg" ;;
      esac
      eval "GATE_REP_$k=\$rep"
      council_say "model check: '$id' ($seats) answered as itself; the CLI billed: $rep. $costmsg"
    done
    # The limit an exact comparison does not close: the billed list can also
    # hold the CLI's own background calls, and nothing in it tells those apart
    # from the call asked for. An ID that is itself the CLI's background model
    # can therefore be found in its own list whatever answered. Not closable
    # here, and not a reason to refuse a legitimate pin. When this run shows
    # it -- an ID in play also turned up in the list for a different ID -- say
    # so once for that ID. A guess from the name alone would be a guess;
    # council.txt states the limit for every run.
    k=0
    while [ "$k" -lt "$GATE_N" ]; do
      k=$((k + 1))
      eval "id=\$GATE_ID_$k"
      eval "seats=\$GATE_SEATS_$k"
      j=0
      bg=""
      while [ "$j" -lt "$GATE_N" ]; do
        j=$((j + 1))
        [ "$j" -ne "$k" ] || continue
        eval "rep=\$GATE_REP_$j"
        case " $rep " in
          *" $id "*) bg=1 ;;
        esac
      done
      [ -z "$bg" ] || council_say "model check: note: '$id' ($seats) also turned up in what the CLI billed for another ID, which suggests the CLI uses it for its own background calls; such an ID can be listed whatever answered, so finding it in its own answer shows nothing about what answered '$id': for that ID this check is no evidence. council.txt records the same limit."
    done
    MODELCHECK=passed
  fi
fi

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
  # The identity gate's outcome, under a mode only. Each modelcheck.<n> is an
  # ID that answered as itself just before the planners started; what served
  # the planning calls afterwards is not something this can know.
  case "$MODELCHECK" in
    passed)
      printf 'modelcheck=passed\n'
      k=0
      while [ "$k" -lt "$GATE_N" ]; do
        k=$((k + 1))
        eval "id=\$GATE_ID_$k"
        eval "seats=\$GATE_SEATS_$k"
        eval "rep=\$GATE_REP_$k"
        printf 'modelcheck.%s=%s\n' "$k" "$id"
        printf 'modelcheck.%s.seats=%s\n' "$k" "$seats"
        printf 'modelcheck.%s.reported=%s\n' "$k" "$rep"
      done
      printf 'modelcheck.from=%s\n' "each modelcheck.<n> ID was asked once, just before the planners started, for one word with --model and JSON output; the call exited 0, and exactly that ID was among the model IDs the CLI billed for it (the keys of modelUsage in its JSON output); that is what answered when planning started, not proof of what served the planning calls, which run without JSON output and leave nothing to read. The list can also hold the CLI's own background calls, and nothing in it tells them apart from the call asked for: an ID that is also the CLI's background model can be listed whatever answered, so for that ID this is no evidence at all" ;;
    skipped)
      printf 'modelcheck=skipped\n'
      printf 'modelcheck.from=%s\n' "--no-model-check was given, so no model ID in play was asked anything before the planners started" ;;
  esac
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
