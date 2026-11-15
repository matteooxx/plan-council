# Shared helpers for the plan-council scripts. POSIX sh. Sourced, never run.
#
# House rules, because each of these has broken a real run:
# - Every path is made absolute BEFORE any cd. A relative path checked in one
#   directory and read in another passes its check and feeds an empty prompt.
# - Child agents are started from the context root. That is where they start,
#   and what they reach by a relative path; it is NOT a boundary. Measured
#   2026-11-14: a read-only child agent read an absolute path outside the root
#   with no refusal at all. Anything that must stay unreadable is denied by an
#   explicit rule -- see council_deny_rule.
# - Prompts reach every CLI on stdin, never as an argument. --disallowedTools
#   is variadic: a prompt written after it is swallowed as more tool names.
# - No backquote characters anywhere in these scripts. Use $( ).

# Every setting the scripts read. Each must be written in the config as
# VAR="${VAR:-default}" so an exported value survives being sourced.
COUNCIL_SETTINGS="COUNCIL_PLANNERS COUNCIL_RISK_FLOOR COUNCIL_AGENT_DIRS COUNCIL_MIN_BYTES COUNCIL_PLANNER_EFFORT COUNCIL_ATTACK_EFFORT COUNCIL_ARBITER_EFFORT COUNCIL_ASSIGN_EFFORT COUNCIL_BUDGET_USD COUNCIL_MODEL_CLAUDE COUNCIL_MODEL_CLAUDE_ALT COUNCIL_MODEL_ARBITER COUNCIL_MODEL_CODEX"

council_say() { printf 'plan-council: %s\n' "$*" >&2; }
council_die() { printf 'plan-council: error: %s\n' "$*" >&2; exit 1; }

# Absolute, symlink-resolved path of an existing directory.
council_absdir() {
  [ -d "$1" ] || return 1
  ( cd "$1" 2>/dev/null && pwd -P )
}

# Absolute path of an existing regular file.
council_absfile() {
  [ -f "$1" ] || return 1
  _cd_dir=$(council_absdir "$(dirname "$1")") || return 1
  printf '%s/%s\n' "$_cd_dir" "$(basename "$1")"
}

# Size of a file in bytes (0 when missing).
council_size() {
  if [ -f "$1" ]; then wc -c < "$1" | tr -d ' \t\r\n'; else printf '0'; fi
}

# The path form the CLI's permission rules accept. Measured 2026-11-14 on
# Windows: a deny rule carrying an MSYS path (/c/Users/...) matches nothing and
# blocks nothing -- it fails open, in silence, which is the worst way for a
# guard to fail. cygpath -m produces the form that is actually honoured.
council_cli_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# The rule that keeps a child agent out of a directory. The arbiter is handed
# every plan by letter in its own prompt; nothing it needs is in the run
# directory, and the attribution is. One Read() rule covers both Read and Grep
# (measured 2026-11-14).
council_deny_rule() {
  printf 'Read(%s/**)' "$(council_cli_path "$1")"
}

# Denying only the current run is not enough for the review phases. An arbiter
# refused the current directory then read an EARLIER run's council.txt and
# reported its letter-to-planner mapping -- in a project that always runs the
# same planners in the same order, that mapping is this run's too. So the
# review and assignment phases deny the whole council tree as well. The
# planning phase does not: reading prior runs as working material is a
# documented feature, and the current run holds nothing yet.
# It always names the council tree, whether or not that directory exists. An
# earlier version fell back to denying the CONTEXT ROOT when there was no
# .council, to keep the value non-empty -- which blinded the arbiter to the
# whole repository. Measured 2026-11-14 on the first council run with real
# models: Read of scripts/lib.sh, Grep on scripts/, Glob on the root and even
# "pwd; ls" were all refused, so the arbiter could verify nothing and said so.
# A rule naming a directory that does not exist matches nothing, which is
# exactly what is wanted when there are no earlier runs to hide.
council_deny_all_runs() {
  council_deny_rule "$1/.council"
}

# council_assert_not_root ROOT RULE1 RULE2
# Refuses to start when a deny rule would cover the context root itself.
# Denying the root blinds every child to the code, and checking claims against
# the code is the arbiter's entire job -- so getting this wrong makes a council
# worthless while every exit code stays 0 and the report still looks like a
# report. That happened once; it does not get to happen quietly again.
council_assert_not_root() {
  _rootrule=$(council_deny_rule "$1")
  if [ "${2:-}" = "$_rootrule" ] || [ "${3:-}" = "$_rootrule" ]; then
    council_die "a deny rule would cover the context root itself ($_rootrule). Every child would be blind to the code, and the arbiter could verify nothing. This is a bug in plan-council, not in your setup: please report it."
  fi
  return 0
}

