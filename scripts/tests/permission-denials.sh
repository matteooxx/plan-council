#!/bin/sh
# Tests for the per-run seat check in ../lib.sh: the reader of the CLI's
# permission_denials record (council_denials_read), the switch that makes a
# seat write that record (council_seat_flags), the probe that calls each seat
# (council_seat_check), the scripts that run it before their seats, the
# refusal by council-review.sh and council-assign.sh of an arbiter the text
# check did not judge, and the parallel runner's plumbing: prompt in, stdout
# and stderr out to their logs.
#
# Usage: sh scripts/tests/permission-denials.sh
#        dash scripts/tests/permission-denials.sh
#
# Every assertion names the function or script it runs and the output or
# variable it reads, and prints one line. The exit status is non-zero when any
# assertion failed.
#
# No model is called. A stand-in "claude", written to a temporary directory
# and put first on PATH, records every argument it receives, one per line,
# and answers as the measured CLI did: with --output-format json it prints one
# JSON object, otherwise plain text. Asked by the probe to read a file, it
# refuses the read, with one permission_denials entry naming Read, when a
# Read(DIR/**) argument covers the file, or when --restricted is given and the
# file lies outside its working directory; otherwise it reads the file and
# puts its first line in the result. STUB_MODE makes it misbehave on purpose.
# When STUB_RULES names a file, it also writes there one line per Read(...)
# argument, prefixed by the COUNCIL_PHASE the runner exported, so that what a
# script computes for its deny rules can be read phase by phase.
# Everything is written to that temporary directory, which is removed on exit.
set -u

T_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
T_PLUGIN=$(dirname "$(dirname "$T_DIR")")
. "$T_PLUGIN/scripts/lib.sh"

T_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t plancouncil) || {
  echo "mktemp failed" >&2
  exit 1
}
T_TMP=$(cd "$T_TMP" && pwd -P)
trap 'rm -rf "$T_TMP"' EXIT
trap 'exit 1' HUP INT TERM

T_PASS=0
T_FAIL=0

t_ok() {
  T_PASS=$((T_PASS + 1))
  printf 'ok    %s\n' "$1"
}

t_bad() {
  T_FAIL=$((T_FAIL + 1))
  printf 'FAIL  %s\n      expected [%s]\n      got      [%s]\n' "$1" "$2" "$3"
}

t_same() {
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_bad "$1" "$2" "$3"; fi
}

# t_has LABEL FILE TEXT -- FILE holds TEXT, as a fixed string.
t_has() {
  if grep -F -q -e "$3" "$2" 2>/dev/null; then t_ok "$1 holds [$3]"; else t_bad "$1 holds [$3]" "a line holding: $3" "$(head -c 300 "$2" 2>/dev/null)"; fi
}

# t_lacks LABEL FILE TEXT -- FILE does not hold TEXT, as a fixed string.
t_lacks() {
  if grep -F -q -e "$3" "$2" 2>/dev/null; then t_bad "$1 lacks [$3]" "no line holding: $3" "$(grep -F -e "$3" "$2" | head -n 1)"; else t_ok "$1 lacks [$3]"; fi
}

# t_read LABEL EXPECTED FORMAT [ARG] -- council_denials_read, reading what
# printf FORMAT [ARG] prints, prints EXPECTED. The input is made here, in a
# command substitution, and not piped into this function: a function on the
# right of a pipe runs in a subshell, where its count of passes and failures
# would be lost and a failure would not reach the exit status.
t_read() {
  if [ $# -ge 4 ]; then
    _t_got=$(printf "$3" "$4" | council_denials_read)
  else
    _t_got=$(printf "$3" | council_denials_read)
  fi
  t_same "$1: council_denials_read prints" "$2" "$_t_got"
}

# ---------------------------------------------------------------------------
echo "The reader"

ENTRY='{"tool_name":"Read","tool_use_id":"toolu_1","tool_input":{"file_path":"C:/x/notes.txt"}}'

t_read "entry present" "1 1" '{"type":"result","result":"BLOCKED","permission_denials":[%s],"modelUsage":{}}\n' "$ENTRY"
t_read "entry present, spread over lines" "1 1" '{\n  "type": "result",\n  "result": "BLOCKED",\n  "permission_denials": [\n    {\n      "tool_name": "Read",\n      "tool_input": { "file_path": "C:/x/notes.txt" }\n    }\n  ]\n}\n'
t_read "two entries, one naming Read" "1 2" '{"result":"x","permission_denials":[{"tool_name":"Grep"},%s]}\n' "$ENTRY"
t_read "brackets and escaped quotes inside a string" "1 1" '{"result":"a \\"}]\\" b {[","permission_denials":[%s]}\n' "$ENTRY"
t_read "field empty" "0 0" '{"result":"Read","permission_denials":[]}\n'
t_read "field empty, with a blank" "0 0" '{"result":"Read","permission_denials":[ ]}\n'
t_read "field missing" "missing" '{"result":"Read"}\n'
t_read "no output at all" "!" ''
t_read "no JSON object: plain text" "!" 'BLOCKED\n'
t_read "no JSON object first: text before it" "!" 'note: starting\n{"permission_denials":[%s]}\n' "$ENTRY"
t_read "no JSON object: an array" "!" '["permission_denials",%s]\n' "$ENTRY"
t_read "malformed: the object never closes" "!" '{"permission_denials":[%s]\n' "$ENTRY"
t_read "malformed: closes on the wrong bracket" "!" '{"permission_denials":[%s}}\n' "$ENTRY"
t_read "malformed: a string broken across lines" "!" '{"result":"BLO\nCKED","permission_denials":[%s]}\n' "$ENTRY"
t_read "duplicated field, empty first" "!" '{"permission_denials":[],"permission_denials":[%s]}\n' "$ENTRY"
t_read "duplicated field, entry first" "!" '{"permission_denials":[%s],"permission_denials":[]}\n' "$ENTRY"
t_read "duplicated tool_name in one entry" "!" '{"permission_denials":[{"tool_name":"Read","tool_name":"Grep"}]}\n'
t_read "the field's name spelled with an escape" "!" '{"permission\\u005fdenials":[%s]}\n' "$ENTRY"
t_read "tool_name spelled with an escape" "!" '{"permission_denials":[{"tool\\u005fname":"Read"}]}\n'
t_read "Read spelled with an escape" "0 1" '{"permission_denials":[{"tool_name":"R\\u0065ad"}]}\n'
t_read "the field only in a nested object" "missing" '{"result":"x","nested":{"permission_denials":[%s]}}\n' "$ENTRY"
t_read "the field is an object, not an array" "notarray" '{"permission_denials":%s}\n' "$ENTRY"
t_read "the field is null" "notarray" '{"permission_denials":null}\n'
t_read "the field is a string" "notarray" '{"permission_denials":"Read"}\n'
t_read "an entry that is a string, not an object" "0 0" '{"permission_denials":["Read"]}\n'
t_read "tool_name only nested deeper in the entry" "0 1" '{"permission_denials":[{"tool_input":{"tool_name":"Read"}}]}\n'
t_read "tool_name not a string" "0 1" '{"permission_denials":[{"tool_name":["Read"]}]}\n'
t_read "a second object after the first adds nothing" "0 0" '{"permission_denials":[]}\n{"permission_denials":[%s]}\n' "$ENTRY"
t_read "text after the object is ignored" "1 1" '{"permission_denials":[%s]} trailing text\n' "$ENTRY"

# ---------------------------------------------------------------------------
echo "The switch"

case " $(council_seat_flags) " in
  *" --output-format "*) _t_got=present ;;
  *) _t_got=absent ;;
