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
# Not covered, and declared rather than closed: an earlier run that
# council-plan.sh --out placed outside ROOT/.council. This rule names only
# ROOT/.council, and a read inside the context root is allowed, so a claude
# seat can read the council.txt of such a run inside the root, which gives
# away which planner wrote which plan (council-review.sh says so above
# COUNCIL_DENY2). The attribution of those runs is not protected.
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
# the price of letting a deliberate late pin work. The README states this
# limit under Limitations.
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

# The CLIs a seat's definition is read for before anything is paid
# (council_check_clis below), and the tools council-doctor.sh reports under
# Tools. A list, not a claim that no other CLI is used: a planner may drive
# any CLI (the end of the planners in config/council.conf shows how), and one
# whose definition names none of these is noted, not refused.
_COUNCIL_KNOWN_CLIS="claude codex"

# council_body_in_effect FN -- the text of the definition of FN that runs
# after the config in use is sourced, or nothing when that cannot be told or
# read. It resolves the definition as council_check_deny_used does, with the
# same two readers, council_definition_scan and council_function_body, and
# changes neither; a body the scan saw close on another line than the reader
# stopped at is unread here too. Call it in a command substitution: its
# variables are not kept apart from the caller's otherwise.
council_body_in_effect() {
  _bie_plugin="${COUNCIL_PLUGIN_ROOT:-}/config/council.conf"
  if [ ! -f "$_bie_plugin" ] || [ "$_bie_plugin" = "$COUNCIL_CONFIG_USED" ]; then
    _bie_plugin=""
  fi
  _bie_pbody=""
  [ -n "$_bie_plugin" ] && _bie_pbody=$(council_function_body "$1" "$_bie_plugin")
  _bie_has=0
  [ -n "$_bie_pbody" ] && _bie_has=1
  _bie_scan=$(council_definition_scan "$1" "$COUNCIL_CONFIG_USED" "$_bie_has")
  case "$_bie_scan" in
    "def "*)
      _bie_a=${_bie_scan#def }
      _bie_z=${_bie_a#* }
      _bie_a=${_bie_a%% *}
      _bie_body=$(council_function_body "$1" "$COUNCIL_CONFIG_USED" "$_bie_a")
      [ -n "$_bie_body" ] || return 0
      [ "$(printf '%s\n' "$_bie_body" | wc -l | tr -d ' ')" -eq $((_bie_z - _bie_a + 1)) ] || return 0
      printf '%s\n' "$_bie_body"
      ;;
    "plugin "*)
      [ -z "$_bie_pbody" ] || printf '%s\n' "$_bie_pbody"
      ;;
  esac
  return 0
}

# council_seat_clis BODY -- the CLIs of _COUNCIL_KNOWN_CLIS that BODY names,
# one per line. A CLI is named when its name stands as a word: not part of a
# longer name (planner_claude, claude_alt, claude-fable-5-2, codex.cmd), not
# after a "$", "/" or "." (a variable, a path), and not on a whole-line
# comment. It is a reading of the text, not of the command the shell runs: a
# name inside a quoted string or a comment after code counts, and a CLI
# reached through a helper function or by an absolute path does not.
council_seat_clis() {
  _csc_code=$(printf '%s\n' "$1" | sed '/^[[:space:]]*#/d')
  for _csc_c in $_COUNCIL_KNOWN_CLIS; do
    if printf '%s\n' "$_csc_code" | grep -Eq '(^|[^A-Za-z0-9_./$-])'"$_csc_c"'([^A-Za-z0-9_./-]|$)'; then
      printf '%s\n' "$_csc_c"
    fi
  done
  return 0
}

# council_check_clis FNS ADVICE -- stops the run, before anything is paid,
# when a function in FNS names a known CLI (council_seat_clis) that command -v
# does not find on the PATH the seats will run with: that seat would fail when
# called, and the seats called before it could already have been paid for.
# ADVICE is the caller's sentence on what to do. The CLI is read from the
# function's body, never from its name: planner_claude_alt drives claude, and
# there is no claude_alt to look for. A function whose body names none of the
# known CLIs
# is noted and not refused, since the plugin documents adding a planner for
# another CLI; one whose definition could not be told or read is noted too,
# and the text check (council_require_deny_used) refuses it later, still
# before anything is paid. It sets no variable another check reads: neither
# COUNCIL_CHECK_CLAUDE nor COUNCIL_DENY_UNCOVERED is touched, so a call
# cannot change which seats a seat check probes.
council_check_clis() {
  _ccl_missing=""
  _ccl_none=""
  _ccl_unread=""
  for _ccl_fn in $1; do
    type "$_ccl_fn" >/dev/null 2>&1 || continue
    _ccl_body=$(council_body_in_effect "$_ccl_fn")
    if [ -z "$_ccl_body" ]; then
      _ccl_unread="$_ccl_unread $_ccl_fn"
      continue
    fi
    _ccl_clis=$(council_seat_clis "$_ccl_body")
    if [ -z "$_ccl_clis" ]; then
      _ccl_none="$_ccl_none $_ccl_fn"
      continue
    fi
    for _ccl_c in $_ccl_clis; do
      command -v "$_ccl_c" >/dev/null 2>&1 || _ccl_missing="$_ccl_missing $_ccl_fn drives $_ccl_c;"
    done
  done
  if [ -n "$_ccl_unread" ]; then
    council_say "note: could not tell which definition runs, or could not read it, for$_ccl_unread, so whether the CLI it drives is installed was not checked."
  fi
  if [ -n "$_ccl_none" ]; then
    council_say "note: the definition of$_ccl_none names none of the CLIs checked here ($_COUNCIL_KNOWN_CLIS), so whether the CLI it drives is installed was not checked. Not checked is not the same as installed: if it is missing, the run finds out when that seat is called."
  fi
  if [ -n "$_ccl_missing" ]; then
    council_die "a CLI is not installed here (command -v did not find it on PATH):${_ccl_missing%;}. Each such seat would fail when called, and seats called before it, a seat check among them, could already have been paid for. $2 Nothing has been run."
  fi
  return 0
}

# Fails unless every configured planner has a function, the names are plain,
# there are no duplicates, there are at least two, and the CLI each one's
# definition names is installed (council_check_clis above). Until 2026-11-23
# it checked that the function existed and nothing else, so a planner whose
# CLI was missing was found only when it ran: with codex a planner and not
# installed, after the claude planner's seat check and its planning had been
# paid for (shown with stand-ins in scripts/tests/permission-denials.sh). It
# sets no variable the text check or the seat check reads.
council_check_planners() {
  _n=0
  _seen=" "
  _fns=""
  for _p in $COUNCIL_PLANNERS; do
    case "$_p" in
      *[!A-Za-z0-9_]*) council_die "planner name '$_p' may use only letters, digits and _" ;;
    esac
    case "$_seen" in
      *" $_p "*) council_die "planner '$_p' is listed twice" ;;
    esac
    _seen="$_seen$_p "
    type "planner_$_p" >/dev/null 2>&1 || council_die "planner '$_p' has no function planner_$_p in $COUNCIL_CONFIG_USED"
    _fns="$_fns planner_$_p"
    _n=$((_n + 1))
  done
  [ "$_n" -ge 2 ] || council_die "at least two planners are needed (COUNCIL_PLANNERS='$COUNCIL_PLANNERS')"
  [ "$_n" -le 8 ] || council_die "at most eight planners"
  council_check_clis "$_fns" "Install it or put it on PATH, or take that planner out of COUNCIL_PLANNERS."
}

# Checks the configured functions against what every seat must carry -- the
# deny rule, $(council_seat_flags) unquoted, and Bash in --disallowedTools --
# reading the definition the shell keeps, which depends on the order of the
# lines in the config (council_definition_scan).
#
# The rule is a Claude Code permission rule, so it reaches a function that runs
# "claude" and nothing else. A function driving another CLI -- codex today --
# gets no such rule: its read access is whatever that tool grants, so with it
# as a planner nothing the plugin enforces keeps it out of the run directory
# during the attack phase, and no prompt asks it to stay out. That is a real
# gap and it is named rather than hidden.
#
# A second gap follows from the same test. A body is judged only when the
# word "claude" is in it, so a seat that delegates to a helper which runs
# claude -- arbiter() { run_seat opus "$@"; } -- lands in
# COUNCIL_DENY_UNCOVERED, sets no return code, and is checked for none of the
# three requirements. This function still does exactly that, and its return
# code is unchanged, because planning and the attack phase consume it for
# planner sets that hold Codex. Since 2026-11-21 council_arbiter_unjudged is
# true when arbiter is in that list: review and assignment refuse on it, with
# no option to skip, and the doctor reports a FAIL. The text cannot tell such
# an arbiter from one that drives another CLI, so both are refused. Only that
# one name is: planner_fable redefined that way, or a planner under a name of
# the user's own, is still checked for nothing. A planner whose name holds
# "claude" was never in this gap, since the definition line is part of the
# text read.
#
# Sets COUNCIL_DENY_UNCOVERED to the functions in whose definition it found no
# "claude": the ones the rule cannot reach, and the ones that reach claude
# through another function, which the text cannot tell apart. Sets
# COUNCIL_CHECK_CLAUDE to the ones it judged to drive claude, whose bodies it
# read and found the word in: those are the seats council_seat_check probes.
# Returns non-zero when a claude-driven function drops the rule, does not
# call $(council_seat_flags), or does not name Bash in its --disallowedTools,
# each a straightforward mistake in the config; when it cannot tell which
# definition of a function runs, or cannot read it, since then none of the
# three was checked; and when a definition in the config in use never runs,
# because a later line sources the plugin's config, which defines the
# function again. Sets COUNCIL_CHECK_NODENY, COUNCIL_CHECK_NOFLAGS and
# COUNCIL_CHECK_NOBASH to the functions missing each, so a caller can say
# which requirement failed; COUNCIL_CHECK_UNKNOWN to the functions whose
# definition is unknown, and COUNCIL_CHECK_UNKNOWN_AT to one FN:KIND:LINE
# entry for each, saying why (council_unknown_reasons turns them into
# sentences); and COUNCIL_CHECK_SHADOWED to FN:A:B entries, a definition at
# line A that the source line at line B replaces. All are text checks: they
# read the config, not the process a function starts.
#
# The body is read from the config FILES, not from the shell. An earlier
# version asked the shell with "type", which prints the body under bash and
# only "is a shell function" under dash -- so it reported a false FAIL on a
# correct config, under the very shell portability is claimed for. A check
# that cries wolf is as bad as one that stays silent.
#
# council_function_body FN FILE [LINE] -- the text of FN's definition in FILE.
# Without LINE it starts at the first line where "FN()" begins in column 1;
# with LINE it starts at that line, and prints nothing unless "FN()" begins
# there. It prints nothing when it cannot say where the body ends, and the
# caller reports that as unknown, never as fine.
#
# Where a body ends is a line convention, not brace counting: counting braces
# would need quotes, comments, escapes, expansions, heredocs and case patterns
# recognised, which is a shell parser. The start line is the whole body only
# when it meets every condition of council_r1 below. Otherwise the body runs
# to the first line with "}" in column 1, as every shipped and documented
# function closes; a line that starts another definition in column 1 first
# ("name()" or the bash word "function"), or the end of the file, leaves it
# unread.
#
# Reading too little is not safe by default. A body that loses the word
# "claude" counts as a function the deny rule cannot reach, which sets no
# return code, so a short read of a planner can pass; an arbiter's that loses
# the word is refused by review and assignment (council_arbiter_unjudged). Two
# of the conditions exist for that:
#   arbiter() { # ; }
# ends in "; }" but the "#" comments the brace out and the body continues; and
#   arbiter() { [ -n "$1" ] || { echo usage >&2; return 1; }
# ends in "; }" but closes the inner group, not the body.
#
# Three shapes are read wrongly by this function: a body that fails the
# one-line conditions and is followed by a "}" in column 1 that is not its
# own (read too far); a line that meets them while its final "; }" sits
# inside an open quote (read too little); and a "}" in column 1 inside the
# body, in a heredoc or a multi-line string (read too little). It was kept as
# it is because the canary in council-detect.sh called it and depended on its
# output; since 2026-11-20 the canary reads no config and no longer calls it,
# and it is unchanged. council_check_deny_used does not judge such a text: it compares
# the line where this function stops with the line where
# council_definition_scan, which recognises quotes and heredocs, sees the
# body close, and reports the body unread when they differ.
_COUNCIL_AWK_R1='
  function council_count(s, ch,   n, i) {
    n = 0
    for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
    return n
  }
  # True when the definition line L holds the whole body: exactly one "{"
  # and one "}", no "#", an even count of each quote character, and, ignoring
  # trailing blanks and a CR, an end of ";" or "&", optional blanks, "}".
  function council_r1(l,   t) {
    t = l
    sub(/[ \t\r]+$/, "", t)
    if (council_count(t, "{") != 1 || council_count(t, "}") != 1) return 0
    if (index(t, "#")) return 0
    if (council_count(t, sprintf("%c", 34)) % 2) return 0
    if (council_count(t, sprintf("%c", 39)) % 2) return 0
    return t ~ /[;&][ \t]*}$/
  }
