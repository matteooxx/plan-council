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
# VAR="${VAR:-default}" so an exported value survives being sourced -- except
# the ones whose EMPTY value means something, which take VAR="${VAR-default}":
# COUNCIL_BUDGET_USD, COUNCIL_MODEL_CODEX, COUNCIL_AGENT_DIRS and COUNCIL_MODE.
COUNCIL_SETTINGS="COUNCIL_PLANNERS COUNCIL_RISK_FLOOR COUNCIL_AGENT_DIRS COUNCIL_MIN_BYTES COUNCIL_PLANNER_EFFORT COUNCIL_ATTACK_EFFORT COUNCIL_ARBITER_EFFORT COUNCIL_ASSIGN_EFFORT COUNCIL_BUDGET_USD COUNCIL_MODEL_CLAUDE COUNCIL_MODEL_CLAUDE_ALT COUNCIL_MODEL_ARBITER COUNCIL_MODEL_CODEX COUNCIL_MODE COUNCIL_MODEL_LADDER COUNCIL_MODEL_LADDER_DATE COUNCIL_STRONGEST_FOR"

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

  # Cleared before the load so a value left by an earlier load cannot satisfy
  # the "mode asked for but never applied" check below, nor make the recheck
  # after the load believe this load dealt the seats, nor give this load a
  # dealt record it did not deal.
  COUNCIL_MODE_APPLIED=""
  COUNCIL_DEALT=""
  _council_shown=""
  _council_except=""
  _council_seats_dealt=""
  _council_deal=""
  _council_fallback_seats=""

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
  # Which seats are still empty here, so about to take the fallback below.
  # Under a mode this is a seat that holds neither a ladder rung nor a hand pin
  # once the config has returned -- whether the deal never reached it or a later
  # line emptied it: the plugin's config skips its own seat defaults once the
  # deal has run, so nothing else has filled it. council_recheck_seats refuses
  # such a seat if it is in play.
  _council_fallback_seats=""
  for _v in COUNCIL_MODEL_CLAUDE COUNCIL_MODEL_CLAUDE_ALT COUNCIL_MODEL_ARBITER; do
    eval "_sv=\${$_v-}"
    [ -n "$_sv" ] || _council_fallback_seats="$_council_fallback_seats $_v"
  done
  # Only so that a sparse config of the user's own cannot trip set -u. These
  # are not a recommendation: /council-setup asks, and council-detect.sh shows
  # what this machine actually has.
  : "${COUNCIL_MODEL_CLAUDE:=claude-opus-5-5}"
  : "${COUNCIL_MODEL_CLAUDE_ALT:=claude-sonnet-5-5}"
  : "${COUNCIL_MODEL_ARBITER:=claude-opus-5-5}"
  : "${COUNCIL_MODEL_CODEX:=}"
  # COUNCIL_MODE uses the colon-less form: an empty value means "no mode", and
  # that has to survive being exported for a single run.
  : "${COUNCIL_MODE=}"
  : "${COUNCIL_MODEL_LADDER:=}"
  : "${COUNCIL_MODEL_LADDER_DATE:=}"
  : "${COUNCIL_STRONGEST_FOR:=}"
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
  # A mode that was asked for and never applied means the config in use never
  # sourced the plugin's own, which is what calls council_apply_mode. Refusing
  # is the only honest answer: otherwise the run would use plugin defaults
  # while the user believes a mode is in effect.
  if [ -n "${COUNCIL_MODE-}" ] && [ -z "${COUNCIL_MODE_APPLIED-}" ]; then
    council_die "COUNCIL_MODE is '$COUNCIL_MODE' but no mode was applied. $_abs must source the plugin's own config, which is what applies a mode: add '. \"\$COUNCIL_PLUGIN_ROOT/config/council.conf\"' to it."
  fi

  # The deal's refusals, re-run on the values that are actually in effect, and
  # the dealt record made to agree with them.
  #
  # A project config is a delta: it sets a few values and then sources the
  # plugin's own config, which is what deals the ladder. So anything it assigns
  # AFTER that source line is assigned after the deal and after every check
  # inside it, and a check that runs only inside the deal can be bypassed by
  # moving a line down. Measured 2026-11-15 on the code this replaces: with the
  # planner list and both Claude model IDs assigned after the source line,
  # COUNCIL_PLANNERS="claude claude_alt" with both IDs 'm1' loaded with three
  # seats on one model and exit 0, and COUNCIL_PLANNERS="claude fable" under a
  # mode loaded without 'fable' ever being named. Both are refused here.
  council_recheck_seats
  council_refresh_dealt
  council_announce_outcome

  [ -n "$_kept" ] && council_say "from the environment, and still in effect after the config:$_kept"
  return 0
}