# council_load_config CONTEXT_ROOT PLUGIN_ROOT
council_load_config() {
  if [ -n "${COUNCIL_CONFIG:-}" ]; then
    _cfg=$COUNCIL_CONFIG
  elif [ -f "$1/.claude/plan-council.conf" ]; then
    _cfg="$1/.claude/plan-council.conf"
  else
    _cfg="$2/config/council.conf"
  fi
  _abs=$(council_absfile "$_cfg") || council_die "config not found: $_cfg"

  # A project config is meant to be a small delta, not a copy. It sets the few
  # values it cares about and then sources this, so it inherits every planner
  # function and every later setting:
  #     . "$COUNCIL_PLUGIN_ROOT/config/council.conf"
  # Copying the whole file is how a plain assignment spreads, and a plain
  # assignment is what silently overrode an exported value.
  COUNCIL_PLUGIN_ROOT=$2
  export COUNCIL_PLUGIN_ROOT

  # Record the exported values BEFORE sourcing, and compare AFTER. An earlier
  # version noted which names arrived from the environment and never looked
  # again: when a config used a plain assignment, the run announced that the
  # environment had won while the config had quietly overridden it. An
  # announcement of an intention rather than of an outcome is the silently
  # ignored setting this method exists to prevent, wearing a line that denies
  # it. Blanking the names before sourcing, which an even earlier version did,
  # is not the answer either: that dropped an exported value without a word.
  _env_names=""
  for _v in $COUNCIL_SETTINGS; do
    eval "_isset=\${$_v+set}"
    if [ "${_isset:-}" = set ]; then
      eval "_council_before_$_v=\$$_v"
      _env_names="$_env_names $_v"
    fi
  done

  # shellcheck disable=SC1090
  . "$_abs" || council_die "config failed to load: $_abs"

  # A config of the user's own may simply not mention a setting.
  : "${COUNCIL_PLANNERS:=}"
  : "${COUNCIL_RISK_FLOOR:=implementer}"
  : "${COUNCIL_AGENT_DIRS:=}"
  : "${COUNCIL_MIN_BYTES:=400}"
  : "${COUNCIL_PLANNER_EFFORT:=high}"
  : "${COUNCIL_ATTACK_EFFORT:=high}"
  : "${COUNCIL_ARBITER_EFFORT:=high}"
  : "${COUNCIL_ASSIGN_EFFORT:=medium}"
  : "${COUNCIL_BUDGET_USD:=}"
  # Only so that a sparse config of the user's own cannot trip set -u. These
  # are not a recommendation: /council-setup asks, and council-detect.sh shows
  # what this machine actually has.
  : "${COUNCIL_MODEL_CLAUDE:=claude-opus-5-5}"
  : "${COUNCIL_MODEL_CLAUDE_ALT:=claude-sonnet-5-5}"
  : "${COUNCIL_MODEL_ARBITER:=claude-opus-5-5}"
  : "${COUNCIL_MODEL_CODEX:=}"
  : "${COUNCIL_DENY:=}"
  : "${COUNCIL_DENY2:=$COUNCIL_DENY}"
  COUNCIL_CONFIG_USED=$_abs

  _kept=""
  for _v in $_env_names; do
    eval "_after=\$$_v"
    eval "_before=\$_council_before_$_v"
    if [ "$_after" = "$_before" ]; then
      _kept="$_kept $_v"
    else
      # The advice has to match the case. An exported EMPTY value survives only
      # the colon-less form, so telling someone to write "${VAR:-default}" when
      # they exported an empty value is advice that cannot work -- and the line
      # is usually already written that way, which is why the empty value was
      # lost. Measured 2026-11-14 while trying to remove a budget cap.
      if [ -z "$_before" ]; then
        _form="\${$_v-<default>}"
        _why=" An exported EMPTY value survives only the colon-less form: with \${$_v:-<default>} an empty value counts as unset and the default comes back."
      else
        _form="\${$_v:-<default>}"
        _why=""
      fi
      council_die "$_abs overrode $_v. The environment set it to '$_before'; after the config it is '$_after'. Write that line as $_v=\"$_form\" so an exported value survives, or unset $_v before this run.$_why A setting ignored in silence is the failure this method exists to prevent."
    fi
  done
  [ -n "$_kept" ] && council_say "from the environment, and still in effect after the config:$_kept"
  return 0
}