esac
t_same "council_seat_flags with the switch unset: --output-format" absent "$_t_got"
_t_got=$(_council_seat_json=1; council_seat_flags)
t_same "council_seat_flags with the switch set to 1" "--restricted --tools Read,Glob,Grep --setting-sources project,local --strict-mcp-config --disable-slash-commands --output-format json" "$_t_got"
_t_got=$(_council_seat_json=yes; council_seat_flags)
case " $_t_got " in
  *" --output-format "*) _t_got=present ;;
  *) _t_got=absent ;;
esac
t_same "council_seat_flags with the switch set to another value: --output-format" absent "$_t_got"
_t_got=$(_council_seat_json=1 sh -c '. "$1/scripts/lib.sh"; council_seat_flags' t "$T_PLUGIN")
case " $_t_got " in
  *" --output-format "*) _t_got=present ;;
  *) _t_got=absent ;;
esac
t_same "council_seat_flags after lib.sh is sourced with the switch exported: --output-format" absent "$_t_got"

# ---------------------------------------------------------------------------
# The stand-in claude.
mkdir -p "$T_TMP/bin" "$T_TMP/tmp"
cat > "$T_TMP/bin/claude" <<'STUB'
#!/bin/sh
# Stand-in claude for scripts/tests/permission-denials.sh. See that file.
{
  echo "--- call"
  for a in "$@"; do printf 'arg:%s\n' "$a"; done
} >> "$STUB_LOG"
# One line per rule, phase first: a whole line per write, so seats running in
# parallel cannot mix one call's rules with another's phase.
if [ -n "${STUB_RULES:-}" ]; then
  for a in "$@"; do
    case "$a" in 'Read('*) printf '%s %s\n' "${COUNCIL_PHASE:-none}" "$a" >> "$STUB_RULES" ;; esac
  done