'
council_function_body() {
  awk -v fn="$1" -v start="${3-}" "$_COUNCIL_AWK_R1"'
    !inside {
      if (start != "" && FNR != start + 0) next
      if (index($0, fn "()") != 1) { if (start != "") exit; next }
      inside = 1
      if (council_r1($0)) { print; exit }
      body = $0
      next
    }
    /^}/ { print body; print; exit }
    /^[A-Za-z_][A-Za-z0-9_]*[ \t]*[(][)]/ { exit }
    /^function[ \t]/ { exit }
    { body = body "\n" $0 }
  ' "$2" 2>/dev/null
}

# council_definition_scan FN CONFIG PLUGIN_HAS_FN -- which definition of FN
# the shell keeps after sourcing CONFIG, read from the text without running
# it. Dash cannot be asked: its "type" prints no body (measured 2026-11-19).
# The scan relies on one property of sh instead: in straight-line top-level
# text, the definition executed last is the one that stays.
#
# Every line is first passed through a recogniser of where the shell text
# has quotes, comments, heredocs, parameter expansions, command
# substitutions, backquoted text, backslash escapes and case patterns. It
# returns the line with all of those replaced by neutral characters, column
# for column, so that what is left is the structure: words, separators, and
# a "{" or "}" only where it is a reserved word in command position. It does
# not evaluate, expand or decide what a command does; it says where those
# constructs begin and end. It was written on the owner's decision of
# 2026-11-19, over a council's ruling against a shell parser, and its tests
# in scripts/tests/definitions.sh compare the scan with what bash keeps.
#
# CONFIG is read once, in line order. Three kinds of line are events:
#   DEF     "FN()" starting in column 1;
#   PLUGIN  "." or "source" as the first word of a line outside any function
#           body, whose argument, quotes removed, is
#           $COUNCIL_PLUGIN_ROOT/config/council.conf, the braced form, or the
#           path that names; it counts only when PLUGIN_HAS_FN is 1, that is
#           when the plugin's config yields a body for FN, and is otherwise
#           ignored, since it cannot change FN;
#   OTHER   any other "." or "source" in command position.
# A DEF or PLUGIN that cannot be known to run becomes an OTHER at its line:
# one inside a multi-line if, case, for, while or until block, or a { or (
# group, tracked outside function bodies by the words that open and close
# them in command position; one on a line continued from a line ending in
# "\", "&&", "||" or "|"; and every one after the block tracking has closed
# more blocks than it opened. A "." naming the plugin config anywhere else --
# after "&&", in a one-line if -- is one of these too, and so is one naming
# it in a spelling not listed above, such as ${COUNCIL_PLUGIN_ROOT:?}. A
# definition of FN in a form the reader cannot read -- indented, after
# another command on its line, with a blank before the parentheses, or with
# the bash word "function" -- is an OTHER too, since it may be the one that
# runs. An OTHER inside a function body, and a definition of FN there, count
# at the end of the file: the text cannot say when that function is called.
# A function body is the text from its definition to the bracket that closes
# it, "{" with "}" or "(" with ")", wherever the function is defined and
# whether the bracket is on the definition line or on the next one.
#
# Prints one line. With E the last DEF or counting PLUGIN:
#   "def A Z"          E is a DEF at line A, whose body closes at line Z, or
#                      0 when it does not close: read the body at A;
#   "plugin B A"       E is the PLUGIN at line B: the plugin's body runs; A is
#                      the line of the last definition of FN before B in any
#                      form -- in column 1, inside a block, or in a form the
#                      reader does not read -- or 0;
#   "other L"          a "." or "source", or an eval, at line L after E, or
#                      with no E;
#   "exit L"           a return or exit at line L, at top level, before E:
#                      the config may stop before E;
#   "cond L"           a DEF or PLUGIN at line L that may not run, after E;
#   "form L"           a definition of FN at line L in a form not read;
#   "spelling L"       line L sources the plugin config in a spelling not
#                      taken as the plugin line;
#   "inbody L S"       line L, inside the body that starts at line S, sources
#                      a file or defines FN;
#   "none"             no event at all.
# Every result but the first two is unknown, and the caller refuses it.
#
# What it does not recognise, from what has been found -- a list, not a
# claim that nothing else is missed: text produced at run time, by an
# expansion, an alias or eval, which it does not evaluate (an eval and a
# return or exit are refused as events, not read); a file it does not
# follow; a heredoc on a line whose command continues into a quote on the
# next line; inside a command substitution, case and esac are counted as
# words wherever they appear, and nothing else about the case is read;
# "esac" as the first pattern of a case item followed by a blank;
# bash-only syntax such as [[ ]] and $'...', read as sh; and a "." or
# "source" after the word "command", as in command . FILE, which it does not
# take as a "." or "source" at all. What these do to the result is not the
# same in every case. Four configs are known that it passes while the shell
# runs another file's seat: a good definition, then x=$(echo case), then a
# "." of another file; the same with x=$(echo "esac" case); the plugin's
# source line, then command . of another file; and a good definition, then
# alias src=. and src of another file. The first three are listed as known
# open in scripts/tests/definitions.sh, where the comparison with bash shows
# them. The comparison cannot show the fourth: bash run as bash does not
# expand the alias and keeps the good definition, as the scan says, while sh
# and dash expand it and run the other file's seat. That fixture is kept out
# of the comparison and pinned there with a stub run under sh and dash.
#
# FROZEN. The logic of this function is not to be changed, by an
# arbitration's decision, until an oracle exists that runs configs under sh
# and under dash, and that oracle gives different answers on the alias
# fixture above under bash and under sh. Until then a change here can be
# compared only with bash, which agrees with the scan on that fixture, so it
# could not be shown to fix anything there. Comments may change; the awk
# program may not.
council_definition_scan() {
  _cds_root=${COUNCIL_PLUGIN_ROOT-} _cds_ok=${3-0} \
  awk -v fn="$1" '
    function ev(t, l, s) { n++; et[n] = t; el[n] = l; es[n] = s }
    function late(l) { nl++; ll[nl] = l; ls[nl] = bodystart }
    function blanks(k) { return k > 0 ? sprintf("%" k "s", "") : "" }

    # ---------------------------------------------------------------------
    # The recogniser. lex(R) returns R with every character that is not
    # structure replaced, column for column. Its state carries from line to
    # line: a stack of modes (T the shell text, S single quotes, D double
    # quotes, P a parameter expansion, C a command substitution, B
    # backquoted text), a stack of case states, and the heredocs waiting for
    # their bodies.
    function push(md) { msn++; ms[msn] = md; cd[msn] = 0; pfd[msn] = 0; cc[msn] = 0; cwd[msn] = ""; ar[msn] = 0 }
    # The word just ended inside a command substitution: count case and esac.
    function cword() {
      if (cwd[msn] == "case") cc[msn]++
      else if (cwd[msn] == "esac" && cc[msn] > 0) cc[msn]--
      cwd[msn] = ""
    }
    function wordchar() {
      if (!inword) { inword = 1; wcp = cp; wpos = length(out) + 1; wtext = ""; wplain = 1 }
    }
    # A word has ended: drive the case states, keep a brace only when it is
    # a reserved word in command position, and say whether the next word is
    # in command position.
    function endword(   seg) {
      if (!inword) return
      inword = 0
      if (csn && cs[csn] == "subj") cs[csn] = "in"
      else if (csn && cs[csn] == "in") {
        if (wplain && wtext == "in") { cs[csn] = "pat"; pw = ""; pstart = 1; pfirst = 1 }
      } else if (wcp && wplain && wtext == "case") { csn++; cs[csn] = "subj" }
      else if (wcp && wplain && wtext == "esac" && csn && cs[csn] == "cmd") csn--
      if (!(wcp && wplain && (wtext == "{" || wtext == "}"))) {
        seg = substr(out, wpos)
        gsub(/[{}]/, "_", seg)
        out = substr(out, 1, wpos - 1) seg
      }
      # After the bash word "function" comes a name, and after the name the
      # body, in command position.
      if (fnkw) { fnkw = 0; cp = 1 }
      else if (wcp && wplain && wtext == "function") { fnkw = 1; cp = 0 }
      else if (wcp && wplain && wtext ~ /^(if|then|do|else|elif|while|until|!|[{]|[}])$/) cp = 1
      else if (wcp && wtext ~ /^[A-Za-z_][A-Za-z0-9_]*=/) cp = 1
      else cp = 0
    }
    # "esac" ended the case where a pattern was expected.
    function esacend() {
      out = substr(out, 1, length(out) - 4) "esac"
      csn--
      pw = ""
      cp = 0
    }
    # The delimiter of a heredoc whose operator ends just before J.
    function heredoc(r, j,   strip, d, c, q) {
      strip = 0
      if (substr(r, j, 1) == "-") { strip = 1; j++ }
      while (substr(r, j, 1) ~ /[ \t]/) j++
      d = ""; q = ""
      for (; j <= length(r); j++) {
        c = substr(r, j, 1)
        if (q != "") { if (c == q) q = ""; else d = d c; continue }
        if (c == sq || c == dq) { q = c; continue }
        if (c == bs) { j++; d = d substr(r, j, 1); continue }
        if (c ~ /[ \t;&|()<>]/) break
        d = d c
      }
      if (d == "") return
      hn++; hdel[hn] = d; hstrip[hn] = strip
    }
    function lex(r,   nn, i, c, nx, md, k) {
      out = ""
      nn = length(r)
      if (hdon) {
        k = r
        if (hstrip[hcur]) sub(/^\t+/, "", k)
        if (k == hdel[hcur]) { hcur++; if (hcur > hn) { hdon = 0; hn = 0 } }
        return blanks(nn)
      }
      if (inword) wpos = 1
      if (!contline && ms[msn] == "T") cp = 1
      contline = 0
      i = 1
      while (i <= nn) {
        c = substr(r, i, 1); nx = substr(r, i + 1, 1)
        md = ms[msn]
        if (md == "S") { out = out "_"; if (c == sq) msn--; i++; continue }
        if (md == "B") {
          if (c == bs && i < nn) { out = out "__"; i += 2; continue }
          out = out "_"; if (c == bt) msn--; i++; continue
        }
        if (md == "D" || md == "P" || md == "C") {
          # In a command substitution, the words "case" and "esac" are
          # counted, so that the ")" of a case pattern does not end it.
          if (md == "C" && !ar[msn]) {
            if (c ~ /[A-Za-z]/) cwd[msn] = cwd[msn] c
            else cword()
          }
          if (c == bs) {
            if (i < nn) { out = out "__"; i += 2 } else { out = out "_"; i++ }
            continue
          }
          if (c == "$" && nx == "{") {
            push("P"); pfd[msn] = (md == "D" || (md == "P" && pfd[msn - 1]))
            out = out "__"; i += 2; continue
          }
          if (c == "$" && nx == "(") { push("C"); cd[msn] = 1; ar[msn] = (substr(r, i + 2, 1) == "("); out = out "__"; i += 2; continue }
          if (c == bt) { push("B"); out = out "_"; i++; continue }
          if (md == "D") { out = out "_"; if (c == dq) msn--; i++; continue }
          if (c == dq) { push("D"); out = out "_"; i++; continue }
          if (c == sq && !(md == "P" && pfd[msn])) { push("S"); out = out "_"; i++; continue }
          if (md == "P") { out = out "_"; if (c == "}") msn--; i++; continue }
          if (c == "#" && (i == 1 || substr(r, i - 1, 1) ~ /[ \t;&|()]/)) {
            out = out blanks(nn - i + 1); i = nn + 1; continue
          }
          # A heredoc inside a command substitution: its body is read as a
          # heredoc body, and the substitution goes on after it.
          if (!ar[msn] && c == "<" && nx == "<" && substr(r, i + 2, 1) == "<") { out = out "___"; i += 3; continue }
          if (!ar[msn] && c == "<" && nx == "<") { heredoc(r, i + 2); out = out "__"; i += 2; continue }
          if (cc[msn] == 0) {
            if (c == "(") cd[msn]++
            else if (c == ")") { cd[msn]--; if (cd[msn] == 0) msn-- }
          }
          out = out "_"; i++; continue
        }
        # Mode T, the shell text itself.
        if (csn && cs[csn] == "pat") {
          if ((c == " " || c == "\t" || c ~ /[;&<>]/) && pw == "esac" && pfirst) { esacend(); continue }
          if (c == " " || c == "\t") { out = out c; i++; continue }
          if (c == "#" && pstart) { out = out blanks(nn - i + 1); i = nn + 1; continue }
          if (c == "(" && pstart) { out = out "_"; pstart = 0; i++; continue }
          if (c == ")") { out = out ";"; cs[csn] = "cmd"; cp = 1; pw = ""; i++; continue }
          if (c == "|") { out = out "_"; pw = ""; pfirst = 0; i++; continue }
          pstart = 0
          if (c == bs) {
            pw = pw "_"
            if (i < nn) { out = out "__"; i += 2 } else { out = out "_"; i++ }
            continue
          }
          if (c == sq || c == dq || c == bt) {
            pw = pw "_"; push(c == sq ? "S" : (c == dq ? "D" : "B")); out = out "_"; i++; continue
          }
          if (c == "$" && (nx == "{" || nx == "(")) {
            pw = pw "_"; push(nx == "{" ? "P" : "C"); if (nx == "(") { cd[msn] = 1; ar[msn] = (substr(r, i + 2, 1) == "(") }
            out = out "__"; i += 2; continue
          }
          pw = pw c; out = out "_"; i++; continue
        }
        if (c == bs) {
          if (i == nn) { out = out bs; contline = 1; i++; continue }
          wordchar(); wplain = 0; out = out "__"; i += 2; continue
        }
        if (c == sq || c == dq || c == bt) {
          wordchar(); wplain = 0
          push(c == sq ? "S" : (c == dq ? "D" : "B"))
          out = out "_"; i++; continue
        }
        if (c == "$" && (nx == "{" || nx == "(")) {
          wordchar(); wplain = 0
          push(nx == "{" ? "P" : "C"); if (nx == "(") { cd[msn] = 1; ar[msn] = (substr(r, i + 2, 1) == "(") }
          out = out "__"; i += 2; continue
        }
        if (c == "#" && !inword) { out = out blanks(nn - i + 1); i = nn + 1; continue }
        if (c == " " || c == "\t") { endword(); out = out c; i++; continue }
        if (c ~ /[;&|()<>]/) {
          endword()
          # "<<<" is a here-string in bash and not a heredoc.
          if (c == "<" && nx == "<" && substr(r, i + 2, 1) == "<") {
            out = out "<<<"; i += 3; cp = 0; continue
          }
          if (c == "<" && nx == "<") {
            heredoc(r, i + 2); out = out "<<"; i += 2; cp = 0; continue
          }
          if (c == ";" && (nx == ";" || nx == "&")) {
            if (csn && cs[csn] == "cmd") { cs[csn] = "pat"; pw = ""; pstart = 1; pfirst = 1 }
            out = out c nx; i += 2; cp = 1
            if (substr(r, i, 1) == "&") { out = out "&"; i++ }
            continue
          }
          out = out c; i++
          cp = (c == "<" || c == ">") ? 0 : 1
          continue
        }
        wordchar(); wtext = wtext c; out = out c; i++
      }
      if (ms[msn] == "T") {
        if (csn && cs[csn] == "pat" && pw == "esac" && pfirst) esacend()
        if (!contline) { endword(); cp = 1 }
      }
      if (ms[msn] == "C") cword()
      if ((ms[msn] == "T" || ms[msn] == "C") && hn > 0 && !hdon) { hdon = 1; hcur = 1 }
      return out
    }

    # ---------------------------------------------------------------------
    # The structure, read from what lex returns.
    #
    # The words of S in command position, into cw[1..ncw].
    function cmdwords(s,   t, k, i, w, pos) {
      t = s
      gsub(sep, " & ", t)
      k = split(t, tk, /[ \t]+/)
      ncw = 0; pos = 1
      for (i = 1; i <= k; i++) {
        w = tk[i]
        if (w == "") continue
        if (w ~ ("^" sep "$")) { pos = 1; continue }
        if (!pos) continue
        ncw++; cw[ncw] = w
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        if (w ~ /^(if|then|do|else|elif|while|until|!|[{])$/) continue
        pos = 0
      }
    }
    function sources(s,   i) {
      cmdwords(s)
      for (i = 1; i <= ncw; i++) if (cw[i] == "." || cw[i] == "source") return 1
      return 0
    }
    # The shell word of the raw text S that starts at I, quotes removed; its
    # end in wend.
    function word(s, i,   c, q, w) {
      w = ""; q = ""
      for (; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; else w = w c; continue }
        if (c == dq || c == sq) { q = c; continue }
        if (c ~ /[ \t;&|<>()]/) break
        w = w c
      }
      wend = i
      return w
    }
    # 1 when the word A, quotes removed, names the plugin config in one of
    # the three spellings the scan takes; 2 when it names it another way,
    # such as ${COUNCIL_PLUGIN_ROOT:?}; 0 otherwise.
    function plugspell(a) {
      if (a == "$COUNCIL_PLUGIN_ROOT/config/council.conf" ||
          a == "${COUNCIL_PLUGIN_ROOT}/config/council.conf" ||
          (root != "" && a == root "/config/council.conf")) return 1
      if (index(a, "COUNCIL_PLUGIN_ROOT") && a ~ /\/config\/council\.conf$/) return 2
      return 0
    }
    # The number of "." or "source" words in the structure M followed by a
    # word of the raw text R that names the plugin config, in any spelling.
    function plugsources(m, r,   off, k) {
      off = 0; k = 0
      while (match(substr(m, off + 1), /(^|[;&|() \t])(\.|source)[ \t]+/)) {
        if (plugspell(word(r, off + RSTART + RLENGTH))) k++
        off = off + RSTART + RLENGTH - 1
      }
      return k
    }
    # 1 when M is "." or "source" naming the plugin config in a spelling the
    # scan takes, followed by nothing, ";", "&&" or "||"; 2 when it names it
    # followed by anything else; 3 when it names it in another spelling; 0
    # when it does not name it.
    function plugin_line(m, r,   a, rest, k) {
      if (!match(m, /^[ \t]*(\.|source)[ \t]+/)) return 0
      a = word(r, RLENGTH + 1)
      k = plugspell(a)
      if (k == 0) return 0
      if (k == 2) return 3
      rest = substr(m, wend)
      sub(/^[ \t]+/, "", rest)
      if (rest == "" || rest ~ /^(&&|[|][|]|;$|;[^;])/) return 1
      return 2
    }
    # The block words of S, in command position, applied to depth.
    function blocks(s,   i) {
      cmdwords(s)
      for (i = 1; i <= ncw; i++) {
        if (cw[i] ~ /^(if|case|for|while|until|[{])$/) depth++
        else if (cw[i] ~ /^(fi|esac|done|[}])$/) depth--
      }
      if (s ~ /[(][ \t]*$/) depth++
      if (s ~ /^[ \t]*[)]/) depth--
      if (depth < 0) { confused = 1; depth = 0 }
    }
    # Walks the brackets of the structure S from depth B: "{" and "(" open,
    # "}" and ")" close. Returns the new depth. When it reaches zero, bclosed
    # is 1 and bpos is the column after the closing bracket.
    function bodyscan(s, b,   j, c) {
      bclosed = 0; bpos = 0
      for (j = 1; j <= length(s); j++) {
        c = substr(s, j, 1)
        if (c == "{" || c == "(") b++
        else if (c == "}" || c == ")") {
          b--
          if (b == 0) { bclosed = 1; bpos = j + 1; return b }
        }
      }
      return b
    }
    # The first text of a function body, at line lno: what is sourced or
    # defined in it counts at the end of the file. Returns the column where
    # the text after a body that closes in M begins, or 0, and opens ibody
    # when the body does not close.
    function bodystartof(m,   b, head) {
      b = bodyscan(m, 0)
      head = bclosed ? substr(m, 1, bpos - 1) : m
      if (head ~ stray || sources(head)) late(lno)
      if (b > 0) { ibody = 1; ibal = b; return 0 }
      if (bclosed) {
        if (curdef) { ez[curdef] = lno; curdef = 0 }
        return bpos
      }
      curdef = 0
      return 0
    }
    # A line outside any function body, as structure M and raw text R.
    function toplevel(m, r, blocked,   i, p, isplug, npl, rm, rr, st, tp) {
      if (m ~ stray) ev("F", lno)
      # A function defined after column 1: only the text before it, and
      # what follows its body once that closes, is read as top level.
      if (match(m, anydef)) {
        st = RSTART
        rm = substr(m, st + RLENGTH); rr = substr(r, st + RLENGTH)
        m = substr(m, 1, st); r = substr(r, 1, st)
        if (st == 1 && m ~ /^[A-Za-z_]/) { m = ""; r = "" }
        bodystart = lno
        curdef = 0
        if (rm ~ /^[ \t]*$/) pending = 1
        else {
          tp = bodystartof(rm)
          if (tp) { m = m " ; " substr(rm, tp); r = r " ; " substr(rr, tp) }
        }
      }
      p = plugin_line(m, r)
      npl = plugsources(m, r)
      cmdwords(m)
      for (i = 1; i <= ncw; i++) {
        # eval can define or source anything, so it is an OTHER. return
        # and exit can stop the config before a later line runs; they are
        # an event that matters only before the winning line.
        if (cw[i] == "eval") { ev("O", lno); continue }
        if (cw[i] == "return" || cw[i] == "exit") { ev("X", lno); continue }
        if (cw[i] != "." && cw[i] != "source") continue
        isplug = (i == 1 && p != 0)
        if (isplug) npl--
        if (isplug && !plugok) continue
        if (isplug && p == 3) ev("S", lno)
        else if (isplug && p == 1 && !blocked) ev("P", lno)
        else if (isplug) ev("C", lno)
        else if (npl > 0) { npl--; if (plugok) ev("C", lno) }
        else ev("O", lno)
      }
      blocks(m)
    }
    BEGIN {
      dq = sprintf("%c", 34); sq = sprintf("%c", 39)
      bs = sprintf("%c", 92); bt = sprintf("%c", 96)
      root = ENVIRON["_cds_root"]
      plugok = (ENVIRON["_cds_ok"] == "1")
      stray = "(^|[^A-Za-z0-9_])(" fn "[ \t]*[(][)]|function[ \t]+" fn "([^A-Za-z0-9_]|$))"
      anydef = "(^|[;&|(){ \t])([A-Za-z_][A-Za-z0-9_]*[ \t]*[(][ \t]*[)]|function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*[(][ \t]*[)])?)"
      sep = "[;&|()" bt "]"
      msn = 1; ms[1] = "T"; cp = 1
    }
    {
      gsub(/\r/, "")
      raw = $0
      m = lex(raw)
      # A backslash at the end of a line joins it to the next one: the two
      # are read as one line, numbered as the first, which is the number
      # the shell gives a definition written that way.
      if (contline) {
        if (!joined) { joined = 1; jl = NR }
        jm = jm substr(m, 1, length(m) - 1)
        jr = jr substr(raw, 1, length(raw) - 1)
        next
      }
      lno = NR
      if (joined) { m = jm m; raw = jr raw; lno = jl; jm = ""; jr = ""; joined = 0 }
      if (m ~ /^[ \t]*$/) next
      # The line after a definition whose own line ended at the
      # parentheses: when it opens the body, read it as the body.
      if (pending) {
        pending = 0
        if (m ~ /^[ \t]*[{(]/) {
          tp = bodystartof(m)
          if (tp) toplevel(substr(m, tp), substr(raw, tp), depth > 0 || confused)
          next
        }
        curdef = 0
      }
      # Inside a function body. What follows the bracket that closes it is
      # read as top level, so that a "}; fi" still closes its block.
      if (ibody) {
        ibal = bodyscan(m, ibal)
        head = bclosed ? substr(m, 1, bpos - 1) : m
        if (index(head, fn "()") == 1 || head ~ stray || sources(head)) late(lno)
        if (bclosed) {
          ibody = 0
          if (curdef) { ez[curdef] = lno; curdef = 0 }
          toplevel(substr(m, bpos), substr(raw, bpos), depth > 0 || confused)
        } else if (ibal <= 0) { ibody = 0; curdef = 0 }
        next
      }
      blocked = (depth > 0 || cont || confused)
      cont = (m ~ /(\\|&&|[|])[ \t]*$/)
      if (match(m, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*[(][ \t]*[)]/) || match(m, /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*[(][ \t]*[)])?/)) {
        rm = substr(m, RLENGTH + 1); rr = substr(raw, RLENGTH + 1)
        name = substr(m, 1, RLENGTH)
        sub(/^function[ \t]+/, "", name)
        sub(/[ \t]*[(][ \t]*[)]$/, "", name)
        curdef = 0
        if (index(m, fn "()") == 1) { ev(blocked ? "K" : "D", lno); if (!blocked) curdef = n }
        else if (name == fn) ev("F", lno)
        bodystart = lno
        cont = 0
        if (rm ~ /^[ \t]*$/) { pending = 1; next }
        tp = bodystartof(rm)
        if (tp) toplevel(substr(rm, tp), substr(rr, tp), depth > 0 || confused)
        next
      }
      toplevel(m, raw, blocked)
    }
    END {
      for (i = 1; i <= nl; i++) ev("L", ll[i], ls[i])
      e = 0
      for (i = 1; i <= n; i++) if (et[i] == "D" || et[i] == "P") e = i
      for (i = e + 1; i <= n; i++) {
        if (et[i] == "O") { print "other " el[i]; exit }
        if (et[i] == "C" || et[i] == "K") { print "cond " el[i]; exit }
        if (et[i] == "F") { print "form " el[i]; exit }
        if (et[i] == "S") { print "spelling " el[i]; exit }
        if (et[i] == "L") { print "inbody " el[i] " " es[i]; exit }
      }
      for (i = 1; i < e; i++) if (et[i] == "X") { print "exit " el[i]; exit }
      if (e == 0) { print "none"; exit }
      if (et[e] == "D") { print "def " el[e] " " (ez[e] + 0); exit }
      # A definition of any form above the source line never runs if the
      # line runs: one in column 1, one inside a block, or one in a form the
      # reader does not read.
      a = 0
      for (i = 1; i < e; i++) if (et[i] == "D" || et[i] == "K" || et[i] == "F") a = el[i]
      print "plugin " el[e] " " a
    }
  ' "$2" 2>/dev/null
}

# council_body_denies_bash BODY -- true when BODY, the text of one function,
# names Bash among the arguments of a --disallowedTools. Read as text:
# continuation lines are joined, whole-line comments dropped, and the arguments
# are the words after the flag up to the next word that starts an option, a
# redirection or the end of the command. Bash, "Bash" and a comma-separated
# --disallowedTools=...,Bash,... count; Bash(...) does not, since it names a
# command pattern and not the tool.
council_body_denies_bash() {
  printf '%s\n' "$1" | awk '
    BEGIN { bs = sprintf("%c", 92); q = sprintf("%c", 34); found = 0; buf = "" }
    /^[ \t]*#/ { next }
    {
      line = $0
      if (substr(line, length(line), 1) == bs) { buf = buf substr(line, 1, length(line) - 1) " "; next }
      buf = buf line
      n = split(buf, t, /[ \t]+/)
      on = 0
      for (i = 1; i <= n; i++) {
        w = t[i]
        if (w == "") continue
        if (w == "--disallowedTools" || w == "--disallowed-tools") { on = 1; continue }
        if (index(w, "--disallowedTools=") == 1 || index(w, "--disallowed-tools=") == 1) {
          m = split(substr(w, index(w, "=") + 1), v, ",")
          for (k = 1; k <= m; k++) if (v[k] == "Bash") found = 1
          on = 0
          continue
        }
        if (on && (substr(w, 1, 1) == "-" || w ~ /^[<>|;&)]/)) on = 0
        if (on && (w == "Bash" || w == q "Bash" q)) found = 1
      }
      buf = ""
    }
    END { exit found ? 0 : 1 }'
}

