#!/bin/sh
# Tests for the function-body reader and the definition scan in ../lib.sh:
# which text council_check_deny_used reads for a seat, and what it reports
# when it cannot say.
#
# Usage: sh scripts/tests/definitions.sh
#        dash scripts/tests/definitions.sh
#
# Every assertion names the function or script it runs and the output or
# variable it reads, and prints one line. The exit status is non-zero when any
# assertion failed.
#
# The fixtures are written to a temporary directory, which is removed on exit.
# One section sources every fixture in bash, when bash is installed, and
# compares what bash keeps with what the scan names; it is the only place the
# tests source a fixture in bash, and it is skipped, with a line saying so,
# without it. Three fixtures there are known open: the scan passes them while
# bash runs another file's seat. One fixture, an alias for ".", is kept out of
# that comparison and run under sh and dash with a stand-in "claude" instead.
# The section after the house rule runs council-assign.sh and council-doctor.sh,
# under sh, with a stand-in "claude" first on PATH that records that it was
# called and fails; no model is called and nothing outside that directory is
# written. The last section reads which CLI a planner's definition names
# (council_check_clis): it runs council_check_planners and council-doctor.sh
# with a PATH from which every directory holding a claude or a codex is left
# out, and stand-ins put back where a row needs one.
#
# These test the text check, not the process a function starts.
set -u

T_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
T_PLUGIN=$(dirname "$(dirname "$T_DIR")")
. "$T_PLUGIN/scripts/lib.sh"

T_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t plancouncil) || {
  echo "mktemp failed" >&2
  exit 1
}
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

# t_conf NAME -- writes stdin to the fixture NAME and prints its path.
t_conf() {
  cat > "$T_TMP/$1.conf"
  printf '%s\n' "$T_TMP/$1.conf"
}

# t_body LABEL FN FILE LINE EXPECTED -- council_function_body FN FILE [LINE]
# prints EXPECTED. An empty LINE makes the two-argument call.
t_body() {
  if [ -n "$4" ]; then
    _t_got=$(council_function_body "$2" "$3" "$4")
  else
    _t_got=$(council_function_body "$2" "$3")
  fi
  t_same "$1: council_function_body $2 prints" "$5" "$_t_got"
}

# t_check CONF FNS [PLUGIN_ROOT] -- council_check_deny_used FNS, with CONF as
# the config in use and PLUGIN_ROOT, by default this plugin, as the plugin.
# Its return code goes to T_RC, its messages to $T_TMP/stderr.
t_check() {
  COUNCIL_CONFIG_USED=$1
  COUNCIL_PLUGIN_ROOT=${3:-$T_PLUGIN}
  # Cleared first, so that no assertion can pass on a value an earlier
  # fixture left behind.
  unset COUNCIL_DENY_UNCOVERED COUNCIL_CHECK_NODENY COUNCIL_CHECK_NOFLAGS \
    COUNCIL_CHECK_NOBASH COUNCIL_CHECK_UNKNOWN COUNCIL_CHECK_UNKNOWN_AT \
    COUNCIL_CHECK_SHADOWED
  T_RC=0
  council_check_deny_used "$2" 2>"$T_TMP/stderr" || T_RC=$?
}

# t_var LABEL FN VAR EXPECTED -- after t_check, VAR holds EXPECTED.
t_var() {
  eval "_t_got=\${$3-}"
  t_same "$1: council_check_deny_used $2 sets $3" "$4" "$_t_got"
}

# t_rc LABEL FN EXPECTED -- after t_check, the return code was EXPECTED.
t_rc() {
  t_same "$1: council_check_deny_used $2 returns" "$3" "$T_RC"
}

# The check skips a name the shell does not know, so every name the fixtures
# ask about is defined here. These bodies are never read: the check reads the
# fixture files.
arbiter() { :; }
planner_claude() { :; }
planner_claude_alt() { :; }
planner_mine() { :; }
planner_gemini() { :; }

echo "Where a body ends"

F=$(t_conf multiline <<'CONF'
# a comment
arbiter() {
  claude -p --model m \
    > "$1"
}
planner_claude() {
  claude -p > "$1"
}
CONF
)
t_body "multi-line, } in column 1" arbiter "$F" "" "$(sed -n '2,5p' "$F")"

F=$(t_conf content-on-def-line <<'CONF'
arbiter() { claude -p --model m \
    > "$1"
}
CONF
)
t_body "content on the definition line, } in column 1" arbiter "$F" "" "$(sed -n '1,3p' "$F")"

F=$(t_conf one-line <<'CONF'
arbiter() { claude -p > "$1"; }
planner_claude() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
CONF
)
t_body "one line meeting R1, then another function" arbiter "$F" "" 'arbiter() { claude -p > "$1"; }'
# Before R1 the reader ran on into planner_claude and passed arbiter on that
# function's text.
t_check "$F" arbiter
t_var "one line without the deny rule, then a function with it" arbiter COUNCIL_CHECK_NODENY " arbiter"
t_var "one line without the deny rule, then a function with it" arbiter COUNCIL_CHECK_UNKNOWN ""

F=$(t_conf one-line-amp <<'CONF'
arbiter() { claude -p > "$1" & }
CONF
)
t_body "one line ending in & }" arbiter "$F" "" 'arbiter() { claude -p > "$1" & }'

# Some awk builds, the one in Git for Windows among them, drop the CR before
# the reader sees it, and others keep it; the comparison sets it aside so the
# assertion means the same on both. Only an awk that keeps it can show that
# council_r1 ignores it.
F="$T_TMP/crlf.conf"
printf 'arbiter() { claude -p > "$1"; }  \r\n' > "$F"
_t_got=$(council_function_body arbiter "$F" | tr -d '\r')
t_same "one line meeting R1, CRLF and trailing blanks: council_function_body arbiter prints, CR aside" 'arbiter() { claude -p > "$1"; }  ' "$_t_got"

echo "Shapes that must come back unread"

F=$(t_conf expansion <<'CONF'
arbiter() { claude -p --model "${M}" > "$1"; }
planner_claude() {
  claude -p > "$1"
}
CONF
)
t_body "one line with \${...}, then a definition" arbiter "$F" "" ""

# Read as one line this body would be right; the rule asks for exactly one
# "}" and does not try to tell which extra one is harmless.
F=$(t_conf two-closers <<'CONF'
arbiter() { echo "}" > "$1"; }
CONF
)
t_body "one line with two }, then end of file" arbiter "$F" "" ""

F=$(t_conf hash <<'CONF'
arbiter() { claude -p "#1" > "$1"; }
CONF
)
t_body "one line with a #, then end of file" arbiter "$F" "" ""

