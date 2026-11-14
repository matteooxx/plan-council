# Shared helpers for the plan-council scripts. POSIX sh. Sourced, never run.
#
# House rules, because each of these has broken a real run:
# - Every path is made absolute BEFORE any cd. A relative path checked in one
#   directory and read in another passes its check and feeds an empty prompt.
# - Child agents are started from the context root, never from elsewhere: an
#   agent's read outside its working directory is refused silently.
# - Prompts reach every CLI on stdin, never as an argument.
# - No backquote characters anywhere in these scripts. Use $( ).

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
  # The environment may set any COUNCIL_* value for a single run, and the config's
  # "${VAR:-default}" form keeps it. The names that arrived that way are ANNOUNCED:
  # blanking them here instead, as an earlier version did, meant an exported value
  # was dropped without a word, and a setting ignored in silence is the failure this
  # whole method exists to prevent. The opposite danger -- a stale export in a shell
  # profile quietly steering a run -- is covered by the same announcement.
  COUNCIL_FROM_ENV=""
  for _v in COUNCIL_PLANNERS COUNCIL_RISK_FLOOR COUNCIL_AGENT_DIRS COUNCIL_MIN_BYTES; do
    eval "_isset=\${$_v+set}"
    [ "${_isset:-}" = set ] && COUNCIL_FROM_ENV="$COUNCIL_FROM_ENV $_v"
  done
  # shellcheck disable=SC1090
  . "$_abs" || council_die "config failed to load: $_abs"
  # A config of the user's own may simply not mention a setting.
  : "${COUNCIL_PLANNERS:=}"
  : "${COUNCIL_RISK_FLOOR:=implementer}"
  : "${COUNCIL_AGENT_DIRS:=}"
  : "${COUNCIL_MIN_BYTES:=400}"
  COUNCIL_CONFIG_USED=$_abs
  [ -n "$COUNCIL_FROM_ENV" ] && council_say "from the environment, not the config:$COUNCIL_FROM_ENV"
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