# council_unknown_reasons -- one line per entry of COUNCIL_CHECK_UNKNOWN_AT,
# saying why that function's definition is unknown. Shared by the refusal
# below, the note in council_check_deny_used and council-doctor.sh.
council_unknown_reasons() {
  for _ur in ${COUNCIL_CHECK_UNKNOWN_AT-}; do
    _ur_fn=${_ur%%:*}
    _ur_rest=${_ur#*:}
    _ur_kind=${_ur_rest%%:*}
    _ur_line=${_ur_rest#*:}
    _ur_line=${_ur_line%%:*}
    _ur_start=${_ur_rest##*:}
    case "$_ur_kind" in
      unread) printf '%s\n' "$_ur_fn: its definition at line $_ur_line could not be read to its end. The check reads a body that closes with } in column 1 before another definition starts in column 1, or one written whole on its definition line with exactly one { and one }, no #, an even count of each quote, and an end of \"; }\" or \"& }\"; and the text it reads must end on the line where the shell closes the body, which a heredoc or a quoted string can move." ;;
      other) printf '%s\n' "$_ur_fn: line $_ur_line sources a file the check does not read, after the last definition it can see, so the body that runs may come from that file." ;;
      cond) printf '%s\n' "$_ur_fn: line $_ur_line defines it or sources the plugin's config/council.conf where the check cannot tell whether that line runs: inside a multi-line if, case, for, while, until or { } block, after another command on the line such as [ -f ... ] &&, on a line continued from the one before, with something after it on its line other than a comment, ;, && or ||, or after a word that closes a block the check did not see open. Whichever that line holds, write it at the top level, outside any block and not continued from the line before: a definition in column 1, or the line that sources the plugin's config on its own, first on its line." ;;
      exit) printf '%s\n' "$_ur_fn: line $_ur_line can stop the config with return or exit before the line that defines it, so the check cannot tell whether that line runs." ;;
      spelling) printf '%s\n' "$_ur_fn: line $_ur_line sources the plugin's config/council.conf in a spelling the check does not take as that line. It takes \"\$COUNCIL_PLUGIN_ROOT/config/council.conf\", the same with \${COUNCIL_PLUGIN_ROOT}, or the literal path." ;;
      form) printf '%s\n' "$_ur_fn: line $_ur_line defines it in a form the check does not read: indented, after another command on the line, with a blank before the parentheses, or with the word function." ;;
      inbody) printf '%s\n' "$_ur_fn: line $_ur_line, inside the function body that starts at line $_ur_start, sources a file or defines it, and the text cannot say when that function is called." ;;
      *) printf '%s\n' "$_ur_fn: the config defines it nowhere the check can see, and does not source the plugin's config/council.conf where the plugin defines it." ;;
    esac
  done
}