# council_apply_mode -- called from config/council.conf, near its top.
#
# A mode is one more link in the chain that already exists, not a second chain:
# the mode file's lines use the "${VAR:-default}" form, so anything the
# environment or a project config set earlier still wins, and the plugin's own
# defaults still come last. The order stays environment, project, mode, plugin.
#
# A mode file may set the four per-phase efforts and COUNCIL_STRONGEST_FOR.
# It may never hold a model ID, a planner list or a dollar figure: an ID in a
# shipped file breaks on accounts that lack that model, and no per-run cost has
# ever been measured.
council_apply_mode() {
  [ -n "${COUNCIL_MODE-}" ] || return 0

  case "$COUNCIL_MODE" in
    *[!A-Za-z0-9_-]*)
      council_die "mode name '$COUNCIL_MODE' may use only letters, digits, _ and -" ;;
  esac

  _modedir="${COUNCIL_PLUGIN_ROOT:-}/config/modes"
  _modefile="$_modedir/$COUNCIL_MODE.conf"
  if [ ! -f "$_modefile" ]; then
    _have=""
    for _f in "$_modedir"/*.conf; do
      [ -f "$_f" ] || continue
      _have="$_have $(basename "$_f" .conf)"
    done
    council_die "unknown mode '$COUNCIL_MODE'. The modes that exist are:${_have:- none found in $_modedir}"
  fi

  # shellcheck disable=SC1090
  . "$_modefile" || council_die "mode failed to load: $_modefile"
  COUNCIL_MODE_APPLIED=$COUNCIL_MODE
  council_deal_seats
}

# council_deal_seats -- deals the user's own ladder to the seats.
#
# "Capability" is position in COUNCIL_MODEL_LADDER and nothing else: the exact
# IDs that answered the setup probe, in an order the user confirmed, dated by
# COUNCIL_MODEL_LADDER_DATE. Nothing here compares models; it only counts
# along the user's line. A draw without replacement keeps the planners
# different, which is the whole product of the method, and the second planner
# always picks last.
#
#   COUNCIL_STRONGEST_FOR=planning     first planner, arbiter, second planner
#   COUNCIL_STRONGEST_FOR=arbitration  arbiter, first planner, second planner
#
# A seat already set -- by the environment, a project config or a hand pin --
# keeps its value and takes no rung. That is the only way to accept a ladder
# shorter than the seats in play.
council_deal_seats() {
  [ -n "${COUNCIL_STRONGEST_FOR-}" ] || return 0

  case "$COUNCIL_STRONGEST_FOR" in
    planning|arbitration) ;;
    *) council_die "COUNCIL_STRONGEST_FOR is '$COUNCIL_STRONGEST_FOR'; it must be 'planning' or 'arbitration' (set by the mode file)" ;;
  esac

  [ -n "${COUNCIL_MODEL_LADDER-}" ] || council_die "mode '$COUNCIL_MODE' deals a model ladder to the seats, but COUNCIL_MODEL_LADDER is empty. Run /council-setup to build one from the models that answer on this machine, or set the model settings by hand and use no mode."

  # Filename expansion off for the whole deal. Every loop below splits a
  # setting into words with the shell, and the shell expands a word holding a
  # glob character against the current directory BEFORE the case that
  # validates it ever sees it. Measured 2026-11-15: ladder 'm1 *' with the
  # current directory inside config/ dealt the filename 'council.conf' as a
  # model ID and exited 0. With -f the entry arrives as the literal '*' and
  # the validation below names it. The deal must not depend on where the run
  # was started from.
  council_noglob_on

  _seen=" "
  for _m in $COUNCIL_MODEL_LADDER; do
    case "$_m" in
      *[!A-Za-z0-9._-]*) council_die "ladder entry '$_m' may use only letters, digits, dot, _ and -" ;;
    esac
    case "$_seen" in
      *" $_m "*) council_die "ladder entry '$_m' is listed twice; a draw without replacement cannot deal the same model to two seats" ;;
    esac
    _seen="$_seen$_m "
  done

  council_seat_scan
  _council_seats_dealt=1

  # Pick order.
  # shellcheck disable=SC2086
  set -- $_claude_seats
  if [ "$COUNCIL_STRONGEST_FOR" = planning ] && [ $# -ge 1 ]; then
    _first=$1
    shift
    _order="$_first COUNCIL_MODEL_ARBITER $*"
  else
    _order="COUNCIL_MODEL_ARBITER$_claude_seats"
  fi

  # What the deal did, seat by seat, for council_refresh_dealt: NAME= for a
  # seat it left alone, NAME=ID for a seat it dealt. NAME is one of the seat
  # names in _order, which this code builds from literals, and ID is a ladder
  # entry validated above, so no word of this list holds a space, a glob
  # character or anything taken from a seat's own value.
  _rungs=$COUNCIL_MODEL_LADDER
  for _seat in $_order; do
    eval "_cur=\${$_seat-}"
    if [ -n "$_cur" ]; then
      _council_deal="$_council_deal $_seat="
      continue
    fi
    # shellcheck disable=SC2086
    set -- $_rungs
    if [ $# -lt 1 ]; then
      council_die "mode '$COUNCIL_MODE' has no model left for $_seat: the ladder is '$COUNCIL_MODEL_LADDER'. Add a model to the ladder, or pin $_seat by hand -- a pinned seat keeps its value and takes no rung."
    fi
    _id=$1
    shift
    _rungs=$*
    eval "$_seat=\$_id"
    _council_deal="$_council_deal $_seat=$_id"
  done

  council_check_seat_models
  council_noglob_off
  return 0
}

# Filename expansion off, and back to whatever it was.
#
# Both the deal and the recheck after the config split settings into words with
# the shell, which is also where the shell expands globs. These are not nested:
# each on is followed by its own off, or by a council_die that leaves the shell
# altogether.
council_noglob_on() {
  case $- in
    *f*) _noglob_was=1 ;;
    *)   _noglob_was=0 ;;
  esac
  set -f
}

council_noglob_off() {
  [ "${_noglob_was:-0}" = 1 ] || set +f
}

# council_seat_scan -- the Claude planner seats, in COUNCIL_PLANNERS order.
#
# codex takes a seat in the council but never a rung on the ladder: its model
# is its own business and the ladder cannot rank it.
#
# Sets _claude_seats, _has_claude and _has_alt. Refuses a planner no mode can
# seat. Needs filename expansion off: see council_noglob_on.
council_seat_scan() {
  _claude_seats=""
  _has_claude=0
  _has_alt=0
  for _p in $COUNCIL_PLANNERS; do
    case "$_p" in
      claude)     _claude_seats="$_claude_seats COUNCIL_MODEL_CLAUDE"; _has_claude=1 ;;
      claude_alt) _claude_seats="$_claude_seats COUNCIL_MODEL_CLAUDE_ALT"; _has_alt=1 ;;
      codex)      ;;
      *) council_die "under a mode, plan-council seats only the planners 'claude', 'claude_alt' and 'codex'; '$_p' is none of them. A planner whose function pins its own model ID, as planner_fable does, could silently take a seat the ladder already dealt. Drop the mode to use it, or rename it to one of the three." ;;
    esac
  done
}

# council_check_seat_models -- refuses two Claude planners on one model ID.
#
# Two planners on one model are two plans that agree at twice the price, so
# this refuses rather than warns -- hand pins included. The arbiter sharing a
# planner's model is only discouraged ("prefer a model that is neither
# planner"), so that loads and is not refused here.
#
# Reads _has_claude, _has_alt and the two Claude model settings, so it judges
# whatever is in effect when it is called: once during the deal, and once more
# after the config has finished, where a late assignment is visible.
council_check_seat_models() {
  if [ "${_has_claude:-0}" -eq 1 ] && [ "${_has_alt:-0}" -eq 1 ]; then
    eval "_a=\${COUNCIL_MODEL_CLAUDE-}"
    eval "_b=\${COUNCIL_MODEL_CLAUDE_ALT-}"
    if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then
      council_die "planners 'claude' and 'claude_alt' would both run '$_a': COUNCIL_MODEL_CLAUDE and COUNCIL_MODEL_CLAUDE_ALT hold the same ID. Disagreement between different models is what this method produces, so two planners on one model is refused: lengthen the ladder, or pin one of them by hand to a different model."
    fi
  fi
  return 0
}

# council_recheck_seats -- the deal's refusals, on the values in effect.
#
# Called from council_load_config once the config has returned. It runs only
# when this load actually dealt the seats: with no mode nothing is dealt, the
# seats are the user's own business, and this must then add no output, no
# refusal and no difference from a run without modes at all.
#
# The marker is set by the deal rather than read back from
# COUNCIL_STRONGEST_FOR, a setting a config may well assign after its source
# line for its own reasons -- clearing it there would have handed back the same
# bypass one line lower. The marker's name is kept out of the COUNCIL_
# namespace for the same reason: a config line that assigned it by accident
# re-opened both refusals. That is all this protects against. A config is
# sourced shell code; one that sets this marker, or redefines this function, on
# purpose gets what it asks for, and nothing in sh can prevent that.
council_recheck_seats() {
  [ "${_council_seats_dealt:-}" = 1 ] || return 0
  council_noglob_on
  council_seat_scan
  council_check_fallback_seats
  council_check_seat_models
  council_noglob_off
  return 0
}

# council_check_fallback_seats -- refuses a seat in play on the fallback.
#
# Under a mode every seat in play takes a rung of the ladder or a hand pin.
# A seat listed in _council_fallback_seats holds neither: it was unset or empty
# once the config had returned, and only the plugin's last-resort default
# filled it. This code sees that state, not how it came about, so the message
# names what is observed and the shapes known to produce it, never a single
# cause. Two such shapes are measured: a COUNCIL_PLANNERS line below the source
# line (the deal never saw the seat), and a line below the source line that
# empties a seat the deal did fill -- under 'standard' with ladder 'm1 m2 m3',
# COUNCIL_MODEL_ARBITER="" there erases the m1 the deal gave it. Measured
# 2026-11-15 on the code before this check: with COUNCIL_PLANNERS="claude
# claude_alt" assigned below the source line, the deal ran on the earlier list,
# never saw claude_alt, and the second planner loaded on claude-sonnet-5-5, a
# model the ladder never named, with exit 0 -- even when the ladder was one
# rung too short and the load had to die.
#
# Only seats in play are judged: the Claude planner seats council_seat_scan
# collected, and the arbiter. With planners 'claude codex' the second Claude
# seat is nobody's, and its value is nobody's business. Reads _claude_seats, so
# it runs after council_seat_scan, with filename expansion off.
#
# A limit, measured 2026-11-15 and not fixable without reading the config's
# text: a line below the source line that writes the fallback's OWN string --
# a pasted COUNCIL_MODEL_CLAUDE_ALT="${COUNCIL_MODEL_CLAUDE_ALT:-claude-sonnet-5-5}",
# or a wholesale copy of an older council.conf -- is indistinguishable, after
# evaluation, from a deliberate hand pin on that model, and it loads. That is
# the price of letting a deliberate late pin work (harness case c4). There is
# no mode documentation yet in README.md, commands/, skills/ or prompts/:
# when that step comes, this limit belongs in the user-facing docs.
council_check_fallback_seats() {
  for _seat in $_claude_seats COUNCIL_MODEL_ARBITER; do
    case " ${_council_fallback_seats-} " in
      *" $_seat "*)
        eval "_sv=\${$_seat-}"
        council_die "$_seat is in play under mode '$COUNCIL_MODE', but after the config it holds neither a ladder rung nor a hand pin: it is unset or empty, so it would run on the plugin's fallback '$_sv'. Under a mode every seat in play takes either a ladder rung or a hand pin. Two shapes are known to leave a seat like this, both on lines below the one that sources the plugin's config in $COUNCIL_CONFIG_USED: a COUNCIL_PLANNERS line there, so that the deal ran on the earlier planner list and never saw this seat; or a line there that empties or unsets $_seat after the deal. Move such a COUNCIL_PLANNERS line above the source line, remove such an emptying line, or pin $_seat by hand." ;;
    esac
  done
  return 0
}

# council_refresh_dealt -- writes COUNCIL_DEALT from what is in effect.
#
# The deal runs while the config is still being sourced, so a line after the
# source line can change a seat afterwards. Measured 2026-11-15: a record
# written during the deal said COUNCIL_MODEL_CLAUDE=m2 while a later line had
# set it to m1. So the record is written here, once the config has returned,
# from the deal's own seat list (_council_deal) and the current value of each
# seat.
#
# It is never parsed back out of COUNCIL_DEALT. An earlier version split that
# record on whitespace and evaluated the text before each '='; a seat value is
# not validated, so a value holding a space produced a fragment that reached
# eval: a trailing space in an exported model ID made council_load_config fail
# (rc=127 under sh, rc=2 under dash, measured 2026-11-15).
#
# The invariant, once council_load_config has returned successfully: every
# NAME=value in COUNCIL_DEALT equals the current value of $NAME. A value
# holding whitespace is written in single quotes, with a quote inside it as
# '\'', so that where one entry ends stays visible. Each entry ends in what the
# deal did with that seat:
#   (kept)        the seat already had a value, and the deal left it alone;
#   no tag        the deal dealt this rung, and it is still in effect;
#   (overridden)  the deal dealt a rung, and a later line set this value.
#
# The same pass also builds the two texts council_announce_outcome prints, so
# the announcement and the record come from one computation of the tag:
#   _council_shown   every seat with the value in effect, no tags;
#   _council_except  the seats not dealt from the ladder, each with its value
#                    and which of the two cases it is, one per entry.
# Nothing else reads the record, so no message promises that it is reported.
council_refresh_dealt() {
  [ -n "${_council_deal:-}" ] || return 0
  # No word of _council_deal can hold a glob character (see the deal), and a
  # seat value is never split here, so this needs no council_noglob_on.
  _rec=""
  _council_shown=""
  _council_except=""
  for _e in $_council_deal; do
    _n=${_e%%=*}
    _d=${_e#*=}
    eval "_ev=\${$_n-}"
    if [ -z "$_d" ]; then
      _tag='(kept)'
    elif [ "$_ev" = "$_d" ]; then
      _tag=''
    else
      _tag='(overridden)'
    fi
    council_record_value "$_ev"
    _rec="$_rec $_n=$_rv$_tag"
    _council_shown="$_council_shown $_n=$_rv"
    case "$_tag" in
      '(kept)')       _council_except="$_council_except $_n=$_rv (the seat had a value when the deal ran, so it took no rung);" ;;
      '(overridden)') _council_except="$_council_except $_n=$_rv (dealt from the ladder, then changed by a later line);" ;;
    esac
  done
  COUNCIL_DEALT=$_rec
  return 0
}

# council_announce_outcome -- tells the user what the load did, on stderr.
#
# Display only: it reads, it never assigns a setting and it never refuses. It
# prints from what council_refresh_dealt built and compares nothing itself. With
# no mode and no ladder it prints nothing at all.
#
# The ladder date is shown because the ladder is the user's own order and is
# only as current as that date; nothing here checks the models still answer.
council_announce_outcome() {
  if [ -n "${COUNCIL_DEALT:-}" ]; then
    if [ -n "${COUNCIL_MODEL_LADDER_DATE:-}" ]; then
      _dt="ladder dated $COUNCIL_MODEL_LADDER_DATE; your own order, as old as its date"
    else
      _dt="ladder with no date set, so its age is unknown; your own order"
    fi
    # The ? below is reachable only by a config that blanks COUNCIL_MODE_APPLIED
    # itself; that is tampering with a COUNCIL_ name and is not defended against.
    council_say "mode ${COUNCIL_MODE_APPLIED:-?} seats:$_council_shown ($_dt)"
    if [ -n "${_council_except:-}" ]; then
      council_say "not dealt from the ladder:${_council_except%;}"
    fi
  elif [ -n "${COUNCIL_MODEL_LADDER:-}" ]; then
    council_say "COUNCIL_MODEL_LADDER is set but no seat was dealt from it, so it was not used; a ladder is dealt only by a mode that sets COUNCIL_STRONGEST_FOR. The ladder changed no model setting."
  fi
  return 0
}

# council_record_value VALUE -- sets _rv to VALUE as one entry of the record:
# unchanged, or in single quotes when it holds whitespace.
council_record_value() {
  _rv=$1
  _ws=$(printf ' \t\n.')
  _ws=${_ws%.}
  case "$_rv" in
    *["$_ws"]*) ;;
    *) return 0 ;;
  esac
  _rv="'"
  _rest=$1
  while :; do
    case "$_rest" in
      *"'"*)
        _rv="$_rv${_rest%%"'"*}'\\''"
        _rest=${_rest#*"'"} ;;
      *)
        _rv="$_rv$_rest'"
        break ;;
    esac
  done
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