# Fails unless every configured planner has a function, the names are plain,
# there are no duplicates, and there are at least two.
council_check_planners() {
  _n=0
  _seen=" "
  for _p in $COUNCIL_PLANNERS; do
    case "$_p" in
      *[!A-Za-z0-9_]*) council_die "planner name '$_p' may use only letters, digits and _" ;;
    esac
    case "$_seen" in
      *" $_p "*) council_die "planner '$_p' is listed twice" ;;
    esac
    _seen="$_seen$_p "
    type "planner_$_p" >/dev/null 2>&1 || council_die "planner '$_p' has no function planner_$_p in $COUNCIL_CONFIG_USED"
    _n=$((_n + 1))
  done
  [ "$_n" -ge 2 ] || council_die "at least two planners are needed (COUNCIL_PLANNERS='$COUNCIL_PLANNERS')"
  [ "$_n" -le 8 ] || council_die "at most eight planners"
}

# Checks which configured functions honour the deny rule.
#
# The rule is a Claude Code permission rule, so it reaches a function that runs
# "claude" and nothing else. A function driving another CLI -- codex today --
# gets no such rule: its read access is whatever that tool grants, so with it
# as a planner the attack phase's blindness rests on the prompt, not on the
# code. That is a real gap and it is named rather than hidden.
#
# Sets COUNCIL_DENY_UNCOVERED to the functions the rule cannot reach.
# Returns non-zero only when a claude-driven function drops the rule, which is
# a straightforward mistake in the config.
#
# The body is read from the config FILES, not from the shell. An earlier
# version asked the shell with "type", which prints the body under bash and
# only "is a shell function" under dash -- so it reported a false FAIL on a
# correct config, under the very shell portability is claimed for. A check
# that cries wolf is as bad as one that stays silent.
council_function_body() {
  awk -v fn="$1" '
    index($0, fn "()") == 1 { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$2" 2>/dev/null
}

# Like council_check_deny_used, but refuses to start the run.
#
# Used in the planning phase as well as the review phases. Nothing is exposed
# while the planners write -- the run directory is still empty -- but the same
# functions attack later, when it is, so a config that cannot be blind is
# better stopped before the plans are paid for than after. Pointed out by the
# arbiter of a real council run: every call site ended in "|| true", so the
# warning never stopped anything, and a planner missing the rule produced a
# line of text and a full-price council whose blindness rested on nothing.
council_require_deny_used() {
  council_check_deny_used "$1" && return 0
  council_die "that function can read the run directory, and with it which planner wrote which plan. Add \"\$COUNCIL_DENY\" and \"\$COUNCIL_DENY2\" to its --disallowedTools, as config/council.conf does. This was a warning that let the run continue; it stops the run now, because a council whose arbiter can look up the attribution is not worth paying for."
}

council_check_deny_used() {
  _missing=""
  _unknown=""
  COUNCIL_DENY_UNCOVERED=""
  # The function may be defined in the config in use or in the plugin's own,
  # which a project config is meant to source.
  _files=$COUNCIL_CONFIG_USED
  _plugin_cfg="${COUNCIL_PLUGIN_ROOT:-}/config/council.conf"
  if [ -f "$_plugin_cfg" ] && [ "$_plugin_cfg" != "$COUNCIL_CONFIG_USED" ]; then
    _files="$_files $_plugin_cfg"
  fi
  for _fn in $1; do
    type "$_fn" >/dev/null 2>&1 || continue
    _body=""
    for _f in $_files; do
      _body=$(council_function_body "$_fn" "$_f")
      [ -n "$_body" ] && break
    done
    if [ -z "$_body" ]; then
      _unknown="$_unknown $_fn"
      continue
    fi
    case "$_body" in
      *claude*)
        case "$_body" in
          *COUNCIL_DENY*) ;;
          *) _missing="$_missing $_fn" ;;
        esac
        ;;
      *) COUNCIL_DENY_UNCOVERED="$COUNCIL_DENY_UNCOVERED $_fn" ;;
    esac
  done
  if [ -n "$_unknown" ]; then
    council_say "note: could not find the definition of$_unknown in $COUNCIL_CONFIG_USED, so the deny rule was not checked for it. Unknown is not the same as fine."
  fi
  if [ -n "$_missing" ]; then
    council_say "WARNING: these claude functions do not pass \$COUNCIL_DENY to their CLI, so they can read the run directory and learn which planner wrote which plan:$_missing"
    return 1
  fi
  return 0
}