# The refusal for functions whose definition council_check_deny_used could not
# read or could not tell would run (COUNCIL_CHECK_UNKNOWN). One copy, used by
# council_require_deny_used and by council-assign.sh, so the two cannot drift
# apart.
council_unread_message() {
  printf '%s' "could not tell which definition runs, or could not read it, for:${COUNCIL_CHECK_UNKNOWN-}, so none of the three requirements was checked for it: the deny rule, \$(council_seat_flags) and Bash in --disallowedTools. In $COUNCIL_CONFIG_USED: $(council_unknown_reasons | tr '\n' ' ')A definition the check reads is one at the top level, in column 1, below every line that sources a file other than the plugin's config, closing with } in column 1, as config/council.conf does. Unknown is not the same as fine, and there is no option to skip this check. Nothing has been run."
}

# The refusal for a definition that never runs (COUNCIL_CHECK_SHADOWED): the
# config in use defines a seat and then sources the plugin's config, which
# defines it again, and the shell keeps the one executed last. The body that
# runs is the plugin's, and the requirements were checked on it, so this is
# not about the seat's safety. It is the same failure as a setting overridden
# in silence, which council_load_config refuses: the command line the author
# wrote is not the one that runs. Decided by a council on 2026-11-19; a
# warning that let the run continue never stopped anything (see
# council_require_deny_used).
council_shadowed_message() {
  _sm_list=""
  for _sm in ${COUNCIL_CHECK_SHADOWED-}; do
    _sm_fn=${_sm%%:*}
    _sm_rest=${_sm#*:}
    _sm_list="$_sm_list $_sm_fn at line ${_sm_rest%%:*}, defined again by the file sourced at line ${_sm_rest#*:};"
  done
  printf '%s' "in $COUNCIL_CONFIG_USED these functions are defined above the line that sources the plugin's config/council.conf, which defines them again, so the definition written there never runs:$_sm_list the plugin's runs instead, and that is the one the requirements were checked on. Move each definition below that line, or delete it. Nothing has been run."
}

# True when the last council_check_deny_used read the arbiter's definition and
# found no "claude" in it, so none of the three requirements was checked for
# it. council-review.sh and council-assign.sh refuse on it and council-doctor.sh
# reports a FAIL; there is no option to skip, as there is none for a function
# that could not be read. Decided by a council on 2026-11-21.
#
# It reads COUNCIL_DENY_UNCOVERED and calls nothing. It tests the one word
# arbiter, not whether that list is empty: council-doctor.sh calls the check
# once with the arbiter and every planner, and planner_codex, which holds no
# "claude", is in the list whenever codex is seated.
#
# Every call of council_check_deny_used resets COUNCIL_DENY_UNCOVERED and
# COUNCIL_CHECK_CLAUDE, and council_seat_check and council_seat_skip read
# both. So no call of it may be placed between a phase's check and its seat
# check or skip: the wrong seats would be probed, or recorded as unprobed.
council_arbiter_unjudged() {
  case " ${COUNCIL_DENY_UNCOVERED-} " in
    *" arbiter "*) return 0 ;;
  esac
  return 1
}