fi
prompt=$(cat)
json=0
restricted=0
rules=""
prev=""
for a in "$@"; do
  [ "$prev" = --output-format ] && [ "$a" = json ] && json=1
  [ "$a" = --restricted ] && restricted=1
  case "$a" in
    'Read('*'/**)') d=${a#Read(}; d=${d%/\*\*)}; rules="$rules
$d" ;;
  esac
  prev=$a
done
mode=${STUB_MODE:-}
if [ "$mode" = fail ]; then
  echo "stub failure" >&2
  exit 3
fi
path=$(printf '%s\n' "$prompt" | grep -E '^(/|[A-Za-z]:/).*notes-[0-9]+\.txt$' | head -n 1)
if [ -z "$path" ]; then
  # A seat's real work: a plain answer, long enough to be accepted. Asked for
  # JSON, the CLI wraps its answer in a JSON object, and so does this.
  answer=$(
    i=0
    while [ "$i" -lt 12 ]; do
      echo "Plain answer line $i, written as text, as a seat writes a plan or an attack."
      i=$((i + 1))
    done
    echo "PASS"
  )
  if [ "$json" = 1 ]; then
    printf '{"type":"result","result":"%s","permission_denials":[]}\n' "$(printf '%s' "$answer" | tr '\n' ' ')"
  else
    printf '%s\n' "$answer"
  fi
  exit 0
fi
cwd=$(pwd -P)
if command -v cygpath > /dev/null 2>&1; then cwd=$(cygpath -m "$cwd"); fi
denied=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  case "$path" in "$d"/*) denied=1 ;; esac
done <<EOF
$rules
EOF
if [ "$restricted" = 1 ]; then
  case "$path" in "$cwd"/*) ;; *) denied=1 ;; esac
fi
[ "$mode" = allow ] && denied=0
[ "$mode" = deny ] && denied=1
if [ "$denied" = 1 ]; then
  result=BLOCKED
  pd='[{"tool_name":"Read","tool_use_id":"toolu_stub","tool_input":{"file_path":"'"$path"'"}}]'
else
  result=$(head -n 1 "$path" 2>/dev/null)
  pd='[]'
fi
case "$mode" in
  nodenial) result=BLOCKED; pd='[]' ;;
  plaintext) json=0 ;;
esac
if [ "$json" = 1 ]; then
  case "$mode" in
    dup) printf '{"type":"result","result":"%s","permission_denials":[],"permission_denials":%s}\n' "$result" "$pd" ;;
    pretty) printf '{\n  "type": "result",\n  "result": "%s",\n  "permission_denials": %s\n}\n' "$result" "$pd" ;;
    *) printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","permission_denials":%s,"modelUsage":{"claude-stub":{"costUSD":0}}}\n' "$result" "$pd" ;;
  esac
else
  printf '%s\n' "$result"
fi
exit 0
STUB
chmod +x "$T_TMP/bin/claude"
PATH="$T_TMP/bin:$PATH"
STUB_LOG="$T_TMP/stub.log"
STUB_RULES="$T_TMP/stub-rules.log"
STUB_MODE=""
export PATH STUB_LOG STUB_RULES STUB_MODE

# t_rule_count PHASE RULE -- how many Read(...) arguments the stand-in
# received in PHASE that equal RULE, read from STUB_RULES.
t_rule_count() {
  if [ -f "$STUB_RULES" ]; then grep -c -x -F -e "$1 $2" "$STUB_RULES" || true; else echo 0; fi
}

# t_rule_lines -- how many Read(...) arguments the stand-in received at all.
t_rule_lines() {
  if [ -f "$STUB_RULES" ]; then wc -l < "$STUB_RULES" | tr -d ' '; else echo 0; fi
}

# t_calls -- the number of calls the stand-in has recorded.
t_calls() {
  if [ -f "$STUB_LOG" ]; then grep -c '^--- call$' "$STUB_LOG"; else echo 0; fi
}

# t_json_calls -- how many recorded calls carried --output-format then json.
t_json_calls() {
  awk '/^--- call$/ { p = "" } { if (p == "arg:--output-format" && $0 == "arg:json") n++; p = $0 } END { print n + 0 }' "$STUB_LOG" 2>/dev/null || echo 0
}

# The context root holds a space, so that argument boundaries are tested.
ROOT="$T_TMP/ro ot"
mkdir -p "$ROOT/.council"
ROOT=$(cd "$ROOT" && pwd -P)
COUNCIL_CONFIG=""
unset COUNCIL_CONFIG
council_load_config "$ROOT" "$T_PLUGIN" 2> /dev/null

# A seat with every flag but no deny rule: the control.
planner_norule() {
  claude -p --model "$COUNCIL_MODEL_CLAUDE" \
    --effort "$(council_effort)" \
    --permission-mode default \
    $(council_budget_flags) \
    $(council_seat_flags) \
    --disallowedTools Edit Write NotebookEdit Bash \
    > "$1"
}

# t_probe NAME RUN FNS -- council_seat_check ROOT RUN STAGE in a subshell,
# with the deny rule on RUN and COUNCIL_CHECK_CLAUDE set to FNS. Its return
# code goes to T_RC, its record to $T_TMP/NAME.rec, its messages to
# $T_TMP/NAME.err. The stage is $T_TMP/NAME.stage.
t_probe() {
  mkdir -p "$2" "$T_TMP/$1.stage"
  : > "$STUB_LOG"
  T_RC=0
  (
    COUNCIL_DENY=$(council_deny_rule "$2")
    COUNCIL_DENY2=$COUNCIL_DENY
    COUNCIL_PHASE=plan
    COUNCIL_CHECK_CLAUDE=$3
    COUNCIL_DENY_UNCOVERED=${T_UNCOVERED-}
    export COUNCIL_DENY COUNCIL_DENY2 COUNCIL_PHASE
    council_seat_check "$ROOT" "$2" "$T_TMP/$1.stage" && council_seat_record plan
  ) > "$T_TMP/$1.rec" 2> "$T_TMP/$1.err" || T_RC=$?
}

# t_clean NAME RUN -- after a probe, the run directory holds no planted file
# and the stage no seatcheck directory and no log.
t_clean() {
  _t_got=$(ls -A "$2" | grep '^notes-' || true)
  t_same "$1: the planted file is gone from the run directory" "" "$_t_got"
  if [ -e "$T_TMP/$1.stage/seatcheck" ]; then _t_got=present; else _t_got=absent; fi
  t_same "$1: the stage's seatcheck directory" absent "$_t_got"
  _t_got=$(ls "$T_TMP/$1.stage" | grep '\.log$' || true)
  t_same "$1: log files in the stage" "" "$_t_got"
}

# ---------------------------------------------------------------------------
echo "The probe: a deny rule on a run directory inside the root"

RUN_IN="$ROOT/.council/run-in"
t_probe inside "$RUN_IN" " arbiter"
t_same "inside: council_seat_check returns" 0 "$T_RC"
t_has "inside: council_seat_record" "$T_TMP/inside.rec" "seatcheck.plan=passed"
t_has "inside: council_seat_record" "$T_TMP/inside.rec" "seatcheck.plan.seats=arbiter"
t_has "inside: council_seat_record" "$T_TMP/inside.rec" "seatcheck.plan.target=inside"
t_has "inside: council_seat_record says what was measured" "$T_TMP/inside.rec" "a read of the run directory through each seat in seatcheck.plan.seats was refused by the CLI, in a separate process, just before the run"
t_has "inside: council_seat_record says inside the root" "$T_TMP/inside.rec" "The run directory is inside the context root"
t_lacks "inside: council_seat_record never says" "$T_TMP/inside.rec" "deny rule is in force"
t_lacks "inside: council_seat_record never says" "$T_TMP/inside.rec" "verified"
t_lacks "inside: council_seat_record, no unprobed line" "$T_TMP/inside.rec" "unprobed"
t_clean inside "$RUN_IN"
t_same "inside: calls the stand-in recorded" 1 "$(t_calls)"
# Argument boundaries: the deny rule, whose path holds a space, arrives as one
# argument; the switch as two; the seat flags each as their own.
_t_rule="arg:$(council_deny_rule "$RUN_IN")"
t_has "inside: the deny rule arrives as one argument" "$STUB_LOG" "$_t_rule"
_t_got=$(grep -c -x -F -e "$_t_rule" "$STUB_LOG")
t_same "inside: arguments equal to the deny rule (COUNCIL_DENY and COUNCIL_DENY2)" 2 "$_t_got"
t_same "inside: calls carrying --output-format then json, as two arguments" 1 "$(t_json_calls)"
_t_got=$(grep -x -e 'arg:--restricted' -e 'arg:--tools' -e 'arg:Read,Glob,Grep' -e 'arg:--setting-sources' -e 'arg:project,local' -e 'arg:--strict-mcp-config' -e 'arg:--disable-slash-commands' "$STUB_LOG" | wc -l | tr -d ' ')
t_same "inside: seat flags arriving as separate arguments" 7 "$_t_got"
_t_got=$(grep -c -x -e 'arg:--model' -e "arg:$COUNCIL_MODEL_ARBITER" "$STUB_LOG")
t_same "inside: the seat's own --model and its value" 2 "$_t_got"
_t_got=$(awk 'p == "arg:--effort" { print; exit } { p = $0 }' "$STUB_LOG")
t_same "inside: the phase's effort" "arg:$COUNCIL_PLANNER_EFFORT" "$_t_got"

echo "The probe: the control, a seat with no deny rule, inside the root"

RUN_CTL="$ROOT/.council/run-control"
t_probe control "$RUN_CTL" " planner_norule"
t_same "control: council_seat_check returns" 1 "$T_RC"
t_has "control: the refusal names the cause" "$T_TMP/control.err" "planner_norule: the read was allowed"
t_has "control: the refusal says the text check had passed" "$T_TMP/control.err" "The text check of the config had passed"
t_lacks "control: council_seat_record printed nothing" "$T_TMP/control.rec" "seatcheck"
t_clean control "$RUN_CTL"

echo "The probe: a seat with no deny rule, run directory outside the root"

RUN_OUT="$T_TMP/outside-run"
t_probe outside "$RUN_OUT" " planner_norule"
t_same "outside: council_seat_check returns" 0 "$T_RC"
t_has "outside: council_seat_record" "$T_TMP/outside.rec" "seatcheck.plan.target=outside"
t_has "outside: council_seat_record says what it does not show" "$T_TMP/outside.rec" "so this does not show that a deny rule refused it"
t_lacks "outside: council_seat_record never says" "$T_TMP/outside.rec" "deny rule is in force"
t_lacks "outside: council_seat_record never says" "$T_TMP/outside.rec" "inside the context root"
t_has "outside: the message on stderr says the same" "$T_TMP/outside.err" "so this does not show that a deny rule refused it"
t_clean outside "$RUN_OUT"

echo "The probe: outcomes that refuse"

STUB_MODE=nodenial; export STUB_MODE
t_probe nodenial "$ROOT/.council/run-nodenial" " arbiter"
t_same "no record, field empty: council_seat_check returns" 1 "$T_RC"
t_has "no record, field empty: the refusal" "$T_TMP/nodenial.err" "arbiter: no record: permission_denials is empty"
t_has "no record, field empty: the refusal says the text check had passed" "$T_TMP/nodenial.err" "The text check of the config had passed"
t_clean nodenial "$ROOT/.council/run-nodenial"

STUB_MODE=plaintext; export STUB_MODE
t_probe plaintext "$ROOT/.council/run-plaintext" " arbiter"
t_same "no JSON object: council_seat_check returns" 1 "$T_RC"
t_has "no JSON object: the refusal" "$T_TMP/plaintext.err" "arbiter: what the seat wrote is not one complete JSON object this check can read"
t_clean plaintext "$ROOT/.council/run-plaintext"

STUB_MODE=dup; export STUB_MODE
t_probe dup "$ROOT/.council/run-dup" " arbiter"
t_same "duplicated field, the second naming Read: council_seat_check returns" 1 "$T_RC"
t_has "duplicated field: the refusal" "$T_TMP/dup.err" "arbiter: what the seat wrote is not one complete JSON object this check can read"
t_clean dup "$ROOT/.council/run-dup"

STUB_MODE=fail; export STUB_MODE
t_probe fail "$ROOT/.council/run-fail" " arbiter"
t_same "the call fails: council_seat_check returns" 1 "$T_RC"
t_has "the call fails: the refusal" "$T_TMP/fail.err" "arbiter: the call exited with status 3"
t_clean fail "$ROOT/.council/run-fail"

STUB_MODE=pretty; export STUB_MODE
t_probe pretty "$ROOT/.council/run-pretty" " arbiter"
t_same "a record spread over lines: council_seat_check returns" 0 "$T_RC"
t_clean pretty "$ROOT/.council/run-pretty"

STUB_MODE=""; export STUB_MODE
t_probe mixed "$ROOT/.council/run-mixed" " arbiter planner_norule"
t_same "two seats, one without the rule: council_seat_check returns" 1 "$T_RC"
t_has "two seats: the failing one is named" "$T_TMP/mixed.err" "planner_norule: the read was allowed"
t_lacks "two seats: the passing one is not named as failing" "$T_TMP/mixed.err" "arbiter: "
t_has "two seats: the refusal counts the calls" "$T_TMP/mixed.err" "The seat check made 2 call(s)"
t_same "two seats: calls the stand-in recorded" 2 "$(t_calls)"
t_clean mixed "$ROOT/.council/run-mixed"

echo "The probe: seats it does not reach"

T_UNCOVERED=" planner_codex"
t_probe none "$ROOT/.council/run-none" ""
t_same "no claude seat: council_seat_check returns" 0 "$T_RC"
t_has "no claude seat: council_seat_record" "$T_TMP/none.rec" "seatcheck.plan=none"
t_has "no claude seat: council_seat_record lists the unprobed" "$T_TMP/none.rec" "seatcheck.plan.unprobed=planner_codex"
t_same "no claude seat: calls the stand-in recorded" 0 "$(t_calls)"
t_probe uncovered "$ROOT/.council/run-uncovered" " arbiter"
t_same "a claude seat beside an unprobed one: council_seat_check returns" 0 "$T_RC"
t_has "a claude seat beside an unprobed one: council_seat_record" "$T_TMP/uncovered.rec" "seatcheck.plan.unprobed=planner_codex"
t_has "a claude seat beside an unprobed one: council_seat_record says what is not known" "$T_TMP/uncovered.rec" "whether they can read the run directory is not known"
T_UNCOVERED=""

# ---------------------------------------------------------------------------
echo "A seat called after the probe writes plain text"

# The probe runs in this shell, not in a subshell, so that a switch it left
# behind would still be here for the calls below.
RUN_AFTER="$ROOT/.council/run-after"
mkdir -p "$RUN_AFTER" "$T_TMP/after.stage"
COUNCIL_DENY=$(council_deny_rule "$RUN_AFTER")
COUNCIL_DENY2=$COUNCIL_DENY
COUNCIL_PHASE=plan
COUNCIL_CHECK_CLAUDE=" arbiter"
COUNCIL_DENY_UNCOVERED=""
export COUNCIL_DENY COUNCIL_DENY2 COUNCIL_PHASE
: > "$STUB_LOG"
council_seat_check "$ROOT" "$RUN_AFTER" "$T_TMP/after.stage" 2> "$T_TMP/after.err"
t_same "after: council_seat_check" passed "${COUNCIL_SEATCHECK-}"
if [ -n "${_council_seat_json+set}" ]; then _t_got="set to '$_council_seat_json'"; else _t_got=unset; fi
t_same "after: the switch in the calling shell" unset "$_t_got"
case " $(council_seat_flags) " in
  *" --output-format "*) _t_got=present ;;
  *) _t_got=absent ;;
esac
t_same "after: council_seat_flags, --output-format" absent "$_t_got"
printf 'Write a plan.\n' > "$T_TMP/after-prompt.md"
: > "$STUB_LOG"
( cd "$ROOT" && arbiter "$T_TMP/after-direct.md" ) < "$T_TMP/after-prompt.md"
_t_got=$(head -c 1 "$T_TMP/after-direct.md")
t_same "after: arbiter called directly, first character of its answer" "P" "$_t_got"
t_lacks "after: arbiter called directly, its answer" "$T_TMP/after-direct.md" "permission_denials"
t_same "after: arbiter called directly, calls carrying --output-format json" 0 "$(t_json_calls)"
t_lacks "after: arbiter called directly, its arguments" "$STUB_LOG" "arg:--output-format"
# The way the runner calls a seat.
cp "$T_TMP/after-prompt.md" "$T_TMP/after.stage/prompt-A.md"
: > "$STUB_LOG"
council_run_parallel "$ROOT" "$T_TMP/after.stage" "A:arbiter" 2> /dev/null
t_same "after: council_run_parallel returns" 0 "$?"
_t_got=$(head -c 1 "$T_TMP/after.stage/answer-A.md")
t_same "after: council_run_parallel, first character of the answer" "P" "$_t_got"
t_lacks "after: council_run_parallel, the answer" "$T_TMP/after.stage/answer-A.md" "permission_denials"
t_lacks "after: council_run_parallel, the arguments" "$STUB_LOG" "arg:--output-format"
# The identity gate builds its own command line: it asks for JSON once.
: > "$STUB_LOG"
council_probe_call claude-x > /dev/null 2>&1
_t_got=$(grep -c -x 'arg:--output-format' "$STUB_LOG")
t_same "after: council_probe_call, --output-format arguments" 1 "$_t_got"

# ---------------------------------------------------------------------------
echo "The runner's plumbing"

# council_run_parallel gives each seat its prompt on stdin and keeps the
# seat's stdout and stderr in stdout-<label>.log and stderr-<label>.log:
# council-plan.sh reads stderr-<letter>.log, and the runner's FAILED line
# tells the user to read stderr-<label>.log. The seat runs an external
# script, as a real seat runs claude or codex. This section has its own root
# and stage, so the run directories t_clean reads are not touched.
T_PL="$T_TMP/plumb"
mkdir -p "$T_PL/root" "$T_PL/stage" "$T_PL/stage-cd" "$T_PL/stage-noprompt"
cat > "$T_PL/child.sh" <<'CHILD'
#!/bin/sh
IFS= read -r _line
printf 'out:%s\n' "$_line"
printf 'err:%s\n' "$_line" >&2
{
  printf 'pwd:%s\n' "$(pwd -P)"
  _i=0
  while [ "$_i" -lt 20 ]; do
    printf 'line %s of an answer long enough to pass the size check\n' "$_i"
    _i=$((_i + 1))
  done
} > "$1"
CHILD
chmod +x "$T_PL/child.sh"
t_plumb_seat() { "$T_PL/child.sh" "$1"; }

# Two seats, each with its own prompt.
printf 'the prompt for P\n' > "$T_PL/stage/prompt-P.md"
printf 'the prompt for Q\n' > "$T_PL/stage/prompt-Q.md"
T_RC=0
council_run_parallel "$T_PL/root" "$T_PL/stage" "P:t_plumb_seat" "Q:t_plumb_seat" \
  > "$T_PL/runner.out" 2> "$T_PL/runner.err" < /dev/null || T_RC=$?
t_same "plumbing: council_run_parallel returns" 0 "$T_RC"
t_has "plumbing: stdout-P.log" "$T_PL/stage/stdout-P.log" "out:the prompt for P"
t_has "plumbing: stderr-P.log" "$T_PL/stage/stderr-P.log" "err:the prompt for P"
t_has "plumbing: stdout-Q.log" "$T_PL/stage/stdout-Q.log" "out:the prompt for Q"
t_has "plumbing: stderr-Q.log" "$T_PL/stage/stderr-Q.log" "err:the prompt for Q"
t_lacks "plumbing: stdout-P.log" "$T_PL/stage/stdout-P.log" "for Q"
t_has "plumbing: answer-P.md, the seat's working directory" "$T_PL/stage/answer-P.md" "pwd:$T_PL/root"
t_lacks "plumbing: the runner's own stdout" "$T_PL/runner.out" "out:"
t_lacks "plumbing: the runner's own stderr" "$T_PL/runner.err" "err:the prompt"
t_has "plumbing: the runner's own stderr" "$T_PL/runner.err" "P done ("

# A root that does not exist: the failed cd must be written into the log
# that the FAILED line names. The redirections must apply before the cd for
# that, so this is the assertion that turns red if their order is swapped.
printf 'the prompt for R\n' > "$T_PL/stage-cd/prompt-R.md"
T_RC=0
council_run_parallel "$T_PL/no-such-root" "$T_PL/stage-cd" "R:t_plumb_seat" \
  > /dev/null 2> "$T_PL/runner-cd.err" < /dev/null || T_RC=$?
if [ "$T_RC" -ne 0 ]; then _t_got=non-zero; else _t_got=0; fi
t_same "failed cd: council_run_parallel returns" non-zero "$_t_got"
t_has "failed cd: the runner's own stderr" "$T_PL/runner-cd.err" "R FAILED with exit code 97 (see stderr-R.log)"
if [ -s "$T_PL/stage-cd/stderr-R.log" ]; then _t_got=non-empty; else _t_got="empty or absent"; fi
t_same "failed cd: stderr-R.log, the file the FAILED line names" non-empty "$_t_got"
if [ -e "$T_PL/stage-cd/answer-R.md" ]; then _t_got=present; else _t_got=absent; fi
t_same "failed cd: answer-R.md, so the seat was not called" absent "$_t_got"

# A prompt that does not exist: the redirection fails, and the seat must not
# run on the runner's own stdin and stdout.
T_RC=0
council_run_parallel "$T_PL/root" "$T_PL/stage-noprompt" "S:t_plumb_seat" \
  > "$T_PL/runner-np.out" 2> /dev/null < /dev/null || T_RC=$?
if [ "$T_RC" -ne 0 ]; then _t_got=non-zero; else _t_got=0; fi
t_same "missing prompt: council_run_parallel returns" non-zero "$_t_got"
if [ -e "$T_PL/stage-noprompt/answer-S.md" ]; then _t_got=present; else _t_got=absent; fi
t_same "missing prompt: answer-S.md, so the seat was not called" absent "$_t_got"
t_lacks "missing prompt: the runner's own stdout" "$T_PL/runner-np.out" "out:"

# ---------------------------------------------------------------------------
echo "The scripts that run it"

printf '# A brief\n\nPlan one small change.\n' > "$T_TMP/brief.md"
printf '# A plan\n\nOne task.\n' > "$T_TMP/final-plan.md"
# An arbiter that hands its claude call to a helper. The helper carries the
# shipped arbiter's whole command line, so the seat would be blind; but the
# arbiter's own definition holds no claude, so the text check judged nothing.
cat > "$T_TMP/unjudged.conf" <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
run_seat() {
  claude -p --model "$1" \
    --effort "$(council_effort)" \
    --permission-mode default \
    $(council_budget_flags) \
    $(council_seat_flags) \
    --disallowedTools Edit Write NotebookEdit Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" \
    > "$2"
}
arbiter() { run_seat "$COUNCIL_MODEL_ARBITER" "$@"; }
CONF
T_SHELLS="sh"
[ -x /usr/bin/dash ] && T_SHELLS="$T_SHELLS /usr/bin/dash"
for T_SH in $T_SHELLS; do
  T_N=${T_SH##*/}
  # A plan, with two claude planners, run directory inside the root.
  : > "$STUB_LOG"
  : > "$STUB_RULES"
  T_RC=0
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-plan.sh" "$T_TMP/brief.md" --root "$ROOT" \
    > "$T_TMP/plan.out" 2> "$T_TMP/plan.err" || T_RC=$?
  t_same "$T_N council-plan.sh: exits" 0 "$T_RC"
  RUN=$(tail -n 1 "$T_TMP/plan.out")
  t_has "$T_N council-plan.sh: council.txt" "$RUN/council.txt" "seatcheck.plan=passed"
  t_has "$T_N council-plan.sh: council.txt" "$RUN/council.txt" "seatcheck.plan.seats=planner_claude planner_claude_alt"
  t_has "$T_N council-plan.sh: council.txt" "$RUN/council.txt" "seatcheck.plan.target=inside"
  t_same "$T_N council-plan.sh: calls the stand-in recorded (two probes, two planners)" 4 "$(t_calls)"
  t_same "$T_N council-plan.sh: calls carrying --output-format json (the probes only)" 2 "$(t_json_calls)"
  # Planning deliberately leaves earlier runs readable: COUNCIL_DENY2 is this
  # run's rule, so the rule on the whole council tree must not arrive here.
  # Compared with council_deny_rule, which builds the CLI's path form.
  T_ALLRUNS=$(council_deny_rule "$ROOT/.council")
  T_THISRUN=$(council_deny_rule "$RUN")
  t_same "$T_N council-plan.sh: rules naming all of ROOT/.council (planning leaves earlier runs readable)" 0 "$(t_rule_count plan "$T_ALLRUNS")"
  t_same "$T_N council-plan.sh: rules naming this run (COUNCIL_DENY and COUNCIL_DENY2, four calls)" 8 "$(t_rule_count plan "$T_THISRUN")"
  t_same "$T_N council-plan.sh: Read rules received in all" 8 "$(t_rule_lines)"
  for L in A B; do
    _t_got=$(head -c 1 "$RUN/plan-$L.md")
    t_same "$T_N council-plan.sh: plan-$L.md, first character" "P" "$_t_got"
    t_lacks "$T_N council-plan.sh: plan-$L.md" "$RUN/plan-$L.md" "permission_denials"
  done
  _t_got=$(ls -A "$RUN" | grep '^notes-' || true)
  t_same "$T_N council-plan.sh: planted file left in the run directory" "" "$_t_got"
  _t_got=$(cat "$RUN"/logs/* 2>/dev/null | grep -c 'permission_denials\|BLOCKED' || true)
  t_same "$T_N council-plan.sh: probe output in the published logs" 0 "$_t_got"

  # The review of that run: an attack phase and an arbitration.
  : > "$STUB_LOG"
  : > "$STUB_RULES"
  T_RC=0
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-review.sh" "$RUN" \
    > "$T_TMP/review.out" 2> "$T_TMP/review.err" || T_RC=$?
  t_same "$T_N council-review.sh: exits" 0 "$T_RC"
  t_has "$T_N council-review.sh: council.txt" "$RUN/council.txt" "seatcheck.attack=passed"
  t_has "$T_N council-review.sh: council.txt" "$RUN/council.txt" "seatcheck.arbitrate=passed"
  t_has "$T_N council-review.sh: council.txt" "$RUN/council.txt" "seatcheck.arbitrate.seats=arbiter"
  t_same "$T_N council-review.sh: calls carrying --output-format json (three probes)" 3 "$(t_json_calls)"
  t_same "$T_N council-review.sh: calls the stand-in recorded (three probes, two attacks, one arbiter)" 6 "$(t_calls)"
  # COUNCIL_DENY2 at review names all of ROOT/.council, so that an earlier
  # run's council.txt, whose letter-to-planner mapping a project running the
  # same planners in the same order shares, stays out of reach. Read from the
  # arguments the runner passed, not from a seat's attempt to read: a seat
  # with --restricted is refused a run directory outside the root whatever
  # the rule says, and such a test would pass for the wrong reason.
  t_same "$T_N council-review.sh: attack phase, rules naming all of ROOT/.council (two probes, two attacks)" 4 "$(t_rule_count attack "$T_ALLRUNS")"
  t_same "$T_N council-review.sh: arbitrate phase, rules naming all of ROOT/.council (one probe, one arbiter)" 2 "$(t_rule_count arbitrate "$T_ALLRUNS")"
  t_same "$T_N council-review.sh: attack phase, rules naming this run" 4 "$(t_rule_count attack "$T_THISRUN")"
  t_same "$T_N council-review.sh: arbitrate phase, rules naming this run" 2 "$(t_rule_count arbitrate "$T_THISRUN")"
  t_same "$T_N council-review.sh: Read rules received in all" 12 "$(t_rule_lines)"
  for F in attack-A.md attack-B.md arbitration.md; do
    _t_got=$(head -c 1 "$RUN/$F")
    t_same "$T_N council-review.sh: $F, first character" "P" "$_t_got"
  done
  _t_got=$(ls -A "$RUN" | grep '^notes-' || true)
  t_same "$T_N council-review.sh: planted file left in the run directory" "" "$_t_got"
  # A rerun of the arbitration replaces its seat-check lines.
  : > "$STUB_LOG"
  : > "$STUB_RULES"
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-review.sh" "$RUN" --arbitrate-only --no-seat-check \
    > /dev/null 2>&1
  _t_got=$(grep -c '^seatcheck\.arbitrate=' "$RUN/council.txt")
  t_same "$T_N council-review.sh --arbitrate-only: seatcheck.arbitrate lines" 1 "$_t_got"
  t_has "$T_N council-review.sh --arbitrate-only --no-seat-check: council.txt" "$RUN/council.txt" "seatcheck.arbitrate=skipped"
  t_has "$T_N council-review.sh --arbitrate-only: the attack record is kept" "$RUN/council.txt" "seatcheck.attack=passed"
  t_same "$T_N council-review.sh --no-seat-check: calls carrying --output-format json" 0 "$(t_json_calls)"
  t_same "$T_N council-review.sh --arbitrate-only: rules naming all of ROOT/.council (the arbiter alone)" 1 "$(t_rule_count arbitrate "$T_ALLRUNS")"
  t_same "$T_N council-review.sh --arbitrate-only: Read rules received in all" 2 "$(t_rule_lines)"

  # A run directory outside the root.
  : > "$STUB_LOG"
  T_RC=0
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-plan.sh" "$T_TMP/brief.md" --root "$ROOT" --out "$T_TMP/out-$T_N" \
    > /dev/null 2> "$T_TMP/plan-out.err" || T_RC=$?
  t_same "$T_N council-plan.sh --out outside the root: exits" 0 "$T_RC"
  t_has "$T_N council-plan.sh --out outside the root: council.txt" "$T_TMP/out-$T_N/council.txt" "seatcheck.plan.target=outside"
  t_has "$T_N council-plan.sh --out outside the root: council.txt" "$T_TMP/out-$T_N/council.txt" "so this does not show that a deny rule refused it"
  t_lacks "$T_N council-plan.sh --out outside the root: council.txt never says" "$T_TMP/out-$T_N/council.txt" "deny rule is in force"

  # A refusal stops the run before any planner.
  : > "$STUB_LOG"
  T_RC=0
  STUB_MODE=allow COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-plan.sh" "$T_TMP/brief.md" --root "$ROOT" --out "$ROOT/.council/refused-$T_N" \
    > /dev/null 2> "$T_TMP/plan-refused.err" || T_RC=$?
  t_same "$T_N council-plan.sh, the read allowed: exits" 1 "$T_RC"
  t_has "$T_N council-plan.sh, the read allowed: the refusal" "$T_TMP/plan-refused.err" "planner_claude: the read was allowed"
  t_same "$T_N council-plan.sh, the read allowed: calls without --output-format json (planners)" 0 "$(( $(t_calls) - $(t_json_calls) ))"
  _t_got=$(ls -A "$ROOT/.council/refused-$T_N")
  t_same "$T_N council-plan.sh, the read allowed: the run directory afterwards" "" "$_t_got"

  # --no-seat-check makes no probe and says so.
  : > "$STUB_LOG"
  T_RC=0
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-plan.sh" "$T_TMP/brief.md" --root "$ROOT" --out "$ROOT/.council/skip-$T_N" --no-seat-check \
    > "$T_TMP/plan-skip.out" 2> /dev/null || T_RC=$?
  t_same "$T_N council-plan.sh --no-seat-check: exits" 0 "$T_RC"
  t_has "$T_N council-plan.sh --no-seat-check: council.txt" "$(tail -n 1 "$T_TMP/plan-skip.out")/council.txt" "seatcheck.plan=skipped"
  t_same "$T_N council-plan.sh --no-seat-check: calls carrying --output-format json" 0 "$(t_json_calls)"

  # An assignment that reaches its seat, with the shipped config. It sets
  # COUNCIL_DENY2 to the rule on all of ROOT/.council, as review does.
  mkdir -p "$T_TMP/assign-ok-$T_N"
  : > "$STUB_LOG"
  : > "$STUB_RULES"
  T_RC=0
  TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-assign.sh" "$T_TMP/final-plan.md" --root "$ROOT" \
    --out "$T_TMP/assign-ok-$T_N/assignment.md" > /dev/null 2> "$T_TMP/assign-ok.err" || T_RC=$?
  t_same "$T_N council-assign.sh: exits" 0 "$T_RC"
  t_same "$T_N council-assign.sh: calls the stand-in recorded (the arbiter alone)" 1 "$(t_calls)"
  t_same "$T_N council-assign.sh: rules naming all of ROOT/.council" 1 "$(t_rule_count assign "$T_ALLRUNS")"
  t_same "$T_N council-assign.sh: rules naming the output directory" 1 "$(t_rule_count assign "$(council_deny_rule "$T_TMP/assign-ok-$T_N")")"

  # An arbiter the text check did not judge is refused before anything runs.
  # Its own run, which nothing else reviews: a review that had written
  # attack-*.md there would make any later one exit 1 for that reason.
  T_UJ="$ROOT/.council/unjudged-$T_N"
  T_RC=0
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-plan.sh" "$T_TMP/brief.md" --root "$ROOT" --out "$T_UJ" \
    > /dev/null 2> /dev/null || T_RC=$?
  t_same "$T_N council-plan.sh, the run for an unjudged arbiter: exits" 0 "$T_RC"
  cp "$T_UJ/council.txt" "$T_TMP/council-uj-$T_N.txt"
  : > "$STUB_LOG"
  T_RC=0
  COUNCIL_CONFIG="$T_TMP/unjudged.conf" COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-review.sh" "$T_UJ" \
    > /dev/null 2> "$T_TMP/review-uj.err" || T_RC=$?
  t_same "$T_N council-review.sh, an arbiter with no claude in its definition: exits" 1 "$T_RC"
  t_has "$T_N council-review.sh, an arbiter with no claude in its definition: stderr" "$T_TMP/review-uj.err" "the word claude is not in its definition"
  t_has "$T_N council-review.sh, an arbiter with no claude in its definition: stderr" "$T_TMP/review-uj.err" "Nothing has been run"
  t_same "$T_N council-review.sh, an arbiter with no claude in its definition: calls the stand-in recorded" 0 "$(t_calls)"
  _t_got=$(ls -A "$T_UJ" | grep '^attack-' || true)
  t_same "$T_N council-review.sh, an arbiter with no claude in its definition: attack files in the run" "" "$_t_got"
  if cmp -s "$T_TMP/council-uj-$T_N.txt" "$T_UJ/council.txt"; then _t_got=identical; else _t_got=changed; fi
  t_same "$T_N council-review.sh, an arbiter with no claude in its definition: council.txt" identical "$_t_got"

  # The same under --arbitrate-only, on the run reviewed above, which has its
  # attacks and an arbitration. That path rewrites council.txt and moves
  # arbitration.md aside before it reaches the arbiter, so the refusal has to
  # come first. A rerun writes the same bytes as the stand-in did before, so
  # the file is marked: if it was moved and replaced, the mark is gone.
  printf 'marker-%s\n' "$T_N" >> "$RUN/arbitration.md"
  cp "$RUN/arbitration.md" "$T_TMP/arbitration-uj-$T_N.md"
  cp "$RUN/council.txt" "$T_TMP/council-ao-$T_N.txt"
  : > "$STUB_LOG"
  T_RC=0
  COUNCIL_CONFIG="$T_TMP/unjudged.conf" COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-review.sh" "$RUN" --arbitrate-only --no-seat-check \
    > /dev/null 2> "$T_TMP/review-ao.err" || T_RC=$?
  t_same "$T_N council-review.sh --arbitrate-only --no-seat-check, an arbiter with no claude in its definition: exits" 1 "$T_RC"
  t_has "$T_N council-review.sh --arbitrate-only --no-seat-check, an arbiter with no claude in its definition: stderr" "$T_TMP/review-ao.err" "the word claude is not in its definition"
  t_same "$T_N council-review.sh --arbitrate-only --no-seat-check, an arbiter with no claude in its definition: calls the stand-in recorded" 0 "$(t_calls)"
  if cmp -s "$T_TMP/arbitration-uj-$T_N.md" "$RUN/arbitration.md"; then _t_got=identical; else _t_got=changed; fi
  t_same "$T_N council-review.sh --arbitrate-only --no-seat-check, an arbiter with no claude in its definition: the marked arbitration.md" identical "$_t_got"
  if cmp -s "$T_TMP/council-ao-$T_N.txt" "$RUN/council.txt"; then _t_got=identical; else _t_got=changed; fi
  t_same "$T_N council-review.sh --arbitrate-only --no-seat-check, an arbiter with no claude in its definition: council.txt" identical "$_t_got"

  # council-assign.sh calls the check with the arbiter alone, and gets 0 back
  # for this one, so its refusal is a branch of its own. Each shell writes its
  # own --out: an existing one is refused before the arbiter is reached.
  : > "$STUB_LOG"
  T_RC=0
  COUNCIL_CONFIG="$T_TMP/unjudged.conf" TMPDIR="$T_TMP/tmp" \
    "$T_SH" "$T_PLUGIN/scripts/council-assign.sh" "$T_TMP/final-plan.md" --root "$ROOT" \
    --out "$T_TMP/assign-$T_N.md" > /dev/null 2> "$T_TMP/assign-uj.err" || T_RC=$?
  t_same "$T_N council-assign.sh, an arbiter with no claude in its definition: exits" 1 "$T_RC"
  t_same "$T_N council-assign.sh, an arbiter with no claude in its definition: calls the stand-in recorded" 0 "$(t_calls)"
  grep '^plan-council: error:' "$T_TMP/assign-uj.err" > "$T_TMP/assign-uj.line"
  t_has "$T_N council-assign.sh, an arbiter with no claude in its definition: the error line" "$T_TMP/assign-uj.line" "the word claude is not in its definition"
  t_lacks "$T_N council-assign.sh, an arbiter with no claude in its definition: stderr" "$T_TMP/assign-uj.err" "this run continues"
  t_lacks "$T_N council-assign.sh, an arbiter with no claude in its definition: stderr" "$T_TMP/assign-uj.err" "assigning tasks"
done

echo "House rule"

_t_got=$(tr -cd "$(printf '\140')" < "$T_DIR/permission-denials.sh" | wc -c | tr -d ' ')
t_same "scripts/tests/permission-denials.sh: backquote characters" 0 "$_t_got"

echo
echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