F=$(t_conf dquote <<'CONF'
arbiter() { echo "; }
"; claude -p > "$1"; }
CONF
)
t_body "one line with an odd count of double quotes" arbiter "$F" "" ""

F=$(t_conf squote <<'CONF'
arbiter() { echo '; }
'; claude -p > "$1"; }
CONF
)
t_body "one line with an odd count of single quotes" arbiter "$F" "" ""

F=$(t_conf no-terminator <<'CONF'
arbiter() { cat }
  claude -p > "$1"; }
CONF
)
t_body "one line ending in } without ; or &" arbiter "$F" "" ""

F=$(t_conf midline-close <<'CONF'
arbiter() {
  claude -p > "$1"; }
planner_claude() {
  claude -p > "$1"
}
CONF
)
t_body "close mid-line, then a definition" arbiter "$F" "" ""

F=$(t_conf indented-close <<'CONF'
arbiter() {
  claude -p > "$1"
  }
CONF
)
t_body "indented close, then end of file" arbiter "$F" "" ""

F=$(t_conf subshell <<'CONF'
arbiter() ( claude -p > "$1" )
planner_claude() {
  claude -p > "$1"
}
CONF
)
t_body "a ( ... ) body, then a definition" arbiter "$F" "" ""

F=$(t_conf nested-def <<'CONF'
arbiter() {
  claude -p > "$1"
helper() { :; }
}
CONF
)
t_body "a column-1 definition inside the body" arbiter "$F" "" ""

F=$(t_conf unterminated <<'CONF'
arbiter() {
  claude -p > "$1"
CONF
)
t_body "unterminated at end of file" arbiter "$F" "" ""

echo "The two holes a one-line rule must not open"

# The "#" comments out the brace: the body runs on to the } in column 1, and
# it holds claude. Read as one line it has no claude, and a function without
# claude sets no return code.
F=$(t_conf hole-comment <<'CONF'
arbiter() { # ; }
  claude -p > "$1"
}
CONF
)
t_body "hole: a # before ; }" arbiter "$F" "" "$(sed -n '1,3p' "$F")"
t_check "$F" arbiter
t_var "hole: a # before ; }" arbiter COUNCIL_CHECK_NODENY " arbiter"
t_var "hole: a # before ; }" arbiter COUNCIL_DENY_UNCOVERED ""
t_rc "hole: a # before ; }" arbiter 1

# The "; }" closes the inner group, not the body.
F=$(t_conf hole-group <<'CONF'
arbiter() { [ -n "$1" ] || { echo usage >&2; return 1; }
  claude -p > "$1"
}
CONF
)
t_body "hole: an inner group closing on the definition line" arbiter "$F" "" "$(sed -n '1,3p' "$F")"
t_check "$F" arbiter
t_var "hole: an inner group closing on the definition line" arbiter COUNCIL_CHECK_NODENY " arbiter"
t_var "hole: an inner group closing on the definition line" arbiter COUNCIL_DENY_UNCOVERED ""
t_rc "hole: an inner group closing on the definition line" arbiter 1

echo "Shapes the reader leaves unread are unknown to the check"

# Each of these, read as its first line only, has no claude and would set no
# return code.
for _t_name in dquote squote no-terminator; do
  t_check "$T_TMP/$_t_name.conf" arbiter
  t_var "$_t_name" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:unread:1"
  t_var "$_t_name" arbiter COUNCIL_DENY_UNCOVERED ""
  t_rc "$_t_name" arbiter 1
done

echo "Which definition runs"

# config/council.conf as the config in use: every seat it ships is read where
# it is defined. Its top-level "if" must close again, or every seat would be
# unknown.
t_check "$T_PLUGIN/config/council.conf" "arbiter planner_claude"
t_var "the plugin's own config" "arbiter planner_claude" COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "the plugin's own config" "arbiter planner_claude" 0

# The layout /council-setup writes: settings, then the source line.
F=$(t_conf setup-layout <<'CONF'
COUNCIL_PLANNERS="${COUNCIL_PLANNERS:-claude claude_alt}"
COUNCIL_BUDGET_USD="${COUNCIL_BUDGET_USD-}"

. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" "arbiter planner_claude"
t_var "the layout /council-setup writes" "arbiter planner_claude" COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "the layout /council-setup writes" "arbiter planner_claude" 0

# Case A: the project redefines a seat after the source line, and its body
# is the one that runs.
F=$(t_conf case-a <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
arbiter() {
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "case A, a bad body after the source line" arbiter COUNCIL_CHECK_NODENY " arbiter"
t_var "case A, a bad body after the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_var "case A, a bad body after the source line" arbiter COUNCIL_CHECK_SHADOWED ""

# Case B: the project defines a seat and then sources the plugin's config,
# whose body is the one that runs. A stand-in plugin whose arbiter lacks the
# rule shows which of the two bodies was read.
mkdir -p "$T_TMP/plugin-bad/config"
cat > "$T_TMP/plugin-bad/config/council.conf" <<'CONF'
arbiter() {
  claude -p > "$1"
}
CONF
F=$(t_conf case-b <<'CONF'
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter "$T_TMP/plugin-bad"
t_var "case B, a good body before the source line of a bad plugin" arbiter COUNCIL_CHECK_NODENY " arbiter"
t_var "case B, a good body before the source line of a bad plugin" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_var "case B, a good body before the source line of a bad plugin" arbiter COUNCIL_CHECK_SHADOWED " arbiter:1:4"

# Case C: a third file sourced after the source line may define the seat.
F=$(t_conf case-c <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
. "$HOME/my-seats.conf"
CONF
)
t_check "$F" arbiter
t_var "case C, a file sourced after the source line" arbiter COUNCIL_CHECK_UNKNOWN " arbiter"
t_var "case C, a file sourced after the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:2"
t_rc "case C, a file sourced after the source line" arbiter 1

F=$(t_conf case-c-alone <<'CONF'
. ./seats.conf
CONF
)
t_check "$F" arbiter
t_var "case C, a sourced file and no definition" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_conf helper-before <<'CONF'
. "$HOME/helpers.sh"
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a helper sourced before the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a helper sourced before the source line" arbiter 0

# The cost of the rule: an unrelated helper after the source line makes every
# seat unknown, until a definition follows it.
F=$(t_conf helper-after <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
. "$HOME/helpers.sh"
CONF
)
t_check "$F" "arbiter planner_claude"
t_var "a helper sourced after the source line" "arbiter planner_claude" COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:2 planner_claude:other:2"

F=$(t_conf helper-after-then-def <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
. "$HOME/helpers.sh"
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "a helper sourced, then a definition" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a helper sourced, then a definition" arbiter 0

F=$(t_conf helper-in-body <<'CONF'
load_mine() {
  . "$HOME/mine.conf"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a file sourced inside a function body" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:2:1"

F=$(t_conf helper-in-one-line-body <<'CONF'
load_mine() { . "$HOME/mine.conf"; }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a file sourced inside a one-line body" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:1:1"

F=$(t_conf plugin-forms <<'CONF'
. ${COUNCIL_PLUGIN_ROOT}/config/council.conf
CONF
)
t_check "$F" arbiter
t_var "the braced, unquoted source line" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
F="$T_TMP/plugin-literal.conf"
printf 'source "%s/config/council.conf" || exit 1\n' "$T_PLUGIN" > "$F"
t_check "$F" arbiter
t_var "source with the literal path, then ||" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

echo "A source line that may not run"

F=$(t_conf cond-if <<'CONF'
arbiter() {
  claude -p > "$1"
}
if [ -n "${USE_PLUGIN-}" ]; then
  . "$COUNCIL_PLUGIN_ROOT/config/council.conf"
fi
CONF
)
t_check "$F" arbiter
t_var "inside a multi-line if" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:5"

F=$(t_conf cond-andand <<'CONF'
[ -f "$COUNCIL_PLUGIN_ROOT/config/council.conf" ] && . "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "after && on one line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:1"
# The file is the plugin config, which the check does read: the reason must
# not send the author looking for another file.
case "$(council_unknown_reasons)" in
  *"sources a file the check does not read"*) _t_got=other-file ;;
  *"sources the plugin's config/council.conf where the check cannot tell"*) _t_got=plugin-config ;;
  *) _t_got=neither ;;
esac
t_same "after && on one line: council_unknown_reasons names" plugin-config "$_t_got"

F=$(t_conf cond-continued <<'CONF'
[ -n "${USE_PLUGIN-}" ] &&
  . "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "on a line continued from &&" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:2"

F=$(t_conf cond-group <<'CONF'
[ -n "${USE_PLUGIN-}" ] && {
  . "$COUNCIL_PLUGIN_ROOT/config/council.conf"
}
CONF
)
t_check "$F" arbiter
t_var "inside a multi-line { } group" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:2"

F=$(t_conf cond-background <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf" &
CONF
)
t_check "$F" arbiter
t_var "followed by &" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:1"

F=$(t_conf cond-def <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
if [ -n "${MINE-}" ]; then
arbiter() {
  claude -p > "$1"
}
fi
CONF
)
t_check "$F" arbiter
t_var "a definition inside a multi-line if" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:3"

F=$(t_conf form-indented <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
if [ -n "${MINE-}" ]; then
  arbiter() {
    claude -p > "$1"
  }
fi
CONF
)
t_check "$F" arbiter
t_var "an indented definition" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:form:3"

F=$(t_conf form-blank <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
arbiter () {
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "a definition with a blank before ()" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:form:2"

F=$(t_conf blocks-closed <<'CONF'
if [ -z "${COUNCIL_MODE-}" ]; then
  COUNCIL_MODE=
fi
for _x in a b; do :; done
case "${X-}" in
  a) Y=1 ;;
esac
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "after blocks that have closed" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "after blocks that have closed" arbiter 0

# A closing word inside a string is not a closing word.
F=$(t_conf closing-word-in-string <<'CONF'
echo "a; done here"
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a closing word inside a string" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a closing word inside a string" arbiter 0

# A closing word the tracking cannot match leaves it unable to say whether a
# later line runs. Here it is a stray "fi", which the shell rejects too.
F=$(t_conf blocks-confused <<'CONF'
fi
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "after a closing word with no opening one" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:2"

echo "Duplicate definitions"

F=$(t_conf dup-good-then-bad <<'CONF'
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
arbiter() {
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "a good definition, then a bad one" arbiter COUNCIL_CHECK_NODENY " arbiter"
t_body "a good definition, then a bad one, from line 4" arbiter "$F" 4 "$(sed -n '4,6p' "$F")"
# The two-argument call, which council_check_deny_used makes for the
# plugin's own definition, still reads the first.
t_body "a good definition, then a bad one, two arguments" arbiter "$F" "" "$(sed -n '1,3p' "$F")"
t_body "a start line that is not a definition of it" arbiter "$F" 2 ""

F=$(t_conf dup-bad-then-good <<'CONF'
arbiter() {
  claude -p > "$1"
}
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "a bad definition, then a good one" arbiter COUNCIL_CHECK_NODENY ""
t_rc "a bad definition, then a good one" arbiter 0

F=$(t_conf dup-last-unread <<'CONF'
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
arbiter() { claude -p --model "${M}" > "$1"; }
CONF
)
t_check "$F" arbiter
t_var "a good definition, then one the reader cannot end" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:unread:4"

echo "A function the plugin does not ship"

# The layout commands/council-setup.md recommends for it: above the source
# line. The source line cannot change it, so the definition is the one read.
F=$(t_conf own-above <<'CONF'
planner_mine() {
  claude -p > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" planner_mine
t_var "a bad function the plugin does not ship, above the source line" planner_mine COUNCIL_CHECK_NODENY " planner_mine"
t_var "a bad function the plugin does not ship, above the source line" planner_mine COUNCIL_CHECK_UNKNOWN_AT ""
t_var "a bad function the plugin does not ship, above the source line" planner_mine COUNCIL_CHECK_SHADOWED ""

F=$(t_conf own-above-good <<'CONF'
planner_mine() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" "arbiter planner_mine"
t_var "a good function the plugin does not ship, above the source line" "arbiter planner_mine" COUNCIL_CHECK_SHADOWED ""
t_var "a good function the plugin does not ship, above the source line" "arbiter planner_mine" COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a good function the plugin does not ship, above the source line" "arbiter planner_mine" 0

echo "A definition that never runs"

# Case B with the plugin as shipped: the body that runs carries everything a
# seat must, and the run is still refused, because the one written never runs.
F=$(t_conf shadowed <<'CONF'
arbiter() {
  claude -p > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" "arbiter planner_claude"
t_var "a seat defined above the source line" "arbiter planner_claude" COUNCIL_CHECK_SHADOWED " arbiter:1:4"
t_var "a seat defined above the source line" "arbiter planner_claude" COUNCIL_CHECK_NODENY ""
t_var "a seat defined above the source line" "arbiter planner_claude" COUNCIL_CHECK_UNKNOWN ""
t_rc "a seat defined above the source line" "arbiter planner_claude" 1

COUNCIL_CONFIG_USED=$F
COUNCIL_PLUGIN_ROOT=$T_PLUGIN
T_RC=0
(council_require_deny_used arbiter) 2>"$T_TMP/stderr" || T_RC=$?
t_same "a seat defined above the source line: council_require_deny_used arbiter exits" 1 "$T_RC"
# Only the line council_die writes: the check's own warning, above it on
# stderr, names the same lines.
case "$(grep '^plan-council: error:' "$T_TMP/stderr")" in
  *"arbiter at line 1, defined again by the file sourced at line 4;"*) _t_got=shadow ;;
  *"lacks what every seat must carry"*) _t_got=generic ;;
  *) _t_got=other ;;
esac
t_same "a seat defined above the source line: council_require_deny_used arbiter dies with" shadow "$_t_got"

F=$(t_conf shadowed-then-redefined <<'CONF'
arbiter() {
  claude -p > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "defined above and below the source line" arbiter COUNCIL_CHECK_SHADOWED ""
t_rc "defined above and below the source line" arbiter 0

# Unknown comes first: a definition that never runs is not reported while the
# check cannot tell what runs.
F=$(t_conf shadowed-then-other <<'CONF'
arbiter() {
  claude -p > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
. "$HOME/my-seats.conf"
CONF
)
t_check "$F" arbiter
t_var "defined above the source line, then a file sourced" arbiter COUNCIL_CHECK_SHADOWED ""
t_var "defined above the source line, then a file sourced" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:5"

F=$(t_conf shadowed-and-unknown <<'CONF'
arbiter() {
  claude -p > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
planner_claude() { claude -p --model "${M}" > "$1"; }
CONF
)
COUNCIL_CONFIG_USED=$F
T_RC=0
(council_require_deny_used "arbiter planner_claude") 2>"$T_TMP/stderr" || T_RC=$?
t_same "one seat never runs, another unread: council_require_deny_used exits" 1 "$T_RC"
case "$(cat "$T_TMP/stderr")" in
  *"plan-council: error: could not tell which definition runs"*) _t_got=unknown ;;
  *"plan-council: error: in "*"never runs"*) _t_got=shadow ;;
  *) _t_got=other ;;
esac
t_same "one seat never runs, another unread: council_require_deny_used dies with" unknown "$_t_got"

echo "Byte for byte, the shapes read as before"

# The reader as it was before the one-line rule. council_check_deny_used
# calls council_function_body with two arguments (the canary did too, until 2026-11-20) and must
# get the same bytes for every shape both read. Compared as files with cmp:
# a command substitution would drop trailing newlines and hide a difference.
t_old_body() {
  awk -v fn="$1" '
    index($0, fn "()") == 1 { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$2"
}

# t_cmp LABEL FN FILE -- council_function_body FN FILE prints the same bytes
# as the reader before the one-line rule.
t_cmp() {
  t_old_body "$2" "$3" > "$T_TMP/old.out"
  council_function_body "$2" "$3" > "$T_TMP/new.out"
  if cmp -s "$T_TMP/old.out" "$T_TMP/new.out"; then _t_got=same; else _t_got=different; fi
  t_same "$1: council_function_body $2 prints the bytes the earlier reader printed" same "$_t_got"
}

for _t_fn in arbiter planner_claude planner_claude_alt planner_fable planner_codex; do
  t_cmp "config/council.conf" "$_t_fn" "$T_PLUGIN/config/council.conf"
done
F=$(t_conf brace-next-line <<'CONF'
arbiter()
{
  claude -p > "$1"
}
CONF
)
t_cmp "{ on the line after the definition" arbiter "$F"
F=$(t_conf name-prefix <<'CONF'
planner_claude_alt() {
  claude -p --model alt > "$1"
}
planner_claude() {
  claude -p --model main > "$1"
}
CONF
)
t_cmp "a name that begins with another" planner_claude "$F"
t_cmp "a name that begins with another" planner_claude_alt "$F"
t_cmp "hole: a # before ; }" arbiter "$T_TMP/hole-comment.conf"
t_cmp "hole: an inner group closing on the definition line" arbiter "$T_TMP/hole-group.conf"

echo "More one-line shapes"

F=$(t_conf one-line-passes <<'CONF'
arbiter() { claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"; }
planner_claude() {
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "one line carrying all three" arbiter COUNCIL_CHECK_UNKNOWN ""
t_rc "one line carrying all three" arbiter 0

F=$(t_conf continued-midline <<'CONF'
arbiter() { claude -p \
  > "$1"; }
planner_claude() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
CONF
)
t_body "content on the definition line, closed mid-line, then a definition" arbiter "$F" "" ""
t_check "$F" arbiter
t_var "content on the definition line, closed mid-line, then a definition" arbiter COUNCIL_CHECK_UNKNOWN " arbiter"

# The final "; }" of line 1 sits inside the double quote that line 2 closes.
F=$(t_conf open-quote-closed <<'CONF'
arbiter() { V="a; }
"; claude -p $(council_seat_flags) --disallowedTools Bash > "$1"
}
CONF
)
t_body "an odd count of double quotes, } in column 1" arbiter "$F" "" "$(sed -n '1,3p' "$F")"
t_check "$F" arbiter
t_var "an odd count of double quotes, } in column 1" arbiter COUNCIL_CHECK_NODENY " arbiter"
t_var "an odd count of double quotes, } in column 1" arbiter COUNCIL_DENY_UNCOVERED ""
t_rc "an odd count of double quotes, } in column 1" arbiter 1

# The price of the parity rule, paid in the closed direction: a correct
# one-liner with an apostrophe inside double quotes is not read.
F=$(t_conf apostrophe <<'CONF'
arbiter() { claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" --append-system-prompt "don't" > "$1"; }
planner_claude() {
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "price: a correct one-liner with an apostrophe" arbiter COUNCIL_CHECK_UNKNOWN " arbiter"

F=$(t_conf bash-function <<'CONF'
arbiter() {
  claude -p > "$1"; }
function other {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
CONF
)
t_body "closed mid-line, then a bash function keyword" arbiter "$F" "" ""

F=$(t_conf bash-function-def <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
function arbiter {
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "a definition with the bash function keyword" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:form:2"

# A one-line function the plugin does not ship, above the source line: the
# scan must see where it ends, or the source line reads as inside it and
# every seat is unknown.
F=$(t_conf one-line-own-above <<'CONF'
planner_gemini() { gemini --model x > "$1"; }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" "arbiter planner_gemini"
t_var "a one-line function not shipped, above the source line" "arbiter planner_gemini" COUNCIL_CHECK_UNKNOWN_AT ""
t_var "a one-line function not shipped, above the source line" "arbiter planner_gemini" COUNCIL_DENY_UNCOVERED " planner_gemini"
t_rc "a one-line function not shipped, above the source line" "arbiter planner_gemini" 0

echo "An arbiter the check did not judge"

# t_unjudged LABEL EXPECTED -- after t_check, council_arbiter_unjudged answers
# EXPECTED, yes or no.
t_unjudged() {
  if council_arbiter_unjudged 2> /dev/null; then _t_got=yes; else _t_got=no; fi
  t_same "$1: council_arbiter_unjudged" "$2" "$_t_got"
}

# An arbiter that hands the claude call to a helper. The helper carries all
# three requirements, but the check reads the arbiter's own definition, which
# holds no claude, so none of them was checked for it.
F=$(t_conf unjudged-one-line <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
run_seat() {
  claude -p --model "$1" $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$2"
}
arbiter() { run_seat opus "$@"; }
CONF
)
T_F1=$F
t_check "$F" arbiter
t_var "an arbiter that calls a helper" arbiter COUNCIL_DENY_UNCOVERED " arbiter"
t_rc "an arbiter that calls a helper" arbiter 0
_t_got=$(cat "$T_TMP/stderr")
t_same "an arbiter that calls a helper: council_check_deny_used arbiter prints on stderr" "" "$_t_got"
t_unjudged "an arbiter that calls a helper" yes
_t_msg=$(council_arbiter_unjudged_message 2> /dev/null)
for _t_w in "the word claude is not in its definition" "Write the claude command line in arbiter itself" "There is no option to skip"; do
  case "$_t_msg" in
    *"$_t_w"*) _t_got=present ;;
    *) _t_got=absent ;;
  esac
  t_same "an arbiter that calls a helper: council_arbiter_unjudged_message holds [$_t_w]" present "$_t_got"
done
# It names one role, and claims nothing for the others.
for _t_w in " every " " any "; do
  case "$_t_msg" in
    *"$_t_w"*) _t_got=present ;;
    *) _t_got=absent ;;
  esac
  t_same "an arbiter that calls a helper: council_arbiter_unjudged_message holds [$_t_w]" absent "$_t_got"
done

# An arbiter that drives another CLI looks the same to the check.
F=$(t_conf unjudged-other-cli <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
arbiter() {
  codex exec --sandbox read-only --skip-git-repo-check --output-last-message "$1" - > /dev/null
}
CONF
)
t_check "$F" arbiter
t_unjudged "an arbiter that drives another CLI" yes

# One word, not a list that is not empty: a planner with no claude in its
# definition lands in the same list, beside an arbiter that was judged, as in
# the doctor's single call.
t_check "$T_TMP/one-line-own-above.conf" "arbiter planner_gemini"
t_unjudged "a judged arbiter beside a planner with no claude" no

# An arbiter the reader leaves unread is unknown, refused on that ground.
t_check "$T_TMP/dquote.conf" arbiter
t_unjudged "an arbiter left unread" no

echo "A definition that may not run, after one that does"

F=$(t_conf cond-def-after-def <<'CONF'
arbiter() {
  claude -p > "$1"
}
if false; then
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
fi
CONF
)
t_check "$F" arbiter
t_var "a good definition inside if false, after a bad one" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:5"

echo "What the shadow test relies on"

# Clause 3 reads config/council.conf alone. That holds while the mode files it
# loads define no function.
for _t_mode in "$T_PLUGIN"/config/modes/*.conf; do
  _t_got=$(grep -c -E '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*[(][)]|function[[:space:]])' "$_t_mode")
  t_same "config/modes/${_t_mode##*/}: grep counts function definitions" 0 "$_t_got"
done

F=$T_TMP/shadowed.conf
t_check "$F" arbiter
t_var "a seat defined above the source line" arbiter COUNCIL_CHECK_NOFLAGS ""
t_var "a seat defined above the source line" arbiter COUNCIL_CHECK_NOBASH ""
case "$(cat "$T_TMP/stderr")" in
  *"arbiter at line 1, defined again by the file sourced at line 4;"*) _t_got=both ;;
  *) _t_got=missing ;;
esac
t_same "a seat defined above the source line: council_check_deny_used arbiter names both lines on stderr" both "$_t_got"

echo "Shapes the reader reads wrongly, which the check no longer judges"

# council_function_body still reads these wrongly; it is kept as it is (it
# was kept for the canary until 2026-11-20). The check compares the line where it stops with the line where
# the scan sees the body close, and reports the body unread. Each of these
# passed the check before that comparison.
#
# (i) A body that fails the one-line rule, followed by a top-level "}" in
# column 1 that is not its own: read too far, into text that carries all
# three.
F=$(t_conf open-too-far <<'CONF'
arbiter() {
  claude -p > "$1"; }
{ : $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2"
}
CONF
)
t_check "$F" arbiter
t_var "(i) read too far" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:unread:1"
t_rc "(i) read too far" arbiter 1

# (ii) The one-line rule met while its "; }" sits inside an open quote: the
# apostrophe inside double quotes balances the count.
F=$(t_conf open-in-quote <<'CONF'
arbiter() { V="a'b" W='c; }
'; claude -p > "$1"; }
CONF
)
t_check "$F" arbiter
t_var "(ii) read too little" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:unread:1"
t_var "(ii) read too little" arbiter COUNCIL_DENY_UNCOVERED ""
t_rc "(ii) read too little" arbiter 1

# (iii) A "}" in column 1 inside the body, here in a heredoc.
F=$(t_conf open-heredoc <<'CONF'
arbiter() {
  cat <<EOF
}
EOF
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "(iii) read too little" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:unread:1"
t_var "(iii) read too little" arbiter COUNCIL_DENY_UNCOVERED ""
t_rc "(iii) read too little" arbiter 1

echo "Functions defined after column 1"

# Its body is where the "." is, so it counts at the end of the file, after
# every definition. Read where it is written, above the source line, it
# came before the winning line and was never looked at.
F=$(t_conf indented-one-line-helper <<'CONF'
  load_mine() { . "$HOME/mine.conf"; }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a file sourced in an indented one-line body, above the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:1:1"

F=$(t_conf indented-multi-line-helper <<'CONF'
  load_mine() {
    . "$HOME/mine.conf"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a file sourced in an indented multi-line body, above the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:2:1"

F=$(t_conf helper-in-if-called-later <<'CONF'
if true; then
  helper() { . "$HOME/x.conf"; }
fi
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
helper
CONF
)
t_check "$F" arbiter
t_var "a helper defined in an if, called after a good definition" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:2:2"

# A body that closes on its own line hands the rest of the line back, so the
# "fi" after it still closes the block.
F=$(t_conf one-line-if-with-definition <<'CONF'
if true; then f() { :; }; fi
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a one-line if holding a one-line definition" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a one-line if holding a one-line definition" arbiter 0

# POSIX allows the body to start on the line after the parentheses. When the
# definition line ends there, the next line opens the body.
F=$(t_conf brace-next-line-indented <<'CONF'
  load_mine()
  {
    . "$HOME/mine.conf"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
load_mine
CONF
)
t_check "$F" arbiter
t_var "an indented definition with { on the next line, above the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:3:1"

F=$(t_conf brace-next-line-in-if <<'CONF'
if true; then
  load_mine()
  {
    . "$HOME/mine.conf"
  }
fi
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
load_mine
CONF
)
t_check "$F" arbiter
t_var "the same inside an if, then a good definition" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:4:2"

F=$(t_conf function-brace-next-line <<'CONF'
  function load_mine
  {
    . "$HOME/mine.conf"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "function NAME with { on the next line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:3:1"

F=$(t_conf paren-next-line <<'CONF'
  load_mine()  # a subshell body
  (
    . "$HOME/mine.conf"
  )
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a ( ) body with ( on the next line, after a comment" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:3:1"

# What follows the brace that closes such a body is read again, so the "fi"
# after it still closes the block.
F=$(t_conf closing-brace-then-fi <<'CONF'
if true; then
  f() {
    :
  }; fi
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a body closed by }; fi" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a body closed by }; fi" arbiter 0

F=$(t_conf closing-paren-then-fi <<'CONF'
if true; then
  f() (
    :
  ); fi
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a ( ) body closed by ); fi" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a ( ) body closed by ); fi" arbiter 0

echo "A comment after &&"

F=$(t_conf andand-comment <<'CONF'
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
[ -n "${X-}" ] && # only when X is set
arbiter() {
  claude -p > "$1"
}
CONF
)
t_check "$F" arbiter
t_var "a definition after && and a comment" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:5"
# The line at fault holds a definition, so the advice must cover one.
case "$(council_unknown_reasons)" in
  *"a definition in column 1"*) _t_got=covers-definition ;;
  *) _t_got=source-line-only ;;
esac
t_same "a definition after && and a comment: council_unknown_reasons advises" covers-definition "$_t_got"

echo "The plugin config sourced where it does not count"

F=$(t_conf plugin-one-line-if <<'CONF'
if [ -f "$COUNCIL_PLUGIN_ROOT/config/council.conf" ]; then . "$COUNCIL_PLUGIN_ROOT/config/council.conf"; fi
CONF
)
t_check "$F" arbiter
t_var "in a one-line if" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:cond:1"

F=$(t_conf plugin-spelling <<'CONF'
. "${COUNCIL_PLUGIN_ROOT:?}/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "spelled \${COUNCIL_PLUGIN_ROOT:?}" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:spelling:1"
case "$(council_unknown_reasons)" in
  *"in a spelling the check does not take"*) _t_got=spelling ;;
  *) _t_got=other ;;
esac
t_same "spelled \${COUNCIL_PLUGIN_ROOT:?}: council_unknown_reasons names" spelling "$_t_got"

echo "A definition of any form above the source line never runs"

F=$(t_conf above-in-if <<'CONF'
if [ -n "${X-}" ]; then
arbiter() {
  claude -p > "$1"
}
fi
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "inside an if, above the source line" arbiter COUNCIL_CHECK_SHADOWED " arbiter:2:6"
t_rc "inside an if, above the source line" arbiter 1

F=$(t_conf above-blank <<'CONF'
arbiter () {
  claude -p > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "with a blank before (), above the source line" arbiter COUNCIL_CHECK_SHADOWED " arbiter:1:4"

F=$(t_conf above-indented <<'CONF'
  arbiter() {
    claude -p > "$1"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "indented, above the source line" arbiter COUNCIL_CHECK_SHADOWED " arbiter:1:4"

F=$(t_conf above-function <<'CONF'
function arbiter {
  claude -p > "$1"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "with the word function, above the source line" arbiter COUNCIL_CHECK_SHADOWED " arbiter:1:4"
t_var "with the word function, above the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

echo "Braces inside quotes, in a body defined after column 1"

# A quoted "}" ended the body early: the "." in it and the real closing
# brace were read as top level, the "}" closed the if, and the source line
# inside it was counted as if it always ran.
F=$(t_conf quoted-brace-ends-body <<'CONF'
. "$HOME/my-seats.conf"
if [ -n "${USE_PLUGIN-}" ]; then
  helper() {
    echo "}"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
fi
CONF
)
t_check "$F" arbiter
t_var "a } in double quotes inside a helper in an if" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"
t_rc "a } in double quotes inside a helper in an if" arbiter 1

# A quoted "{" kept the body open, and the source line after it was read as
# inside the body.
F=$(t_conf quoted-brace-dq <<'CONF'
  helper() {
    echo "{"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a { in double quotes" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a { in double quotes" arbiter 0

F=$(t_conf quoted-brace-sq <<'CONF'
  helper() {
    echo '{'
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a { in single quotes" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

# Inside double quotes a backslash takes the next character with it, so the
# escaped quote does not close them and the brace stays quoted.
F=$(t_conf quoted-brace-escaped-dq <<'CONF'
  helper() {
    echo "\"{"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a { after an escaped double quote" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

# Inside single quotes nothing escapes: the quote after the backslash closes
# them, and the brace after that is in double quotes.
F=$(t_conf backslash-in-sq <<'CONF'
  helper() {
    echo '\' "{"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a backslash inside single quotes" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

# The quote state carries across the lines of one body.
F=$(t_conf quote-across-lines <<'CONF'
  helper() {
    echo "a
    }"
    . "$HOME/mine.conf"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a } in a double-quoted string over two lines" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:4:1"

echo "Shell constructs the recogniser reads"

# Most of these share one shape, built so that a misread is a silent pass:
# a file that defines arbiter is sourced first, then a helper inside an if
# holds the construct, then the source line, then fi. Read wrongly, the
# helper body ends early, its last "}" closes the if, and the source line
# counts as if it always ran. Read rightly, the source line is inside the if
# and the file sourced first may be what defines arbiter.
t_inif() {
  t_conf "$1" <<CONF
. "\$HOME/my-seats.conf"
if [ -n "\${USE_PLUGIN-}" ]; then
  helper() {
$(cat)
  }
. "\$COUNCIL_PLUGIN_ROOT/config/council.conf"
fi
CONF
}

F=$(t_inif construct-expansion <<'BODY'
    x=${1%\}}
BODY
)
t_check "$F" arbiter
t_var "parameter expansion with an escaped }" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_inif construct-expansion-nested <<'BODY'
    x=${1:-${2%\}}}
BODY
)
t_check "$F" arbiter
t_var "a parameter expansion inside another" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_inif construct-heredoc <<'BODY'
    cat <<EOT
}
EOT
BODY
)
t_check "$F" arbiter
t_var "a heredoc holding a } in column 1" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_inif construct-heredoc-quoted <<'BODY'
    cat <<'EOT'
  }
EOT
BODY
)
t_check "$F" arbiter
t_var "a heredoc with a quoted delimiter" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

# <<- strips leading tabs from the body and from the terminator.
F="$T_TMP/construct-heredoc-tabs.conf"
printf '. "$HOME/my-seats.conf"\nif [ -n "${USE_PLUGIN-}" ]; then\n  helper() {\n\tcat <<-EOT\n\t}\n\tEOT\n  }\n. "$COUNCIL_PLUGIN_ROOT/config/council.conf"\nfi\n' > "$F"
t_check "$F" arbiter
t_var "a <<- heredoc with a tab-indented terminator" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_conf construct-heredoc-top <<'CONF'
. "$HOME/my-seats.conf"
cat > /dev/null <<'EOT'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
EOT
CONF
)
t_check "$F" arbiter
t_var "a source line inside a heredoc at top level" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_conf construct-string-top <<'CONF'
. "$HOME/my-seats.conf"
X='
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
'
CONF
)
t_check "$F" arbiter
t_var "a source line inside a multi-line string at top level" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_conf construct-case-brace <<'CONF'
  helper() {
    case "$1" in
      }) : ;;
    esac
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a case pattern })" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a case pattern })" arbiter 0

F=$(t_conf construct-case-fi <<'CONF'
case "${X-}" in
  fi) Y=1 ;;
  (done|esac) Y=2 ;;
esac
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "case patterns fi), (done|esac)" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "case patterns fi), (done|esac)" arbiter 0

F=$(t_conf construct-escaped-quote <<'CONF'
  helper() {
    echo it\'s
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "an escaped quote outside quotes" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

# After a backslash at the end of a line the command goes on, so the "}" on
# the next line is an argument, not the end of the body.
F=$(t_inif construct-escaped-newline <<'BODY'
    echo \
      }
BODY
)
t_check "$F" arbiter
t_var "an escaped newline before a }" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

# The "{" after the "}" keeps a misread from tripping the closing-word rule,
# so that the misread is the silent pass it would otherwise hide.
F=$(t_inif construct-command-substitution <<'BODY'
    x=$(echo }; echo {)
BODY
)
t_check "$F" arbiter
t_var "a command substitution holding a }" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_inif construct-command-substitution-nested <<'BODY'
    x=$(echo $(echo }; echo {) ")")
BODY
)
t_check "$F" arbiter
t_var "a command substitution inside another" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F="$T_TMP/construct-backquote.conf"
printf '. "$HOME/my-seats.conf"\nif [ -n "${USE_PLUGIN-}" ]; then\n  helper() {\n    x=\140echo }\140\n  }\n. "$COUNCIL_PLUGIN_ROOT/config/council.conf"\nfi\n' > "$F"
t_check "$F" arbiter
t_var "backquoted text holding a }" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_conf construct-comment <<'CONF'
  helper() {
    true  # don't
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a quote character in a trailing comment" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

# Inside a parameter expansion a blank and a "#" do not start a comment, so
# the "; }" after it still closes the body.
F=$(t_conf construct-expansion-hash <<'CONF'
helper() { x=${y:- #}; }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a parameter expansion holding a blank and a #" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a parameter expansion holding a blank and a #" arbiter 0

# A function defined inside a command substitution is defined in a subshell,
# and the shell that sources the config does not keep it.
F=$(t_conf construct-definition-in-substitution <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
x=$(arbiter() { claude -p > "$1"; }; echo)
CONF
)
t_check "$F" arbiter
t_var "a definition inside a command substitution" arbiter COUNCIL_CHECK_UNKNOWN_AT ""
t_rc "a definition inside a command substitution" arbiter 0

F=$(t_inif construct-case-in-substitution <<'BODY'
    x=$(case a in a) echo ;; esac)
BODY
)
t_check "$F" arbiter
t_var "a case inside a command substitution" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_inif construct-heredoc-in-substitution <<'BODY'
    x=$(cat <<EOT
)
EOT
)
BODY
)
t_check "$F" arbiter
t_var "a heredoc inside a command substitution" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:1"

F=$(t_conf construct-function-parens <<'CONF'
function load_mine() {
  . "$HOME/mine.conf"
}
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
load_mine
CONF
)
t_check "$F" arbiter
t_var "function NAME() with a source in its body" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:inbody:2:1"

F=$(t_conf construct-eval <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
eval 'arbiter() { claude -p > "$1"; }'
CONF
)
t_check "$F" arbiter
t_var "an eval after the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:other:2"

F=$(t_conf construct-return <<'CONF'
. "$HOME/my-seats.conf"
return 0
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
t_check "$F" arbiter
t_var "a return before the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT " arbiter:exit:2"

# A return or exit after the winning line does not change what it defines.
F=$(t_conf construct-exit-after <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf" || exit 1
CONF
)
t_check "$F" arbiter
t_var "an exit after the source line" arbiter COUNCIL_CHECK_UNKNOWN_AT ""

echo "Shapes for the comparison with bash"

# Written for the comparison below rather than for an assertion of their
# own: each is a shape expected to be hard for the recogniser.
t_conf hard-here-string > /dev/null <<'CONF'
  helper() {
    cat <<< "x"
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
arbiter() {
  claude -p > "$1"
}
CONF
t_conf hard-two-heredocs > /dev/null <<'CONF'
. "$HOME/my-seats.conf"
if [ -n "${USE_PLUGIN-}" ]; then
  helper() {
    cat <<A <<'B'
}
A
}
B
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
fi
CONF
t_conf hard-heredoc-partly-quoted > /dev/null <<'CONF'
. "$HOME/my-seats.conf"
cat > /dev/null <<E"O"F
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
EOF
CONF
t_conf hard-arithmetic > /dev/null <<'CONF'
x=$(( (1 << 2) + ( 3 ) ))
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
t_conf hard-case-arm-sources > /dev/null <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
case "${USE_PLUGIN-}" in
  1) . "$HOME/x.conf" ;;
esac
CONF
t_conf hard-definition-in-substitution > /dev/null <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
x=$(arbiter() { :; }; echo)
CONF
t_conf hard-blank-before-brace > /dev/null <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
arbiter()

# the body follows
{
  claude -p > "$1"
}
CONF
t_conf hard-group-unconditional > /dev/null <<'CONF'
{
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
}
CONF
t_conf hard-continued-source > /dev/null <<'CONF'
. \
  "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
t_conf hard-definition-in-loop > /dev/null <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
while false; do
arbiter() {
  claude -p > "$1"
}
done
CONF
t_conf hard-expansion-default-brace > /dev/null <<'CONF'
. "$HOME/my-seats.conf"
if [ -n "${USE_PLUGIN-}" ]; then
  helper() {
    echo ${x:-}}
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
fi
CONF
t_conf hard-dollar-single-quote > /dev/null <<'CONF'
  helper() {
    echo $'it\'s'
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
t_conf hard-comment-substitution > /dev/null <<'CONF'
  helper() {
    true # $( and } and '
  }
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
t_conf hard-unset > /dev/null <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
unset -f arbiter
CONF

# Three configs the scan is known to pass while bash runs another file's
# seat. They are listed in t_known_open below, so the comparison reports each
# as known open; one that stops failing fails the run, so the list cannot go
# stale. The scan is frozen (see the comment above council_definition_scan),
# so they stay open.
t_conf open-case-in-substitution > /dev/null <<'CONF'
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
x=$(echo case)
. "$HOME/my-seats.conf"
CONF
t_conf open-esac-case-in-substitution > /dev/null <<'CONF'
arbiter() {
  claude -p $(council_seat_flags) --disallowedTools Bash "$COUNCIL_DENY" "$COUNCIL_DENY2" > "$1"
}
x=$(echo "esac" case)
. "$HOME/my-seats.conf"
CONF
t_conf open-command-dot > /dev/null <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
command . "$HOME/my-seats.conf"
CONF

echo "Agreement with bash"

# The scan reads text; a shell runs it. For every fixture written above, and
# for config/council.conf, the definition of arbiter that bash keeps after
# sourcing the fixture is compared with the one council_definition_scan
# names. bash is the oracle because "declare -F" with extdebug prints the
# file and line of the definition it kept, and dash prints no body at all.
# The plugin runs under both shells, so agreeing with bash is not agreeing
# with every POSIX shell. This section is the one place the tests run bash,
# and it is skipped, with a line saying so, when bash is not installed.
#
# Each fixture is sourced twice, with USE_PLUGIN, X and MINE empty and then
# set, because several fixtures branch on them; when the two runs keep
# different definitions, only unknown is right. Otherwise:
#   - the scan naming a definition bash did not keep is a false pass;
#   - the scan saying unknown where bash kept the definition at a line of
#     the fixture, or the plugin's, is a false refusal. The ones the design
#     accepts are listed in t_by_design with their reason. Any other is a
#     failure, and so is a listed one that stops refusing, so the list
#     cannot go stale;
#   - bash keeping a definition from another sourced file agrees only with
#     unknown, and arbiter left undefined agrees with any answer, since the
#     check skips a name the shell does not know;
#   - a false pass the scan is known to make, and is frozen with, is listed
#     in t_known_open. It is reported as known open, not counted as agreeing,
#     and a listed one that gives anything but a false pass fails, as a
#     listed refusal by design does.
# Every fixture written to $T_TMP as a .conf file enters this comparison. The
# alias fixture does not: bash run as bash does not expand the alias, so it
# would agree with the scan here while sh and dash run another seat. It is
# pinned below with a stand-in under sh and dash instead.

# t_known_open NAME -- why the scan passes fixture NAME while bash keeps
# another file's definition. Fails for any other fixture.
t_known_open() {
  case "$1" in
    open-case-in-substitution|open-esac-case-in-substitution)
      echo "inside a command substitution case and esac are counted as words wherever they appear" ;;
    open-command-dot)
      echo "a . after the word command is not taken as a source line" ;;
    *) return 1 ;;
  esac
}

# t_by_design NAME -- why the scan refuses fixture NAME although bash keeps
# a definition the check could read. Fails for any other fixture.
t_by_design() {
  case "$1" in
    helper-in-body|helper-in-one-line-body|indented-one-line-helper|indented-multi-line-helper|function-brace-next-line|paren-next-line|quote-across-lines)
      echo "a file sourced in a function body: the text cannot say when the function is called" ;;
    helper-after)
      echo "a file sourced after the source line: the scan does not read what it defines" ;;
    cond-andand|plugin-one-line-if|cond-def-after-def|hard-definition-in-loop)
      echo "a definition or source line the scan cannot know runs" ;;
    hard-group-unconditional)
      echo "a source line inside a { } group, which the scan tracks as a block" ;;
    hard-dollar-single-quote)
      echo "bash-only syntax, read as sh: under dash this config does not parse" ;;
    plugin-spelling)
      echo "a spelling of the source line the scan does not take" ;;
    form-blank|bash-function-def)
      echo "a definition in a form the reader cannot read" ;;
    construct-eval)
      echo "an eval, whose text the scan does not evaluate" ;;
    *) return 1 ;;
  esac
}

# t_oracle CONF SET -- what bash keeps for arbiter after sourcing CONF: "def
# LINE", "plugin", "other" or "none". SET empty or 1 is the value of the
# variables the fixtures branch on.
t_oracle() {
  _t_o=$(cd "$T_TMP/home" && HOME="$T_TMP/home" COUNCIL_PLUGIN_ROOT="$T_PLUGIN" \
    USE_PLUGIN="$2" X="$2" MINE="$2" \
    bash -c 'shopt -s extdebug; . "$1" > /dev/null 2>&1; . "$2" > /dev/null 2>&1 < /dev/null; declare -F arbiter' \
    t_oracle "$T_PLUGIN/scripts/lib.sh" "$1" 2> /dev/null)
  if [ -z "$_t_o" ]; then echo none; return; fi
  _t_ol=${_t_o#arbiter }
  _t_of=${_t_ol#* }
  _t_ol=${_t_ol%% *}
  if [ "$_t_of" = "$1" ]; then echo "def $_t_ol"
  elif [ "$_t_of" = "$T_PLUGIN/config/council.conf" ]; then echo plugin
  else echo other
  fi
}

if command -v bash > /dev/null 2>&1; then
  mkdir -p "$T_TMP/home"
  for _t_f in my-seats.conf mine.conf x.conf seats.conf; do
    printf 'arbiter() {\n  claude -p > "$1"\n}\n' > "$T_TMP/home/$_t_f"
  done
  : > "$T_TMP/home/helpers.sh"
  T_AGREE=0
  for _t_f in "$T_PLUGIN/config/council.conf" "$T_TMP"/*.conf; do
    _t_name=${_t_f##*/}
    _t_name=${_t_name%.conf}
    _t_ok=1
    [ "$_t_f" = "$T_PLUGIN/config/council.conf" ] && _t_ok=0
    _t_scan=$(COUNCIL_PLUGIN_ROOT=$T_PLUGIN council_definition_scan arbiter "$_t_f" "$_t_ok")
    case "$_t_scan" in
      "def "*) _t_s=${_t_scan#def }; _t_s="def ${_t_s%% *}" ;;
      "plugin "*) _t_s=plugin ;;
      *) _t_s=unknown ;;
    esac
    _t_o1=$(t_oracle "$_t_f" "")
    _t_o2=$(t_oracle "$_t_f" 1)
    # bash 5.2.21 reports a function whose body holds another definition at
    # the line of that inner one, where bash 5.3.15 reports the line of its
    # own name (both measured 2026-11-19). A line bash reports inside the
    # body the scan names, between the A and Z of "def A Z", is taken as the
    # same definition.
    case "$_t_scan" in
      "def "*)
        _t_a=${_t_scan#def }
        _t_z=${_t_a#* }
        _t_a=${_t_a%% *}
        for _t_v in o1 o2; do
          eval "_t_x=\$_t_$_t_v"
          case "$_t_x" in
            "def "*)
              if [ "${_t_x#def }" -ge "$_t_a" ] && [ "${_t_x#def }" -le "$_t_z" ]; then
                eval "_t_$_t_v=\$_t_s"
              fi ;;
          esac
        done ;;
    esac
    if [ "$_t_o1" != "$_t_o2" ]; then
      if [ "$_t_s" = unknown ]; then _t_v=agree; else _t_v="false pass: bash keeps $_t_o1 or $_t_o2"; fi
    elif [ "$_t_o1" = none ]; then
      _t_v=agree
    elif [ "$_t_o1" = other ]; then
      if [ "$_t_s" = unknown ]; then _t_v=agree; else _t_v="false pass: bash keeps another file's"; fi
    elif [ "$_t_s" = "$_t_o1" ]; then
      _t_v=agree
    elif [ "$_t_s" = unknown ]; then
      _t_v="false refusal: bash keeps $_t_o1"
    else
      _t_v="false pass: bash keeps $_t_o1"
    fi
    _t_why=$(t_by_design "$_t_name") || _t_why=""
    _t_open=$(t_known_open "$_t_name") || _t_open=""
    if [ -n "$_t_open" ]; then
      case "$_t_v" in
        "false pass"*) t_ok "$_t_name: council_definition_scan arbiter, known open ($_t_v, scan $_t_scan): $_t_open" ;;
        *) t_bad "$_t_name: council_definition_scan arbiter, listed as known open" "a false pass" "$_t_v ($_t_scan)" ;;
      esac
      continue
    fi
    case "$_t_v" in
      agree)
        if [ -n "$_t_why" ]; then
          t_bad "$_t_name: council_definition_scan arbiter, listed as refusing by design" "false refusal" "agree ($_t_scan)"
        else
          T_AGREE=$((T_AGREE + 1))
        fi ;;
      "false refusal"*)
        if [ -n "$_t_why" ]; then
          t_ok "$_t_name: council_definition_scan arbiter refuses by design: $_t_why"
        else
          t_bad "$_t_name: council_definition_scan arbiter agrees with bash" "agree" "$_t_v ($_t_scan)"
        fi ;;
      *) t_bad "$_t_name: council_definition_scan arbiter agrees with bash" "agree" "$_t_v ($_t_scan)" ;;
    esac
  done
  t_ok "council_definition_scan arbiter agrees with bash on $T_AGREE fixtures"
else
  echo "skip  bash is not installed, so the scan was not compared with a shell"
fi

echo "The alias fixture, under sh and dash"

# A good definition, then an alias for "." and a call of it on another file.
# The scan names the good definition, and bash run as bash keeps it too,
# since it does not expand aliases there: that is why this fixture is kept
# out of the comparison above, which would count it as agreeing. Under sh and
# dash the alias is expanded and the other file's seat is the one that runs.
# This pins all of that, with a stand-in claude that prints its arguments: a
# change to the scan, or to either shell, makes it fail and is seen.
mkdir -p "$T_TMP/alias" "$T_TMP/alias-home" "$T_TMP/alias-bin"
cat > "$T_TMP/alias/alias-dot.conf" <<'CONF'
arbiter() {
  claude GOOD > "$1"
}
alias src=.
src "$HOME/my-seats.conf"
CONF
printf 'arbiter() {\n  claude OTHER > "$1"\n}\n' > "$T_TMP/alias-home/my-seats.conf"
printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$T_TMP/alias-bin/claude"
chmod +x "$T_TMP/alias-bin/claude"
_t_got=$(COUNCIL_PLUGIN_ROOT=$T_PLUGIN council_definition_scan arbiter "$T_TMP/alias/alias-dot.conf" 0)
t_same "alias-dot: council_definition_scan arbiter prints" "def 1 3" "$_t_got"
if command -v bash > /dev/null 2>&1; then
  _t_got=$(t_oracle "$T_TMP/alias/alias-dot.conf" "")
  t_same "alias-dot: bash, run as bash, keeps" "def 1" "$_t_got"
else
  echo "skip  bash is not installed, so what bash keeps for alias-dot was not asked"
fi
T_ALIAS_SHELLS="sh"
if [ -x /usr/bin/dash ]; then
  T_ALIAS_SHELLS="$T_ALIAS_SHELLS /usr/bin/dash"
elif command -v dash > /dev/null 2>&1; then
  T_ALIAS_SHELLS="$T_ALIAS_SHELLS dash"
else
  echo "skip  dash is not installed, so alias-dot was not run under dash"
fi
for _t_sh in $T_ALIAS_SHELLS; do
  rm -f "$T_TMP/alias/out"
  HOME="$T_TMP/alias-home" PATH="$T_TMP/alias-bin:$PATH" \
    "$_t_sh" -c '. "$1" > /dev/null 2>&1; arbiter "$2"' t \
    "$T_TMP/alias/alias-dot.conf" "$T_TMP/alias/out" > /dev/null 2>&1
  _t_got=$(cat "$T_TMP/alias/out" 2>/dev/null)
  t_same "alias-dot: under $_t_sh, the seat that runs prints" "OTHER" "$_t_got"
done

echo "House rule"

# lib.sh, near its top: no backquote characters anywhere in these scripts.
_t_got=$(cat "$T_PLUGIN"/scripts/*.sh "$T_PLUGIN"/scripts/tests/*.sh | tr -cd "$(printf '\140')" | wc -c | tr -d ' ')
t_same "scripts/*.sh and scripts/tests/*.sh: backquote characters" 0 "$_t_got"

echo "The scripts that act on it"

mkdir -p "$T_TMP/bin" "$T_TMP/root" "$T_TMP/out" "$T_TMP/tmp"
printf '#!/bin/sh\n: > "%s/claude-called"\nexit 1\n' "$T_TMP" > "$T_TMP/bin/claude"
chmod +x "$T_TMP/bin/claude"
printf '# A plan\n\nOne task.\n' > "$T_TMP/plan.md"

# council-assign.sh continues on a missing deny rule, so a dead definition
# needs its own refusal there, before the arbiter is started.
rm -f "$T_TMP/claude-called"
T_RC=0
PATH="$T_TMP/bin:$PATH" TMPDIR="$T_TMP/tmp" COUNCIL_CONFIG="$T_TMP/shadowed.conf" \
  sh "$T_PLUGIN/scripts/council-assign.sh" "$T_TMP/plan.md" --root "$T_TMP/root" \
  --out "$T_TMP/out/assignment.md" > /dev/null 2> "$T_TMP/assign.err" || T_RC=$?
t_same "a seat defined above the source line: council-assign.sh exits" 1 "$T_RC"
if [ -e "$T_TMP/claude-called" ]; then _t_got=called; else _t_got=not-called; fi
t_same "a seat defined above the source line: council-assign.sh starts claude" not-called "$_t_got"
case "$(grep '^plan-council: error:' "$T_TMP/assign.err")" in
  *"never runs"*) _t_got=shadow ;;
  *) _t_got=other ;;
esac
t_same "a seat defined above the source line: council-assign.sh dies with" shadow "$_t_got"

# The doctor discards the check's stderr, so the cause has to reach its
# stdout through the variable.
PATH="$T_TMP/bin:$PATH" TMPDIR="$T_TMP/tmp" COUNCIL_CONFIG="$T_TMP/shadowed.conf" \
  sh "$T_PLUGIN/scripts/council-doctor.sh" --root "$T_TMP/root" --no-model-check \
  > "$T_TMP/doctor.out" 2> /dev/null
if grep -q '^  FAIL  arbiter is defined at line 1 of ' "$T_TMP/doctor.out"; then _t_got=reported; else _t_got=silent; fi
t_same "a seat defined above the source line: council-doctor.sh stdout" reported "$_t_got"

# An arbiter the text check did not judge: the doctor names it, and no ok line
# speaks for it. codex is a planner here, and its definition holds no claude
# either, so a test of the whole list rather than of the word arbiter shows in
# the second run, on the shipped config.
PATH="$T_TMP/bin:$PATH" TMPDIR="$T_TMP/tmp" COUNCIL_CONFIG="$T_F1" COUNCIL_PLANNERS="claude codex" \
  sh "$T_PLUGIN/scripts/council-doctor.sh" --root "$T_TMP/root" --no-model-check \
  > "$T_TMP/doctor-unjudged.out" 2> /dev/null
if grep -q "^  FAIL  the arbiter's definition was read" "$T_TMP/doctor-unjudged.out"; then _t_got=reported; else _t_got=silent; fi
t_same "an arbiter that calls a helper: council-doctor.sh stdout, a FAIL for it" reported "$_t_got"
if grep -q -x -F '  ok    every claude planner passes $COUNCIL_DENY to its CLI' "$T_TMP/doctor-unjudged.out"; then _t_got=present; else _t_got=absent; fi
t_same "an arbiter that calls a helper: council-doctor.sh stdout, the ok line for the planners alone" present "$_t_got"
_t_got=$(grep -c '^  ok    .* and the arbiter ' "$T_TMP/doctor-unjudged.out")
t_same "an arbiter that calls a helper: council-doctor.sh stdout, ok lines that speak for the arbiter" 0 "$_t_got"
_t_got=$(grep '^  note  the text check found no claude in the definition of:' "$T_TMP/doctor-unjudged.out")
t_same "an arbiter that calls a helper: council-doctor.sh stdout, the note" "  note  the text check found no claude in the definition of: planner_codex" "$_t_got"

PATH="$T_TMP/bin:$PATH" TMPDIR="$T_TMP/tmp" COUNCIL_CONFIG="$T_PLUGIN/config/council.conf" COUNCIL_PLANNERS="claude codex" \
  sh "$T_PLUGIN/scripts/council-doctor.sh" --root "$T_TMP/root" --no-model-check \
  > "$T_TMP/doctor-shipped.out" 2> /dev/null
_t_got=$(grep -c '^  ok    every claude planner and the arbiter ' "$T_TMP/doctor-shipped.out")
t_same "the shipped config with codex as a planner: council-doctor.sh stdout, ok lines for the planners and the arbiter" 3 "$_t_got"
if grep -q "^  FAIL  the arbiter's definition was read" "$T_TMP/doctor-shipped.out"; then _t_got=reported; else _t_got=silent; fi
t_same "the shipped config with codex as a planner: council-doctor.sh stdout, a FAIL for the arbiter" silent "$_t_got"
_t_got=$(grep '^  note  the text check found no claude in the definition of:' "$T_TMP/doctor-shipped.out")
t_same "the shipped config with codex as a planner: council-doctor.sh stdout, the note" "  note  the text check found no claude in the definition of: planner_codex" "$_t_got"

# The shipped default planner set, as a run with no project config and no
# COUNCIL_CONFIG gets it: two Claude models, so no planner is left uncovered.
# Decided by a council on 2026-11-23. The root holds no .claude directory, and
# both variables are unset in the subshell, so the plugin's own config is the
# one loaded.
(
  unset COUNCIL_CONFIG COUNCIL_PLANNERS
  PATH="$T_TMP/bin:$PATH" TMPDIR="$T_TMP/tmp" \
    sh "$T_PLUGIN/scripts/council-doctor.sh" --root "$T_TMP/root" --no-model-check \
    > "$T_TMP/doctor-default.out" 2> /dev/null
)
_t_got=$(grep '^  ok    planners: ' "$T_TMP/doctor-default.out")
t_same "no project config: council-doctor.sh stdout, the planners line" "  ok    planners: claude claude_alt" "$_t_got"
_t_got=$(grep -c '^  note  the text check found no claude in the definition of:' "$T_TMP/doctor-default.out")
t_same "no project config: council-doctor.sh stdout, notes on an uncovered planner" 0 "$_t_got"

echo "The CLI a planner drives"

# council_check_planners refuses a planner whose definition names a known CLI
# that command -v does not find, before anything is paid, and only notes one
# whose definition names none. The CLI is read from the definition, never
# from the planner's name: planner_claude_alt drives claude, and there is no
# claude_alt binary to find. These run the check in a subshell, with a PATH
# from which every directory holding a claude or a codex has been left out,
# and a stand-in claude, which is never called, put back where a row needs
# one.

# t_path_without NAME... -- PATH with every directory left out that holds
# NAME or NAME.exe for one of the NAMEs.
t_path_without() {
  _t_out=""
  _t_ifs=$IFS
  IFS=:
  set -f
  for _t_d in $PATH; do
    _t_keep=1
    for _t_n in "$@"; do
      if [ -e "$_t_d/$_t_n" ] || [ -e "$_t_d/$_t_n.exe" ]; then _t_keep=0; fi
    done
    [ "$_t_keep" = 0 ] || _t_out="$_t_out${_t_out:+:}$_t_d"
  done
  set +f
  IFS=$_t_ifs
  printf '%s\n' "$_t_out"
}

# t_planners LABEL CONF PLANNERS PATH -- council_check_planners, in a
# subshell, with CONF as the config in use, this plugin as the plugin, and
# PATH as the PATH. Its exit status goes to T_RC, its stderr to
# $T_TMP/planners.err.
t_planners() {
  T_RC=0
  (
    COUNCIL_CONFIG_USED=$2
    COUNCIL_PLUGIN_ROOT=$T_PLUGIN
    COUNCIL_PLANNERS=$3
    PATH=$4
    council_check_planners
  ) 2> "$T_TMP/planners.err" || T_RC=$?
}

# t_err_has LABEL TEXT -- $T_TMP/planners.err holds TEXT, as a fixed string.
t_err_has() {
  if grep -F -q -e "$2" "$T_TMP/planners.err"; then _t_got=present; else _t_got="absent: $(head -c 400 "$T_TMP/planners.err")"; fi
  t_same "$1: stderr holds [$2]" present "$_t_got"
}

planner_codex() { :; }
planner_fable() { :; }
T_NOCLI=$(t_path_without claude codex)
mkdir -p "$T_TMP/clibin" "$T_TMP/codexbin"
printf '#!/bin/sh\n: > "%s/clibin-called"\nexit 1\n' "$T_TMP" > "$T_TMP/clibin/claude"
printf '#!/bin/sh\n: > "%s/codexbin-called"\nexit 1\n' "$T_TMP" > "$T_TMP/codexbin/codex"
chmod +x "$T_TMP/clibin/claude" "$T_TMP/codexbin/codex"
T_SHIPPED="$T_PLUGIN/config/council.conf"
if PATH=$T_NOCLI command -v claude > /dev/null 2>&1 || PATH=$T_NOCLI command -v codex > /dev/null 2>&1; then
  echo "skip  no PATH could be made here without claude and codex, so the refusal of a missing CLI was not tested"
else

  # The shipped default, claude and claude_alt, with claude installed. A check
  # keyed on the planner's name would look for claude_alt and refuse it.
  t_planners "default planners, claude installed" "$T_SHIPPED" "claude claude_alt" "$T_TMP/clibin:$T_NOCLI"
  t_same "default planners, claude installed: council_check_planners exits" 0 "$T_RC"
  t_same "default planners, claude installed: council_check_planners stderr" "" "$(cat "$T_TMP/planners.err")"

  # The same with claude missing: both planners drive it.
  t_planners "default planners, claude missing" "$T_SHIPPED" "claude claude_alt" "$T_NOCLI"
  t_same "default planners, claude missing: council_check_planners exits" 1 "$T_RC"
  t_err_has "default planners, claude missing" "plan-council: error: a CLI is not installed here (command -v did not find it on PATH): planner_claude drives claude; planner_claude_alt drives claude. "
  t_err_has "default planners, claude missing" "Nothing has been run."

  # Codex as a planner, codex missing and claude installed: only codex named.
  t_planners "claude and codex, codex missing" "$T_SHIPPED" "claude codex" "$T_TMP/clibin:$T_NOCLI"
  t_same "claude and codex, codex missing: council_check_planners exits" 1 "$T_RC"
  t_err_has "claude and codex, codex missing" "(command -v did not find it on PATH): planner_codex drives codex. "
  if grep -q 'planner_claude drives' "$T_TMP/planners.err"; then _t_got=named; else _t_got=not-named; fi
  t_same "claude and codex, codex missing: planner_claude in the refusal" not-named "$_t_got"

  # The same with codex installed: nothing to refuse.
  t_planners "claude and codex, both installed" "$T_SHIPPED" "claude codex" "$T_TMP/clibin:$T_TMP/codexbin:$T_NOCLI"
  t_same "claude and codex, both installed: council_check_planners exits" 0 "$T_RC"
  t_same "claude and codex, both installed: council_check_planners stderr" "" "$(cat "$T_TMP/planners.err")"

  # A project config that sets nothing and sources the plugin's: the
  # definitions that run are the plugin's, read through that branch.
  F=$(t_conf sources-plugin <<'CONF'
. "$COUNCIL_PLUGIN_ROOT/config/council.conf"
CONF
)
  t_planners "a config that sources the plugin's, codex missing" "$F" "claude codex" "$T_TMP/clibin:$T_NOCLI"
  t_same "a config that sources the plugin's, codex missing: council_check_planners exits" 1 "$T_RC"
  t_err_has "a config that sources the plugin's, codex missing" ": planner_codex drives codex. "

  # A planner for another CLI is noted, not refused: the plugin documents
  # adding one. Its CLI is missing here too, and that is not checked.
  F=$(t_conf other-cli <<'CONF'
planner_claude() {
  claude -p > "$1"
}
planner_gemini() {
  gemini --model m > "$1"
}
CONF
)
  t_planners "a planner for another CLI" "$F" "claude gemini" "$T_TMP/clibin:$T_NOCLI"
  t_same "a planner for another CLI: council_check_planners exits" 0 "$T_RC"
  t_err_has "a planner for another CLI" "plan-council: note: the definition of planner_gemini names none of the CLIs checked here (claude codex)"

  # What counts as naming a CLI. A whole-line comment does not, nor a
  # longer name, a variable, a model ID or a path; a planner written so
  # names none, and is noted.
  F=$(t_conf not-named <<'CONF'
planner_claude() {
  claude -p > "$1"
}
planner_mine() {
  # codex and claude are both mentioned on this comment line
  run_seat "$COUNCIL_MODEL_CLAUDE" claude-opus-5-5 planner_claude claude_alt $codex /opt/codex codex.cmd > "$1"
}
CONF
)
  t_planners "a planner that names no CLI as a word" "$F" "claude mine" "$T_TMP/clibin:$T_NOCLI"
  t_same "a planner that names no CLI as a word: council_check_planners exits" 0 "$T_RC"
  t_err_has "a planner that names no CLI as a word" "plan-council: note: the definition of planner_mine names none of the CLIs checked here"

  # And the words that do count, read from the shipped definitions.
  COUNCIL_CONFIG_USED=$T_SHIPPED
  COUNCIL_PLUGIN_ROOT=$T_PLUGIN
  for _t_fn in planner_claude planner_claude_alt planner_fable arbiter; do
    _t_got=$(council_seat_clis "$(council_body_in_effect "$_t_fn")")
    t_same "config/council.conf: council_seat_clis of $_t_fn" claude "$_t_got"
  done
  _t_got=$(council_seat_clis "$(council_body_in_effect planner_codex)")
  t_same "config/council.conf: council_seat_clis of planner_codex" codex "$_t_got"

  # The doctor runs this check with its stderr captured, and its FAIL line
  # carries the reason instead of sending the reader to council-plan.sh.
  PATH="$T_TMP/bin:$T_NOCLI" TMPDIR="$T_TMP/tmp" COUNCIL_CONFIG="$T_SHIPPED" COUNCIL_PLANNERS="claude codex" \
    sh "$T_PLUGIN/scripts/council-doctor.sh" --root "$T_TMP/root" --no-model-check \
    > "$T_TMP/doctor-nocodex.out" 2> /dev/null
  _t_got=$(grep -c '^  FAIL  planners (claude codex): a CLI is not installed here (command -v did not find it on PATH): planner_codex drives codex\. ' "$T_TMP/doctor-nocodex.out")
  t_same "codex missing: council-doctor.sh stdout, the FAIL line for the planners" 1 "$_t_got"
  _t_got=$(grep -c '^  ok    planners: ' "$T_TMP/doctor-nocodex.out")
  t_same "codex missing: council-doctor.sh stdout, an ok line for the planners" 0 "$_t_got"
fi

echo
echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