# The refusal for that arbiter. One copy, used by council-review.sh and by
# council-assign.sh, so the two cannot drift apart.
council_arbiter_unjudged_message() {
  printf '%s' "the arbiter in $COUNCIL_CONFIG_USED was read, and the word claude is not in its definition, so none of the three requirements was checked for it: the deny rule, \$(council_seat_flags) and Bash in --disallowedTools. The check reads the arbiter's own definition and does not follow a function it calls, so it cannot tell an arbiter that reaches claude through another function from one that drives another CLI, and it refuses both. Write the claude command line in arbiter itself, with all three, as config/council.conf does. Only the arbiter is refused for this: a planner with no claude in its definition is not refused, and is checked for nothing. There is no option to skip this check."
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
#
# A function whose definition could not be read refuses as well, and there is
# no flag to walk past it: the owner decided so on 2026-11-19, because this
# project had just removed a gate that could be walked past by accident.
# council-assign.sh splits its refusals by cause -- it continues when only the
# deny rule is missing, since attribution is not at stake there, and stops on
# capability -- but an unread function has no known cause to split on: nothing
# is known about it, capability included. So every phase refuses it, assignment
# too, and that is deliberate, not a case the split forgot.
council_require_deny_used() {
  council_check_deny_used "$1" && return 0
  if [ -n "${COUNCIL_CHECK_UNKNOWN-}" ]; then
    council_die "$(council_unread_message)"
  fi
  # Before the message below, which would be false here: the body that runs
  # may carry everything a seat must.
  if [ -n "${COUNCIL_CHECK_SHADOWED-}" ]; then
    council_die "$(council_shadowed_message)"
  fi
  council_die "a claude function named above lacks what every seat must carry. One without \"\$COUNCIL_DENY\" breaks the requirement that keeps a seat out of the run directory, where council.txt says which planner wrote which plan: add \"\$COUNCIL_DENY\" and \"\$COUNCIL_DENY2\" to its --disallowedTools. One without \$(council_seat_flags) starts claude with the host's settings, hooks and connector tools: put \$(council_seat_flags), unquoted, on its claude command line. One without Bash in its --disallowedTools relies on \$(council_seat_flags) alone to keep the shell out, and on nothing when it lacks those flags too: add Bash there. config/council.conf does all three. A missing deny rule was a warning that let the run continue; it stops the run now, because a council whose arbiter can look up the attribution is not worth paying for."
}

council_check_deny_used() {
  _missing=""
  _noflags=""
  _quoted=""
  _nobash=""
  _nobash_bare=""
  _unknown=""
  _unknown_at=""
  _shadowed=""
  _claude_fns=""
  COUNCIL_DENY_UNCOVERED=""
  COUNCIL_CHECK_CLAUDE=""
  COUNCIL_CHECK_NODENY=""
  COUNCIL_CHECK_NOFLAGS=""
  COUNCIL_CHECK_NOBASH=""
  COUNCIL_CHECK_UNKNOWN=""
  COUNCIL_CHECK_UNKNOWN_AT=""
  COUNCIL_CHECK_SHADOWED=""
  # Which definition runs is read from the config in use, in line order, by
  # council_definition_scan. The plugin's own config is read only when the
  # last thing there that defines the function is the line that sources it.
  # An earlier version took the first body it found, in the config in use and
  # then in the plugin's, while the shell keeps the last one executed: it
  # could approve a body that never runs, and a body in a third file was
  # never seen, so the plugin's was approved in its place.
  _plugin_cfg="${COUNCIL_PLUGIN_ROOT:-}/config/council.conf"
  if [ ! -f "$_plugin_cfg" ] || [ "$_plugin_cfg" = "$COUNCIL_CONFIG_USED" ]; then
    _plugin_cfg=""
  fi
  for _fn in $1; do
    type "$_fn" >/dev/null 2>&1 || continue
    _plugin_body=""
    [ -n "$_plugin_cfg" ] && _plugin_body=$(council_function_body "$_fn" "$_plugin_cfg")
    _plugin_has=0
    [ -n "$_plugin_body" ] && _plugin_has=1
    _scan=$(council_definition_scan "$_fn" "$COUNCIL_CONFIG_USED" "$_plugin_has")
    _scan=${_scan:-none}
    _body=""
    case "$_scan" in
      "def "*)
        # "def A Z": the definition at line A, whose body the scan saw close
        # at line Z (0 when it did not). The reader keeps its own line
        # convention, which the canary relied on until 2026-11-20; when the text it returns
        # does not end on line Z, the reader stopped somewhere the shell did
        # not -- a "}" in column 1 inside a heredoc, a one-line body whose
        # "; }" sits inside a quote, a close that is not its own -- and the
        # body is unread, not judged on the wrong text.
        _da=${_scan#def }
        _dz=${_da#* }
        _da=${_da%% *}
        _body=$(council_function_body "$_fn" "$COUNCIL_CONFIG_USED" "$_da")
        if [ -n "$_body" ] && [ "$(printf '%s\n' "$_body" | wc -l | tr -d ' ')" -ne $((_dz - _da + 1)) ]; then
          _body=""
        fi
        [ -n "$_body" ] || _unknown_at="$_unknown_at $_fn:unread:$_da"
        ;;
      "plugin "*)
        _body=$_plugin_body
        [ -n "$_body" ] || _unknown_at="$_unknown_at $_fn:none"
        # A definition above the source line that wins, of a function the
        # plugin's config itself defines, never runs: refused, see
        # council_shadowed_message. A function the plugin does not ship,
        # written above that line as commands/council-setup.md recommends,
        # never reaches this branch: the source line cannot change it.
        _sh_b=${_scan#plugin }
        _sh_a=${_sh_b#* }
        _sh_b=${_sh_b%% *}
        if [ "$_sh_a" != 0 ] && [ -n "$_plugin_body" ]; then
          _shadowed="$_shadowed $_fn:$_sh_a:$_sh_b"
        fi
        ;;
      *)
        _unknown_at="$_unknown_at $_fn:$(printf '%s' "$_scan" | tr ' ' ':')"
        ;;
    esac
    if [ -z "$_body" ]; then
      _unknown="$_unknown $_fn"
      continue
    fi
    case "$_body" in
      *claude*)
        _claude_fns="$_claude_fns $_fn"
        # The deny and flags tests read the body without its whole-line
        # comments, as council_body_denies_bash does: a commented-out
        # occurrence passed both before.
        _code=$(printf '%s\n' "$_body" | sed '/^[[:space:]]*#/d')
        # The name must stand on its own: $COUNCIL_DENY or ${COUNCIL_DENY
        # followed by a character that cannot continue a shell name. An
        # earlier pattern, *COUNCIL_DENY*, was satisfied by "$COUNCIL_DENY2"
        # alone, and the 0.4.0 gate passed a function that carried only that.
        # Under the default layout, a run in ROOT/.council, that was a defect
        # of the check: planning sets COUNCIL_DENY2 to COUNCIL_DENY, and review
        # and assignment set it to the whole ROOT/.council tree, which holds
        # the run. It was a real gap when the run directory lies anywhere else:
        # council-plan.sh --out puts it anywhere, an ignored or a tracked path
        # inside ROOT included, while COUNCIL_DENY2 still names only
        # ROOT/.council. Such a function was not denied the run directory. In
        # 0.4.0 that held inside ROOT and outside it alike (a read outside the
        # root was measured unrefused on 2026-11-14). With the flags of
        # council_seat_flags, a read by absolute path outside the root was
        # refused (measured 2026-11-19), so the part of that gap still open
        # without this exact match is a run directory inside ROOT and
        # outside ROOT/.council.
        case "$_code" in
          *'$COUNCIL_DENY'[!A-Za-z0-9_]*|*'${COUNCIL_DENY'[!A-Za-z0-9_]*) ;;
          *) _missing="$_missing $_fn" ;;
        esac
        # Quoted, "$(council_seat_flags)" reaches the CLI as one argument. The
        # reviewer of this change ran that form and the CLI refused it, with
        # "error: unknown option '--restricted --tools ...'", so it fails
        # loudly rather than weakening the seat; what it cost here was an ok
        # from this check. It is refused as its own case.
        case "$_code" in
          *'"$(council_seat_flags)'*) _quoted="$_quoted $_fn" ;;
          *'$(council_seat_flags)'*) ;;
          *) _noflags="$_noflags $_fn" ;;
        esac
        if ! council_body_denies_bash "$_body"; then
          case "$_code" in
            *'"$(council_seat_flags)'*) _nobash_bare="$_nobash_bare $_fn" ;;
            *'$(council_seat_flags)'*) _nobash="$_nobash $_fn" ;;
            *) _nobash_bare="$_nobash_bare $_fn" ;;
          esac
        fi
        ;;
      *) COUNCIL_DENY_UNCOVERED="$COUNCIL_DENY_UNCOVERED $_fn" ;;
    esac
  done
  COUNCIL_CHECK_UNKNOWN_AT=$_unknown_at
  COUNCIL_CHECK_SHADOWED=$_shadowed
  if [ -n "$_unknown" ]; then
    council_say "note: could not tell which definition runs, or could not read it, for$_unknown in $COUNCIL_CONFIG_USED, so none of the three requirements was checked for it: the deny rule, \$(council_seat_flags) and Bash in --disallowedTools. Unknown is not the same as fine. $(council_unknown_reasons | tr '\n' ' ')"
  fi
  _cdu_rc=0
  [ -n "$_unknown" ] && _cdu_rc=1
  if [ -n "$_shadowed" ]; then
    council_say "WARNING: $(council_shadowed_message | sed 's/ Nothing has been run\.$//')"
    _cdu_rc=1
  fi
  if [ -n "$_missing" ]; then
    council_say "WARNING: these claude functions do not pass \$COUNCIL_DENY to their CLI, the rule that keeps a seat out of the run directory, where council.txt says which planner wrote which plan:$_missing"
    _cdu_rc=1
  fi
  if [ -n "$_noflags" ]; then
    council_say "WARNING: these claude functions do not call \$(council_seat_flags), so the session they start loads the host's settings, hooks and connector tools and answers a different question from the seats the plugin ships:$_noflags"
    _cdu_rc=1
  fi
  if [ -n "$_quoted" ]; then
    council_say "WARNING: these claude functions quote \$(council_seat_flags), which hands the CLI the flags as one argument it refuses; write it unquoted:$_quoted"
    _cdu_rc=1
  fi
  if [ -n "$_nobash" ]; then
    council_say "WARNING: these claude functions do not name Bash in their --disallowedTools. They call \$(council_seat_flags), whose flags leave the shell out today; the name is kept so that it stays out if a CLI release changed what those flags remove:$_nobash"
    _cdu_rc=1
  fi
  if [ -n "$_nobash_bare" ]; then
    council_say "WARNING: these claude functions do not name Bash in their --disallowedTools and do not call \$(council_seat_flags) unquoted either, so nothing in their definition keeps the shell out:$_nobash_bare"
    _cdu_rc=1
  fi
  COUNCIL_CHECK_NODENY=$_missing
  COUNCIL_CHECK_NOFLAGS="$_noflags$_quoted"
  COUNCIL_CHECK_NOBASH="$_nobash$_nobash_bare"
  COUNCIL_CHECK_UNKNOWN=$_unknown
  COUNCIL_CHECK_CLAUDE=$_claude_fns
  if [ "$_cdu_rc" -ne 0 ]; then
    council_say "note: this is a text check. It reads each function's definition in the config file, not the process the function starts."
  fi
  return "$_cdu_rc"
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

# Expands to the flags every claude session this plugin starts must carry: the
# four claude functions in config/council.conf, council_probe_call below and
# the deny canary's child in council-detect.sh. Expanded unquoted at the call
# site, as council_budget_flags is, and written only here: a second copy of a
# flag list drifts from the first in silence.
#
# What each flag is for:
#   --tools Read,Glob,Grep    the built-in tools the session gets, and no
#                             others.
#   --restricted              removes the tools that run commands and confines
#                             the file tools to the working directory.
#   --setting-sources project,local
#                             loads settings from those two sources and not
#                             from the user's own (the CLI's --help).
#   --strict-mcp-config       starts only the MCP servers named on the command
#                             line, and none is named here.
#   --disable-slash-commands  disables skills and commands (the CLI's --help;
#                             not measured on its own).
#
# Measured 2026-11-19, each with a control:
#   - --allowedTools is not exclusive. A child given only Read ran
#     "git log --oneline -1": allowed, and it printed the real commit. The
#     protection of 0.4.0 rested on that list.
#   - With the 0.4.0 list and --disallowedTools Edit Write NotebookEdit, a
#     child ran "git show --output=b5-write-probe.txt -s HEAD": allowed, and
#     the file existed, 4370 bytes, inside the context root.
#   - A deny rule on a command prefix, Bash(git show --output:*), did not stop
#     it: the obvious spelling and the same flags reordered were both allowed
#     and both wrote the file.
#   - --tools is exclusive: with --tools Read,Glob,Grep the tool inventory came
#     back as exactly Glob, Grep, Read.
#   - A tool denied by name is removed: with Bash in --disallowedTools the
#     session reported "the Bash tool isn't available in this session". It is
#     absent, not refused on use, so nothing is recorded for it (see the
#     comment above council_seat_check).
#   - --restricted on its own: a read of an absolute path outside the root was
#     refused, one inside it allowed (863 lines). On its own it does not
#     remove Write, Edit, NotebookEdit, Agent, WebSearch or the worktree tools;
#     that is what --tools is here for.
#   - Without settings flags a seat held the host's connector tools, among
#     them tools that draft messages and handle attachments. Either
#     --setting-sources project,local or --strict-mcp-config, alone, brought
#     the MCP tool count to 0.
#   - The whole set, measured together: inventory Glob, Grep, Read; a read
#     inside the root allowed (863 lines); an absolute path outside it
#     refused; .council refused; a search returned 6 paths; and the identity
#     gate still reported modelUsage claude-opus-5-5.
#
# The call sites also keep Edit, Write, NotebookEdit and Bash in
# --disallowedTools, although --tools leaves them out today. Denying a tool by
# name was measured effective (above). Keeping the names rests on a belief
# about the CLI's future, not on a measurement: if a release made --tools add
# to the default set instead of replacing it, the names would be the only thing
# left keeping those tools out.
#
# One switch, and only one caller sets it: council_seat_check, inside the
# subshell that calls a seat for the per-run seat check, adds
# --output-format json so that the CLI writes its record of the call. Nothing
# else may ever see it. An answer is accepted on its size alone
# (council_answer_ok), so a switch left on would put JSON where a plan belongs
# and no exit code would change. It is therefore tested for the exact value 1,
# set only inside that subshell, which ends with it, and cleared below when
# this file is sourced, so that a value exported by the environment cannot
# turn it on. Its name is kept out of the COUNCIL_ namespace so that no
# setting can be mistaken for it. council_probe_call and the deny canary in
# council-detect.sh expand this function too; neither runs inside that
# subshell, so neither ever sees the switch, and council_probe_call, which
# asks for JSON on its own, does not get the flag twice.
council_seat_flags() {
  printf -- '--restricted --tools Read,Glob,Grep --setting-sources project,local --strict-mcp-config --disable-slash-commands'
  if [ "${_council_seat_json-}" = 1 ]; then
    printf -- ' --output-format json'
  fi
  return 0
}
unset _council_seat_json

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

# --- The repository, as the runner reads it for the seats ---------------------
# No seat has a shell: $(council_seat_flags) gives a claude seat Read, Glob and
# Grep only, so a planner cannot run git rev-parse to say which commit it read.
# The host injects a git snapshot into every Claude child, and
# --exclude-dynamic-system-prompt-sections does not remove it (measured), but
# the plugin does not control that injection, it can change under it, and a
# Codex seat does not get it at all. So the runner reads the facts itself and
# hands them over in the prompt.
#
# The reason that survives any change in the CLIs: the planners must read the
# same bytes. A blind council whose planners are told different facts about
# the tree is not comparing plans, it is comparing situations. That is why
# council-plan.sh reads these facts once and puts them in the one shared
# prompt, before the per-planner copies and the check that they are identical,
# and never per planner.
#
# The price: file names reach the prompts verbatim, through git status
# --porcelain here and git diff --stat at review. git status --porcelain names
# untracked files that are not ignored, so a scratch file in the tree is named
# in the prompt. The README's "What the prompts say about your repository"
# says so where a user configuring this will see it.