# The effort level for the phase now running. One planner function serves both
# the planning and the attack phase, so the depth of reasoning cannot live in
# the function: it is chosen per phase and read here.
council_effort() {
  case "${COUNCIL_PHASE:-plan}" in
    plan)      printf '%s' "${COUNCIL_PLANNER_EFFORT:-high}" ;;
    attack)    printf '%s' "${COUNCIL_ATTACK_EFFORT:-high}" ;;
    arbitrate) printf '%s' "${COUNCIL_ARBITER_EFFORT:-high}" ;;
    assign)    printf '%s' "${COUNCIL_ASSIGN_EFFORT:-medium}" ;;
    *)         printf 'high' ;;
  esac
}

# Expands to --max-budget-usd <amount>, or to nothing when no cap is set.
# The flag only works with --print, which every planner here uses.
council_budget_flags() {
  if [ -n "${COUNCIL_BUDGET_USD:-}" ]; then
    printf -- '--max-budget-usd %s' "$COUNCIL_BUDGET_USD"
  fi
}

# The Nth letter, 1-based.
council_letter() {
  printf 'ABCDEFGH' | cut -c"$1"
}

# A fresh staging directory that is NOT inside the context root, so that a
# planner cannot read a rival's answer while both are still running.
council_stage() {
  _st=$(mktemp -d 2>/dev/null || mktemp -d -t plancouncil) || council_die "mktemp failed"
  _st=$(council_absdir "$_st") || council_die "staging directory vanished"
  case "$_st/" in
    "$1"/*) council_die "the temp directory $_st is inside the context root; set TMPDIR elsewhere" ;;
  esac
  printf '%s\n' "$_st"
}

# Keep council runs out of version control without touching the project's
# own .gitignore.
council_ignore_dir() {
  mkdir -p "$1" || council_die "cannot create $1"
  [ -f "$1/.gitignore" ] || printf '*\n' > "$1/.gitignore"
}

# An answer is real when it exists and is not trivially short. Exit code 0
# with an empty answer is the most common silent failure.
council_answer_ok() {
  [ "$(council_size "$1")" -ge "${COUNCIL_MIN_BYTES:-400}" ]
}

# Last non-empty line of a file, stripped of Markdown decoration, upper-cased.
council_last_word() {
  tr -d '\r' < "$1" | sed '/^[[:space:]]*$/d' | tail -n 1 \
    | tr -d '*#_>\140 \t' | tr '[:lower:]' '[:upper:]'
}

# Read a key=value line from a run's manifest.
council_manifest_get() {
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# Run one function per job in parallel, from the context root, feeding each
# its own prompt on stdin. Jobs are "label:function" words; prompts are
# $STAGE/prompt-<label>.md and answers land in $STAGE/answer-<label>.md.
# Labels are letters, never planner names: the stage files and the published
# logs carry the label, so no log can attribute a plan to a model.
# Returns non-zero if any job failed or produced no real answer.
council_run_parallel() {
  _root=$1; _stage=$2; shift 2
  _jobs=""
  for _job in "$@"; do
    _label=${_job%%:*}
    _fn=${_job#*:}
    (
      cd "$_root" || exit 97
      "$_fn" "$_stage/answer-$_label.md"
    ) < "$_stage/prompt-$_label.md" > "$_stage/stdout-$_label.log" 2> "$_stage/stderr-$_label.log" &
    _jobs="$_jobs $_label:$!"
    council_say "started $_label ($_fn, pid $!)"
  done
  _failed=0
  for _job in $_jobs; do
    _label=${_job%%:*}
    _pid=${_job#*:}
    wait "$_pid"
    _st=$?
    if [ "$_st" -ne 0 ]; then
      council_say "$_label FAILED with exit code $_st (see stderr-$_label.log)"
      _failed=1
    elif ! council_answer_ok "$_stage/answer-$_label.md"; then
      council_say "$_label exited 0 but its answer is empty or under ${COUNCIL_MIN_BYTES} bytes: treated as a failure"
      _failed=1
    else
      council_say "$_label done ($(council_size "$_stage/answer-$_label.md") bytes)"
    fi
  done
  return "$_failed"
}

# Copy the staging logs into a run directory.
council_keep_logs() {
  mkdir -p "$2/logs"
  for _f in "$1"/*.log; do
    [ -f "$_f" ] && cp "$_f" "$2/logs/$3$(basename "$_f")"
  done
  return 0
}