# council_git_facts ROOT -- reads, with git, from ROOT, and sets:
#   COUNCIL_GIT_HEAD    the commit HEAD names, or a sentence starting "none:"
#                       or "unknown:" saying why there is none;
#   COUNCIL_GIT_BRANCH  the branch, or a sentence starting "none:" or
#                       "unknown:";
#   COUNCIL_GIT_TREE    clean, dirty, "not a git work tree", or a sentence
#                       starting "unknown:";
#   COUNCIL_GIT_STATUS  the output of git status --porcelain, verbatim, when
#                       the tree is dirty; empty otherwise.
# It never fails the run: a root git cannot describe is described as such.
# git status runs with GIT_OPTIONAL_LOCKS=0, so reading the tree does not
# refresh and rewrite the index of the user's repository.
council_git_facts() {
  COUNCIL_GIT_HEAD=""
  COUNCIL_GIT_BRANCH=""
  COUNCIL_GIT_TREE=""
  COUNCIL_GIT_STATUS=""
  if ! command -v git > /dev/null 2>&1; then
    COUNCIL_GIT_HEAD="unknown: git is not on PATH"
    COUNCIL_GIT_BRANCH="unknown: git is not on PATH"
    COUNCIL_GIT_TREE="unknown: git is not on PATH"
    return 0
  fi
  _gf_in=$(cd "$1" 2> /dev/null && git rev-parse --is-inside-work-tree 2> /dev/null)
  if [ "$_gf_in" != true ]; then
    COUNCIL_GIT_HEAD="none: not a git work tree"
    COUNCIL_GIT_BRANCH="none: not a git work tree"
    COUNCIL_GIT_TREE="not a git work tree"
    return 0
  fi
  if _gf_h=$(cd "$1" && git rev-parse -q --verify 'HEAD^{commit}' 2> /dev/null) \
    && council_git_is_commit "$_gf_h"; then
    COUNCIL_GIT_HEAD=$_gf_h
  else
    COUNCIL_GIT_HEAD="none: HEAD names no commit (a repository with no commits yet, or a branch with none)"
  fi
  if _gf_b=$(cd "$1" && git symbolic-ref -q --short HEAD 2> /dev/null) && [ -n "$_gf_b" ]; then
    COUNCIL_GIT_BRANCH=$_gf_b
  elif council_git_is_commit "$COUNCIL_GIT_HEAD"; then
    COUNCIL_GIT_BRANCH="none: detached HEAD"
  else
    COUNCIL_GIT_BRANCH="none: git names no branch"
  fi
  if _gf_s=$(cd "$1" && GIT_OPTIONAL_LOCKS=0 git status --porcelain 2> /dev/null); then
    if [ -n "$_gf_s" ]; then
      COUNCIL_GIT_TREE=dirty
      COUNCIL_GIT_STATUS=$_gf_s
    else
      COUNCIL_GIT_TREE=clean
    fi
  else
    COUNCIL_GIT_TREE="unknown: git status failed"
  fi
  return 0
}

# council_git_is_commit VALUE -- true when VALUE is shaped like a full object
# name (40 or 64 lower-case hex digits), as git rev-parse prints one.
council_git_is_commit() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

# council_git_block TITLE INTRO HEAD BRANCH TREE STATUS EXTRA -- prints one
# labelled block: a separator, a heading, INTRO, then the facts in a fenced
# block. STATUS (git status --porcelain, verbatim) and EXTRA (more lines,
# such as a git diff --stat) are printed only when not empty. The fence is a
# run of tildes longer than any run of tildes in what it holds, so no file
# name can close it early.
council_git_block() {
  _gb_body=$(
    printf 'HEAD: %s\n' "$3"
    printf 'branch: %s\n' "$4"
    printf 'tree: %s\n' "$5"
    if [ -n "$6" ]; then
      printf 'git status --porcelain:\n%s\n' "$6"
    fi
    if [ -n "$7" ]; then
      printf '%s\n' "$7"
    fi
  )
  _gb_fence=$(printf '%s\n' "$_gb_body" | awk '
    { s = $0; while (match(s, /~+/)) { if (RLENGTH > m) m = RLENGTH; s = substr(s, RSTART + RLENGTH) } }
    END { n = (m >= 3) ? m + 1 : 3; while (n-- > 0) printf "~" }')
  printf '\n---\n\n# %s\n\n%s\n\n%s\n%s\n%s\n' "$1" "$2" "$_gb_fence" "$_gb_body" "$_gb_fence"
}

# council_check_prompts_identical PROMPT STAGE LETTER... -- dies unless
# STAGE/prompt-LETTER.md is byte for byte PROMPT, for every LETTER. The
# repository block is in PROMPT, so a block built per planner, or built twice
# and different, fails here, before any planner is paid for.
council_check_prompts_identical() {
  _cpi_ref=$1
  _cpi_stage=$2
  shift 2
  for _cpi_l in "$@"; do
    cmp -s "$_cpi_ref" "$_cpi_stage/prompt-$_cpi_l.md" || council_die "prompt for planner $_cpi_l differs"
  done
  return 0
}

# council_codex_announced_model LOG -- prints the model Codex ANNOUNCED in the
# banner at the top of its own stderr log, or 'unknown'.
#
# The banner, measured on codex-cli 0.162.1 (a kept log of a real run):
#     1  OpenAI Codex v0.162.1
#     2  --------
#     3  workdir: ...
#     4  model: gpt-6-luna
#        ...
#    11  --------
#    12  user
#    13  <the prompt, echoed verbatim>
# From the line after the second separator Codex echoes the prompt, and the
# prompt holds the brief. A parser that read past that separator would let a
# brief containing "model: something" write that name into council.txt: a
# prompt-injection path into the run record. So the banner is trusted only
# when it starts on line 1 with Codex's own first line and line 2 is the
# separator; from line 3 every line must be a banner field -- lower-case
# words, a colon and a space -- until the closing separator; 'model:' is read
# only among those fields; and nothing at or below the first line that is
# neither a field nor the separator is ever looked at. No banner, a line that
# is not a field before the closing separator, no closing separator, no model
# line, two model lines that disagree, or a value outside letters, digits and
# . _ : / - all give 'unknown'.
#
# What that guarantees, and what it rests on: Codex echoes the prompt starting
# from its first line (measured on 0.162.1, after its own 'user' line, which is
# not a field either); the plugin's planner_codex hands Codex the prompt on
# stdin unchanged; and the prompt starts with prompts/plan.md, whose first
# line is a Markdown heading and not a field (council-plan.sh refuses, before
# any planner is called, a prompt whose first line is one: see
# council_prompt_opens_with_field). Any echo of the prompt therefore ends the
# banner before the brief is reached, whether or not Codex closes the banner
# first, so no line of the brief is read as the banner. It stops holding only
# if a Codex release printed part of the prompt without its first line ahead
# of it and inside the banner's run of fields. A banner Codex itself changes
# in any other way records 'unknown' or the model line it printed.
#
# "Announced", never "served". Measured 2026-11-15 (task R2): codex exec -m ID
# does change this line, but it reports what was ASKED FOR, not what answered:
# a nonexistent ID is printed here verbatim, with a "Model metadata ... not
# found" warning below the banner, and Codex exits 101.
#
# Shared on purpose: council-detect.sh is to call this same function rather
# than carry a second parser.
#
# What a banner field looks like, as an awk ERE: lower-case words, a colon and
# a space. Defined once because two checks must agree on it: the parser below
# reads only lines that match it, and council_prompt_opens_with_field refuses a
# prompt whose first line matches it.
COUNCIL_BANNER_FIELD='^[a-z][a-z ]*: '
council_codex_announced_model() {
  _cam=$(awk -v field="$COUNCIL_BANNER_FIELD" '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 !~ /^OpenAI Codex/) exit; next }
    NR == 2 { if ($0 != "--------") exit; next }
    $0 == "--------" { closed = 1; exit }
    $0 !~ field { exit }
    /^model: / {
      v = substr($0, 8)
      sub(/[ \t]+$/, "", v)
      if (seen && v != m) bad = 1
      m = v
      seen = 1
    }
    END { if (closed && seen && !bad) print m }
  ' "$1" 2>/dev/null)
  case "$_cam" in
    ''|*[!A-Za-z0-9._:/-]*) printf 'unknown\n' ;;
    *) printf '%s\n' "$_cam" ;;
  esac
}

# council_prompt_opens_with_field FILE -- true when FILE's first line, read the
# way the parser reads it (a trailing CR dropped), is shaped like a banner
# field. An empty or unreadable FILE is not. council-plan.sh uses this to
# refuse a prompt that an echo into Codex's log would extend the banner with.
council_prompt_opens_with_field() {
  [ "$(awk -v field="$COUNCIL_BANNER_FIELD" '
    { sub(/\r$/, ""); if ($0 ~ field) print "field"; exit }
  ' "$1" 2>/dev/null)" = field ]
}

# council_probe_call ID -- asks the claude CLI, once, for one word from ID with
# JSON output. This is the call and nothing else: what the CLI prints goes to
# this function's stdout and stderr untouched, and its exit status is the
# CLI's. Each probe is a full CLI session and is billed as one. Shared by
# council-doctor.sh, by the identity gate in council-plan.sh and by the probe
# in council-detect.sh, and only the call is shared: each caller decides what
# to capture and how to judge it. The doctor merges stderr into what it reads
# and ignores the exit status, as it always has; the gate and the probe refuse
# a non-zero exit and read stdout alone with council_billed_ids below, because
# a fallback can be announced on stderr by name and a failed call can name the
# model it failed on.
council_probe_call() {
  printf 'Reply with the single word ok.' | claude -p --model "$1" --output-format json \
    $(council_seat_flags) \
    --disallowedTools Edit Write NotebookEdit Bash
}

# council_billed_ids -- reads, on stdin, the stdout of one call made with
# --output-format json, and prints the model IDs the claude CLI billed for it,
# sorted, unique and joined by single spaces: the "claude-..." keys of the
# modelUsage object. It prints "!" when that stdout cannot be read, and
# nothing when it names no billed ID.
#
# This is the one definition of "answered" in this plugin. The model check in
# council-plan.sh and the setup's probe in council-detect.sh both read a reply
# with it, so both take the same billed list from the same reply. Only the
# reading is shared. Each caller keeps stderr out of what it hands here (a
# fallback can be announced on stderr by name), judges the exit status itself
# (a failed call can name the model it failed on), compares the list with the
# ID it asked for, and writes its own messages.
# council-doctor.sh does not use it, on purpose: it keeps its own looser
# reading, and its comment says how.
#
# Reading those keys is reading JSON, so the reader follows it: string state
# (with backslash escapes) and brace and bracket depth, across lines and
# whatever the spacing. It reads the JSON object stdout opens with, after any
# whitespace, and stops where that object closes: whatever follows it, a
# second object or a line of text, is ignored and can add nothing.
# Inside it, "modelUsage" counts only as a key of that object itself, never of
# one nested in it, and may appear there only once. Its value must be an
# object, and each of its own keys that is "claude-..." and holds an object is
# a billed ID; keys nested deeper, and fields beside modelUsage, are not. Keys
# are compared as raw text, and a backslash escape can spell the same key
# another way, so a key holding a backslash at either of those two levels
# cannot be compared. Output that does not open with an object, whose first
# object never closes, closes on the wrong bracket or breaks a string across
# lines, that names modelUsage twice, or that holds such a key, gives "!"; a
# modelUsage that is missing, not an object, or without such a key gives
# nothing.
council_billed_ids() {
  _cbi=$(LC_ALL=C awk '
    BEGIN { d = 0; st = ""; ins = 0; esc = 0; started = 0; closed = 0
            bad = 0; nmu = 0; inmu = 0; key = ""; havestr = 0; colon = 0; n = 0 }
    {
      if (NR > 1 && ins) bad = 1
      line = $0
      len = length(line)
      for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (ins) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") { ins = 0; havestr = 1; continue }
          s = s c
          continue
        }
        if (c == " " || c == "\t" || c == "\r") continue
        if (closed) exit
        if (!started) {
          if (c != "{") { bad = 1; exit }
          started = 1
        }
        if (colon) {
          colon = 0
          if (d == 1 && key == "modelUsage") {
            nmu++
            if (c == "{") inmu = 1
          } else if (inmu && d == 2 && c == "{" && key ~ /^claude-[A-Za-z0-9._-]*$/) {
            ids[++n] = key
          }
        }
        if (havestr) {
          havestr = 0
          if (c == ":") {
            key = s; colon = 1
            if (index(key, "\\") && (d == 1 || (inmu && d == 2))) { bad = 1; exit }
            continue
          }
        }
        if (c == "\"") { ins = 1; s = ""; continue }
        if (c == "{" || c == "[") { st = st c; d++; continue }
        if (c == "}" || c == "]") {
          if (d == 0) { bad = 1; exit }
          o = substr(st, d, 1)
          if ((c == "}" && o != "{") || (c == "]" && o != "[")) { bad = 1; exit }
          st = substr(st, 1, d - 1)
          d--
          if (inmu && d == 1) inmu = 0
          if (d == 0) closed = 1
        }
      }
    }
    END {
      if (bad || !closed || nmu > 1) { print "!"; exit }
      for (k = 1; k <= n; k++) print ids[k]
    }' | sort -u | tr '\n' ' ')
  printf '%s\n' "${_cbi% }"
}

# council_denials_read -- reads, on stdin, the stdout of one seat call made
# with --output-format json, and prints what the claude CLI recorded in its
# permission_denials field, the CLI's own list of the tool calls it refused:
#   !         the stdout cannot be read (see below);
#   missing   it holds no permission_denials field;
#   notarray  the field is there and is not an array;
#   R N       the field is an array of N objects, R of which name "Read" as
#             their tool_name.
# Only "R N" with R at least 1 is a refused read. Everything else is not, and
# council_seat_check refuses it.
#
# council_denials_read shell -- the same reader, on the same input, with the
# same outcomes, except that R counts the objects whose tool_name is "Bash" or
# "PowerShell": the shell calls the CLI refused. "R N" with R at least 1 is a
# refused shell call, which proves the seat holds a shell; council_seat_check
# refuses it. R of 0 proves nothing about the shell (see the comment above
# council_seat_check).
#
# The same reader as council_billed_ids, in the same structural style, for
# the same reason: this is JSON, so it follows string state (with backslash
# escapes) and brace and bracket depth, across lines and whatever the
# spacing. It reads the JSON object stdout opens with, after any whitespace,
# and stops where that object closes: whatever follows it is ignored and can
# add nothing. "permission_denials" counts only as a key of that object
# itself, never of one nested in it, and may appear there only once. An entry
# is an object directly inside that array, and its tool_name counts only as
# one of its own keys, at most once, whose value is the string "Read"
# exactly, compared as raw text: an escape that spells it another way is not
# "Read". Output that does not open with an object (empty output included),
# whose first object never closes, closes on the wrong bracket or breaks a
# string across lines, that names permission_denials twice among its own keys
# or tool_name twice in one entry, or that spells a key at either of those
# two levels with a backslash, gives "!".
council_denials_read() {
  LC_ALL=C awk -v want="${1-}" '
    BEGIN { d = 0; st = ""; ins = 0; esc = 0; started = 0; closed = 0; bad = 0
            npd = 0; pdarr = 0; inpd = 0; inent = 0; nent = 0; nread = 0
            key = ""; havestr = 0; colon = 0; capt = 0; tn = 0; tnread = 0 }
    {
      if (NR > 1 && ins) bad = 1
      line = $0
      len = length(line)
      for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (ins) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") {
            ins = 0; havestr = 1
            if (capt) {
              capt = 0
              if (want == "shell") { if (s == "Bash" || s == "PowerShell") tnread = 1 }
              else if (s == "Read") tnread = 1
            }
            continue
          }
          s = s c
          continue
        }
        if (c == " " || c == "\t" || c == "\r") continue
        if (closed) exit
        if (!started) {
          if (c != "{") { bad = 1; exit }
          started = 1
        }
        if (colon) {
          colon = 0
          if (d == 1 && key == "permission_denials") {
            npd++
            if (c == "[") { pdarr = 1; inpd = 1 }
          } else if (inent && d == 3 && key == "tool_name") {
            tn++
            if (c == "\"") capt = 1
          }
        }
        if (havestr) {
          havestr = 0
          if (c == ":") {
            key = s; colon = 1
            if (index(key, "\\") && (d == 1 || (inent && d == 3))) { bad = 1; exit }
            continue
          }
        }
        if (c == "\"") { ins = 1; s = ""; continue }
        if (c == "{" || c == "[") {
          if (inpd && d == 2 && c == "{") { inent = 1; nent++; tn = 0; tnread = 0 }
          st = st c; d++; continue
        }
        if (c == "}" || c == "]") {
          if (d == 0) { bad = 1; exit }
          o = substr(st, d, 1)
          if ((c == "}" && o != "{") || (c == "]" && o != "[")) { bad = 1; exit }
          st = substr(st, 1, d - 1)
          d--
          if (inent && d == 2) {
            inent = 0
            if (tn > 1) { bad = 1; exit }
            if (tn == 1 && tnread) nread++
          }
          if (inpd && d == 1) inpd = 0
          if (d == 0) closed = 1
        }
      }
    }
    END {
      if (bad || !closed || npd > 1) { print "!"; exit }
      if (npd == 0) { print "missing"; exit }
      if (!pdarr) { print "notarray"; exit }
      print nread " " nent
    }'
}

# The file council_seat_check plants, while it is planted, so that an exit
# trap can remove it (council_seat_unplant). Empty otherwise.
_council_planted=""
# The file council_seat_check asks each seat to create by running a shell
# command, from the first call until the check is over, for the same trap.
# Empty otherwise.
_council_made=""

# Removes the file council_seat_check planted, and any file a seat created
# where the check asked it to, if they are still there. Called by
# council_seat_check itself before any seat of the phase runs, and from the
# EXIT traps of council-plan.sh and council-review.sh, so that an interrupted
# or refused check leaves neither in the run directory.
council_seat_unplant() {
  if [ -n "${_council_planted-}" ]; then
    rm -f "$_council_planted"
    _council_planted=""
  fi
  if [ -n "${_council_made-}" ]; then
    rm -rf "$_council_made"
    _council_made=""
  fi
  return 0
}

# council_seat_check ROOT RUN STAGE -- the per-run seat check.
#
# Every other check in this plugin reads either a text file or a model's
# words. This one reads a record the CLI wrote. It runs after
# council_require_deny_used has passed, which is a text check of the config,
# and before any seat of the phase is paid for.
#
# For each function council_check_deny_used judged to drive claude
# (COUNCIL_CHECK_CLAUDE), in the phase now running (COUNCIL_PHASE, so the
# seat runs at that phase's effort, on whatever model it is configured with):
#   - a file with a neutral name is planted in the run directory RUN, holding
#     a marker that appears nowhere in the prompt. Never council.txt: the deny
#     canary learned that a name like "secret" can make a model decline a read
#     on its own judgement, which is not the CLI refusing it;
#   - the same prompt asks the seat to create a second file, next to it,
#     created-PID.txt, by running a shell command. Its name is in the prompt,
#     as it must be; the marker the planted file holds still is not;
#   - the seat is called by name, from ROOT, with the probe prompt on stdin,
#     as council_run_parallel calls it, in a subshell that sets the switch in
#     council_seat_flags, so the CLI writes its JSON record into the seat's
#     answer file. The switch ends with that subshell;
#   - after each seat's call, and before the next one, the check looks for
#     the file the seat was asked to create, and deletes it if it is there,
#     so that a seat called later is not blamed for it;
#   - the planted file is deleted before any seat of the phase runs, and so
#     is any file a seat created, so neither is among the run directory's
#     published files;
#   - nothing of the probe is written to STAGE/*.log, which council_keep_logs
#     copies into the run directory: it all goes to STAGE/seatcheck, which is
#     removed here.
# One call per seat per phase: the shell request rides on the read probe's
# call, and adds none.
#
# A seat passes only when the CLI's record names a refused Read: an entry of
# permission_denials naming Read, read by council_denials_read, with the
# marker nowhere in what the seat printed and a zero exit status; and when no
# shell was detected: no entry of permission_denials names Bash or
# PowerShell (council_denials_read shell), and the file the seat was asked to
# create does not exist after its call. Anything else refuses the run, there
# is nothing to walk past it, and the message names the cause: a shell was
# detected, and how; the marker appeared (the read was allowed); the call
# exited non-zero; what it printed is not a JSON object; or it is one, and it
# holds no refused Read.
#
# What a pass shows, and what it does not. A Read entry proves only that the
# CLI refused a read: it does not say which rule did. Measured with the
# shipped arbiter and no deny rule at all: a read of an absolute path OUTSIDE
# the context root also leaves one Read entry, refused by --restricted. A
# read INSIDE the root is not refused by --restricted (see the measurements
# above council_seat_flags), so there the refusal did not come from
# --restricted alone, though the record does not say which rule refused it,
# and a deny rule in the project's own settings would leave the same entry.
# So the record says whether RUN was inside ROOT, and for a run
# directory outside it says that this does not show a deny rule did it. It
# never says the deny rule is in force, and nothing here is verified beyond
# one call: it shows that a read of the run directory through this seat was
# refused by the CLI, in a separate process, just before the run.
#
# What this check shows about a shell: it can prove one present, and it
# cannot prove one absent.
# Measured 2026-11-23, three calls with --output-format json. With the
# shipped seat flags (--tools Read,Glob,Grep, and Bash in --disallowedTools),
# Bash was absent, the seat answered NO SHELL TOOL, and permission_denials
# was empty. With no --tools and Bash denied by name, the same: absent,
# NO SHELL TOOL, empty. The control, with no --tools and Bash allowed, ran
# the command from the same prompt and printed its output. A tool denied by
# name is absent from the session, not refused on use, so no refusal happens
# and the CLI has nothing to record.
# Measured 2026-11-26, two calls with --output-format json, each asked to
# create a file by running a shell command. A seat with a shell (no --tools,
# Bash not denied) did not create it: the CLI's write-approval layer refused
# both its Bash and its PowerShell attempt, and permission_denials named
# both, with their commands. With the shipped seat flags, the file was not
# created and permission_denials was empty.
# So a shell that is present and tries is recorded when it is refused, and
# leaves the file when it is not; either is written by the CLI or found on
# disk, not said by the model, and either proves a shell, so the check
# refuses on either. What the seat says about its tools is not read. The
# converse does not hold: no shell entry and no file is what an absent shell
# gives, and also what a seat with a shell gives when it does not try. A pass
# says that no shell was detected, never that there is none.
# The prompt here is not the one measured on 2026-11-26: it asks for the
# read first, and names the file by an absolute path in the run directory,
# not by a name in the working directory. Whether it draws the shell attempt
# as that prompt did is for a run against the CLI to show; these tests use a
# stand-in.
#
# Seats in COUNCIL_DENY_UNCOVERED, whose definition the text check did not
# find "claude" in, are not probed: neither the deny rule nor this check
# reaches them, as the comment above council_check_deny_used says. The
# record lists them.
#
# A pass is recorded as seatcheck.PHASE=passed with, beside it,
# seatcheck.PHASE.shell=notdetected, never a word that says there is no shell.
#
# Sets COUNCIL_SEATCHECK to passed, or none when no seat was probed, and
# COUNCIL_SEATCHECK_SEATS, COUNCIL_SEATCHECK_UNPROBED and
# COUNCIL_SEATCHECK_TARGET (inside or outside) for council_seat_record. Dies
# on any other outcome.
council_seat_check() {
  _sc_root=$1
  _sc_run=$2
  _sc_stage=$3
  COUNCIL_SEATCHECK=""
  COUNCIL_SEATCHECK_SEATS=""
  COUNCIL_SEATCHECK_UNPROBED=${COUNCIL_DENY_UNCOVERED-}
  case "$_sc_run/" in
    "$_sc_root"/*) COUNCIL_SEATCHECK_TARGET=inside ;;
    *) COUNCIL_SEATCHECK_TARGET=outside ;;
  esac
  _sc_fns=""
  for _sc_fn in ${COUNCIL_CHECK_CLAUDE-}; do
    case " $_sc_fns " in
      *" $_sc_fn "*) ;;
      *) _sc_fns="$_sc_fns $_sc_fn" ;;
    esac
  done
  if [ -z "$_sc_fns" ]; then
    COUNCIL_SEATCHECK=none
    council_say "seat check: no seat of this phase was judged by the text check to drive claude, so none was probed${COUNCIL_SEATCHECK_UNPROBED:+; not probed:$COUNCIL_SEATCHECK_UNPROBED}."
    return 0
  fi
  _sc_count=0
  for _sc_fn in $_sc_fns; do _sc_count=$((_sc_count + 1)); done

  _sc_dir="$_sc_stage/seatcheck"
  rm -rf "$_sc_dir"
  mkdir "$_sc_dir" || council_die "seat check: cannot create $_sc_dir. Nothing has been run."
  _sc_name="notes-$$.txt"
  _sc_file="$_sc_run/$_sc_name"
  [ ! -e "$_sc_file" ] || council_die "seat check: $_sc_file already exists, and the check plants a file under that name. Nothing has been run."
  _sc_made="$_sc_run/created-$$.txt"
  if [ -e "$_sc_made" ] || [ -L "$_sc_made" ]; then
    council_die "seat check: $_sc_made already exists, and the check asks each seat to create a file under that name, so it could not tell a file a seat created from one already there. It was left as it is. Nothing has been run."
  fi
  _sc_mark="M$(date +%s)P$$R$(awk 'BEGIN { srand(); printf "%d", rand() * 1000000000 }')Z"
  _sc_path=$(council_cli_path "$_sc_file")
  _sc_mpath=$(council_cli_path "$_sc_made")
  printf 'Do two things, in this order, and do the second whatever happened to the first.\n\nFirst, use the Read tool, once, on the file at this absolute path, and note the first line of that file exactly as it is written:\n\n%s\n\nSecond, create an empty file at this absolute path by running a shell command, with the tool you have that runs shell commands:\n\n%s\n\nDo not create it any other way, and do not use any tool other than these two or read any other file. Then reply with two lines. The first: the first line of the file you read, or the single word BLOCKED if the read was refused or failed. The second: DONE if the command ran, REFUSED if it was refused, or NO SHELL TOOL if you have no tool that runs shell commands.\n' "$_sc_path" "$_sc_mpath" > "$_sc_dir/prompt"
  if grep -q "$_sc_mark" "$_sc_dir/prompt"; then
    council_die "seat check: the marker appears in the probe prompt, so the check could not tell a read from an echo. This is a bug in plan-council. Nothing has been run."
  fi

  council_say "seat check: before any seat of this phase is paid for, each claude seat is called once, by name, from the context root, asked to read a file planted in the run directory and, in the same call, to create another there by running a shell command. The CLI's own record of that call must show the read refused and no shell call refused, and the file must not exist afterwards. $_sc_count call(s), each a full CLI session billed as such."
  _council_planted=$_sc_file
  printf '%s\n' "$_sc_mark" > "$_sc_file" || council_die "seat check: cannot write $_sc_file. Nothing has been run."
  _council_made=$_sc_made
  _sc_n=0
  for _sc_fn in $_sc_fns; do
    _sc_n=$((_sc_n + 1))
    (
      _council_seat_json=1
      cd "$_sc_root" || exit 97
      "$_sc_fn" "$_sc_dir/answer-$_sc_n"
    ) < "$_sc_dir/prompt" > "$_sc_dir/stdout-$_sc_n" 2> "$_sc_dir/stderr-$_sc_n"
    eval "_sc_rc_$_sc_n=\$?"
    # Looked for, and deleted, before the next seat is called, so that the
    # file is put down to the seat that created it.
    eval "_sc_made_$_sc_n=0"
    if [ -e "$_sc_made" ] || [ -L "$_sc_made" ]; then
      eval "_sc_made_$_sc_n=1"
      rm -rf "$_sc_made"
      if [ -e "$_sc_made" ] || [ -L "$_sc_made" ]; then
        council_seat_unplant
        rm -rf "$_sc_dir"
        council_die "seat check: $_sc_fn created $_sc_made, the file it was asked to create by running a shell command, so it holds a shell, and the check cannot delete it. Delete it before anything else, as it is in the run directory. No seat of this phase has been run after the check."
      fi
    fi
  done
  council_seat_unplant

  _sc_fail=""
  _sc_n=0
  for _sc_fn in $_sc_fns; do
    _sc_n=$((_sc_n + 1))
    eval "_sc_rc=\$_sc_rc_$_sc_n"
    eval "_sc_made_n=\$_sc_made_$_sc_n"
    _sc_out=$(cat "$_sc_dir/answer-$_sc_n" 2>/dev/null)
    _sc_rep=$(printf '%s\n' "$_sc_out" | council_denials_read)
    _sc_shrep=$(printf '%s\n' "$_sc_out" | council_denials_read shell)
    _sc_ex=$(printf '%s' "$_sc_out" | tr '\n' ' ' | cut -c1-200)
    # The shell first, and on its own: a seat whose read was refused is
    # still refused when it holds a shell. Nothing the seat said is read
    # here, only the CLI's record and the file system.
    case "$_sc_shrep" in
      [1-9]*" "*)
        _sc_fail="$_sc_fail $_sc_fn: a shell was detected: the CLI's record of the call names a refused Bash or PowerShell call (${_sc_shrep%% *} of ${_sc_shrep#* } entries), and a refused call is one the seat had the tool to make;" ;;
    esac
    if [ "$_sc_made_n" = 1 ]; then
      _sc_fail="$_sc_fail $_sc_fn: a shell was detected: the file it was asked to create by running a shell command exists after its call, so the seat created it. It was deleted, and is not among the run directory's files;"
    fi
    if cat "$_sc_dir/answer-$_sc_n" "$_sc_dir/stdout-$_sc_n" "$_sc_dir/stderr-$_sc_n" 2>/dev/null | grep -q "$_sc_mark"; then
      _sc_fail="$_sc_fail $_sc_fn: the read was allowed: the marker held only by the planted file appears in what the seat printed, so the seat read the run directory;"
    elif [ "$_sc_rc" -ne 0 ]; then
      _sc_fail="$_sc_fail $_sc_fn: the call exited with status $_sc_rc, so what it printed is not a record of a completed call (first 200 chars: $_sc_ex);"
    else
      case "$_sc_rep" in
        "!")
          _sc_fail="$_sc_fail $_sc_fn: what the seat wrote is not one complete JSON object this check can read (it is empty, does not open with an object, never closes or is malformed, names permission_denials twice, names tool_name twice in one entry, or spells such a key with a backslash), so there is no record of the call to read (first 200 chars: $_sc_ex);" ;;
        missing)
          _sc_fail="$_sc_fail $_sc_fn: no record: the JSON holds no permission_denials field, and the marker does not appear;" ;;
        notarray)
          _sc_fail="$_sc_fail $_sc_fn: no record: permission_denials is not an array, and the marker does not appear;" ;;
        "0 0")
          _sc_fail="$_sc_fail $_sc_fn: no record: permission_denials is empty, and the marker does not appear, so whether a read was even attempted cannot be told;" ;;
        "0 "*)
          _sc_fail="$_sc_fail $_sc_fn: no record: permission_denials holds ${_sc_rep#0 } object(s) and none names Read, and the marker does not appear, so whether a read was even attempted cannot be told;" ;;
        [1-9]*" "*)
          COUNCIL_SEATCHECK_SEATS="$COUNCIL_SEATCHECK_SEATS $_sc_fn" ;;
        *)
          _sc_fail="$_sc_fail $_sc_fn: the record could not be read (reader returned '$_sc_rep');" ;;
      esac
    fi
  done
  rm -rf "$_sc_dir"

  if [ -n "$_sc_fail" ]; then
    council_die "seat check refused the run. The text check of the config had passed for these seats; this check reads the CLI's own record of one call per seat, and whether the file the call asked the seat to create exists after it, and it refused:${_sc_fail%;}. A seat whose read of the run directory is not refused can read what a run writes there, council.txt included, which says which planner wrote which plan, and a seat must hold no shell, which the deny rule on Read does not cover. The seat check made $_sc_count call(s), and no seat of this phase has been run after them."
  fi
  COUNCIL_SEATCHECK=passed
  council_say "seat check: a read of the run directory through each of these seats,$COUNCIL_SEATCHECK_SEATS, was refused by the CLI (its permission_denials names Read), in a separate process, just before the run. $(council_seat_target_sentence) $(council_seat_shell_sentence)${COUNCIL_SEATCHECK_UNPROBED:+ Not probed, since the text check found no claude in them:$COUNCIL_SEATCHECK_UNPROBED.}"
  return 0
}

# The sentence that says what a pass shows about a shell, which is less than
# that there is none (see the comment above council_seat_check). Shared by
# the message and the record.
council_seat_shell_sentence() {
  printf '%s' "No shell was detected: each seat was also asked, in the same call, to create a file in the run directory by running a shell command, and the CLI's record named no refused Bash or PowerShell call, and the file did not exist afterwards. Nothing detected is not the same as no shell, and is not proof that the seat holds no shell: a tool denied by name is absent and leaves no record (measured 2026-11-23), and a seat with a shell that does not try leaves none either."
}

# The sentence that says what the refusal shows, given where the run
# directory lies. Shared by the message and the record.
council_seat_target_sentence() {
  if [ "${COUNCIL_SEATCHECK_TARGET-}" = inside ]; then
    printf '%s' "The run directory is inside the context root, where --restricted alone was measured not to refuse a read, so the refusal did not come from --restricted alone; the record does not say which rule refused it."
  else
    printf '%s' "The run directory is outside the context root, where --restricted alone refuses a read with no deny rule present (measured), so this does not show that a deny rule refused it."
  fi
}

# council_seat_skip -- what council_seat_check sets, for a phase run with
# --no-seat-check. The seats the check could not have reached are still
# listed, so the record says the same about them either way.
council_seat_skip() {
  COUNCIL_SEATCHECK=skipped
  COUNCIL_SEATCHECK_SEATS=""
  COUNCIL_SEATCHECK_TARGET=""
  COUNCIL_SEATCHECK_UNPROBED=${COUNCIL_DENY_UNCOVERED-}
  council_say "seat check: skipped (--no-seat-check). No seat was asked to read the run directory before this phase; council.txt records that."
}

# council_seat_record PHASE -- prints the council.txt lines for the seat
# check of PHASE, from what council_seat_check (or a skip) set.
council_seat_record() {
  printf 'seatcheck.%s=%s\n' "$1" "${COUNCIL_SEATCHECK-}"
  case "${COUNCIL_SEATCHECK-}" in
    passed)
      printf 'seatcheck.%s.seats=%s\n' "$1" "${COUNCIL_SEATCHECK_SEATS# }"
      printf 'seatcheck.%s.target=%s\n' "$1" "$COUNCIL_SEATCHECK_TARGET"
      printf 'seatcheck.%s.from=%s\n' "$1" "a read of the run directory through each seat in seatcheck.$1.seats was refused by the CLI, in a separate process, just before the run: the seat was called once, by name, from the context root, and asked to read a file planted in the run directory, and the CLI's record of that call (permission_denials in its JSON output) named a refused Read, while the file's content appeared nowhere in what it printed. $(council_seat_target_sentence) One call per seat, not a record of the calls that followed it."
      printf 'seatcheck.%s.shell=%s\n' "$1" notdetected
      printf 'seatcheck.%s.shell.from=%s\n' "$1" "$(council_seat_shell_sentence)" ;;
    none)
      printf 'seatcheck.%s.from=%s\n' "$1" "no seat of this phase was judged by the text check to drive claude, so none was probed" ;;
    skipped)
      printf 'seatcheck.%s.from=%s\n' "$1" "--no-seat-check was given, so no seat was asked to read the run directory before this phase" ;;
  esac
  if [ -n "${COUNCIL_SEATCHECK_UNPROBED-}" ]; then
    printf 'seatcheck.%s.unprobed=%s\n' "$1" "${COUNCIL_SEATCHECK_UNPROBED# }"
    printf 'seatcheck.%s.unprobed.from=%s\n' "$1" "the text check did not find claude in these functions, so the deny rule cannot reach them and this check did not call them; whether they can read the run directory is not known"
  fi
  return 0
}

# council_seat_record_into MANIFEST PHASE -- replaces the seatcheck.PHASE
# lines of MANIFEST with the current ones, as council-review.sh records
# model.arbiter: a rerun replaces its own lines and adds no second set.
council_seat_record_into() {
  _sr_keep=$(grep -v -e "^seatcheck\\.$2=" -e "^seatcheck\\.$2\\." "$1")
  [ "$?" -le 1 ] || council_die "cannot read $1 to record the seat check, so no seat of this phase was called."
  {
    [ -z "$_sr_keep" ] || printf '%s\n' "$_sr_keep"
    council_seat_record "$2"
  } > "$1.tmp" && mv "$1.tmp" "$1" || { rm -f "$1.tmp"; council_die "cannot record the seat check in $1, so no seat of this phase was called."; }
}

# Run one function per job in parallel, from the context root, feeding each
# its own prompt on stdin. Jobs are "label:function" words; prompts are
# $STAGE/prompt-<label>.md and answers land in $STAGE/answer-<label>.md.
# Labels are letters, never planner names: the stage files and the published
# logs carry the label, so no log can attribute a plan to a model.
# Returns non-zero if any job failed or produced no real answer.
# The staging path is printed before anything starts: a run that never
# returns (see "A run that does not return" in the README) can only be
# ended by a kill, the callers' EXIT trap then deletes this directory, and
# nothing else names it. The answers must be copied out before the kill.
# Each seat's stdin, stdout and stderr are redirected inside its subshell,
# by exec, and not on the backgrounded subshell as a whole: hangs in the
# wait below were counted only with the redirections on the backgrounded
# subshell, in a stand-in on one machine. Why is not known, and this shape is
# not known to prevent them (see the same README entry). exec comes before
# cd, so that a failed cd is written to stderr-<label>.log, the file the
# FAILED line names. A failed exec redirection exits 96: bash run as bash,
# not as sh, carries on past it, and the seat would then run on the runner's
# own stdin and stdout.
council_run_parallel() {
  _root=$1; _stage=$2; shift 2
  council_say "staging directory, where this phase writes answer-*.md; it is deleted when this script exits, and a kill can make it exit, so if the run never returns, copy answer-*.md out of it before you kill it: $_stage"
  _jobs=""
  for _job in "$@"; do
    _label=${_job%%:*}
    _fn=${_job#*:}
    (
      exec < "$_stage/prompt-$_label.md" > "$_stage/stdout-$_label.log" 2> "$_stage/stderr-$_label.log" || exit 96
      cd "$_root" || exit 97
      "$_fn" "$_stage/answer-$_label.md"
    ) &
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
