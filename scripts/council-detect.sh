#!/bin/sh
# What plan-council can actually see on this machine: the shell it must be run
# from, the planner CLIs, which models answer, the agent roster, and whether
# the blindness rule is honoured here. Nothing below is assumed -- every line
# is the result of running something.
#
# This exists because a fresh install cannot know any of it. Which Claude
# models an account has, and whether Codex is connected, differ per user, and
# guessing produces a council that runs on a model the user did not choose.
#
# Usage: council-detect.sh [--root DIR] [--no-model-check]
#   --root DIR        the context root whose config to report. Default: .
#   --no-model-check  skip every live call (no spend, but then the model and
#                     guard answers are "unknown", never "fine")
#
# The last section is a machine-readable summary, one KEY=value per line, for
# /council-setup to read.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
PLUGIN_ROOT=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '2,18p' "$SCRIPT_DIR/council-detect.sh" | sed 's/^# \{0,1\}//'; }

# --- Deny canary helpers ------------------------------------------------------
#
# The canary must probe what the review seats can actually do, so the tool list
# it hands its child is read from the arbiter() function itself and never
# copied here: a second copy drifts from the first, and the drift is silent.

# canary_arbiter_tools CONFIG -> the --allowedTools entries of arbiter() in
# CONFIG, one per line. When they cannot be read, one line "!<why>" and
# status 1: the caller reports "untested", never "ok", and never falls back
# to a list of its own.
canary_arbiter_tools() {
  if [ ! -f "$1" ]; then
    printf '!%s\n' "the config $1 was not found"
    return 1
  fi
  _cat_body=$(council_function_body arbiter "$1")
  if [ -z "$_cat_body" ]; then
    printf '!%s\n' "no arbiter() function was found in $1, or the one found could not be read to its end"
    return 1
  fi
  # council_function_body returns the first definition; the shell runs the
  # last. With more than one, the list read here may not be the one in use.
  if [ "$(tr -d '\r' < "$1" | grep -c '^arbiter()')" -ne 1 ]; then
    printf '!%s\n' "arbiter() is defined more than once in $1, and the parser reads only the first"
    return 1
  fi
  printf '%s\n' "$_cat_body" | tr -d '\r' | awk '
    function push(t, kind) { nt++; tok[nt] = t; qt[nt] = kind }
    function flush() { if (have) push(cur, wasq); cur = ""; have = 0; wasq = 0 }
    function bad(why) { print "!" why; failed = 1; exit 1 }
    # A line ending in a backslash continues the command; any other line
    # ends it.
    {
      line = $0
      if (sub(/\\$/, "", line)) all = all line " "
      else all = all line "\n"
    }
    END {
      if (failed) exit 1
      sq = sprintf("%c", 39); dq = sprintf("%c", 34); bq = sprintf("%c", 96)
      nt = 0; cur = ""; have = 0; wasq = 0; mode = ""
      n = length(all)
      # Split into shell words, honouring both kinds of quote. Kind 0 is an
      # unquoted word, 1 a word with quoting in it, 2 the end of a command.
      for (i = 1; i <= n; i++) {
        c = substr(all, i, 1)
        if (mode == dq) {
          if (c == dq) mode = ""
          else if (c == "\\") { i++; cur = cur substr(all, i, 1) }
          else cur = cur c
          continue
        }
        if (mode == sq) {
          if (c == sq) mode = ""
          else cur = cur c
          continue
        }
        if (c == dq || c == sq) { mode = c; have = 1; wasq = 1; continue }
        if (c == " " || c == "\t") { flush(); continue }
        if (c == ">" || c == "<") {
          # A redirection such as 2>/dev/null: its descriptor number is part
          # of the redirection, not a word of the command. A redirection does
          # not end the command, so it gets a kind of its own (3); one met
          # while the list is open is refused below rather than guessed at.
          if (have && !wasq && cur ~ /^[0-9]+$/) { cur = ""; have = 0 }
          flush(); push("", 3); continue
        }
        if (c == "\n" || c == ";" || c == "|" || c == "&") {
          flush(); push("", 2); continue
        }
        if (c == "#" && !have) {
          while (i <= n && substr(all, i, 1) != "\n") i++
          i--
          continue
        }
        if (c == "\\") { i++; cur = cur substr(all, i, 1); have = 1; continue }
        cur = cur c; have = 1
      }
      flush()
      occ = 0; on = 0; cnt = 0
      for (k = 1; k <= nt; k++) {
        t = tok[k]
        if (qt[k] == 0 && (t == "--allowedTools" || t == "--allowed-tools")) { occ++; on = 1; continue }
        if (qt[k] == 0 && (index(t, "--allowedTools=") == 1 || index(t, "--allowed-tools=") == 1))
          bad("arbiter() gives the list as " t ", a form this parser does not read")
        if (!on) continue
        if (qt[k] == 3)
          bad("a redirection sits inside the --allowedTools list of arbiter(), and where that list ends is not read here")
        if (qt[k] == 2 || (qt[k] == 0 && substr(t, 1, 1) == "-")) { on = 0; continue }
        if (index(t, "$") || index(t, bq))
          bad("the --allowedTools list of arbiter() contains " t ", which has no value until run time")
        # One word may carry several entries, separated by commas or spaces
        # outside parentheses, as the CLI accepts.
        depth = 0; item = ""
        for (j = 1; j <= length(t); j++) {
          c = substr(t, j, 1)
          if (c == "(") depth++
          if (c == ")" && depth > 0) depth--
          if (depth == 0 && (c == "," || c == " ")) {
            if (item != "") list[++cnt] = item
            item = ""
            continue
          }
          item = item c
        }
        if (item != "") list[++cnt] = item
      }
      if (occ == 0) bad("arbiter() passes no --allowedTools")
      if (occ > 1) bad("arbiter() passes --allowedTools more than once, and which one wins is not known here")
      if (cnt == 0) bad("the --allowedTools list of arbiter() is empty")
      for (k = 1; k <= cnt; k++) print list[k]
    }
  '
}

# canary_route TOOL -> "SCOPE<TAB>PROBE": how the child is told to reach the
# planted file with TOOL. SCOPE is "file" when the probe names the file and
# "dir" when it names only the directory; only a "dir" probe can leak by
# naming a file, because it was told no file name to echo back, while a "file"
# probe was handed one. The name that counts as a leak is never the probed
# file: it is the second planted file, whose name appears nowhere in the
# prompt, so that a child parroting what it was given cannot be read as
# having reached anything. In PROBE, @ROOT@ is
# the child's working directory as an absolute path, @DIR@ the directory
# relative to it, and @FILE@ the file relative to it. A command this function
# does not know is still probed, with the file path as its argument, so a tool
# added to arbiter() later is tested without anyone remembering to.
canary_route() {
  case "$1" in
    Read) printf 'file\tRead tool, file_path: @ROOT@/@FILE@\n' ;;
    Glob) printf 'dir\tGlob tool, path: @ROOT@, pattern: @DIR@/*\n' ;;
    Grep) printf 'dir\tGrep tool, path: @ROOT@, glob: @DIR@/*, pattern: COUNCIL, output_mode: content\n' ;;
    Bash) printf 'file\tBash tool, command: cat @FILE@\n' ;;
    'Bash('*')')
      _cr_cmd=${1#Bash(}
      _cr_cmd=${_cr_cmd%)}
      _cr_cmd=${_cr_cmd%:\*}
      _cr_cmd=${_cr_cmd% \*}
      _cr_cmd=${_cr_cmd%\*}
      case "$_cr_cmd" in
        ls) printf 'dir\tBash tool, command: ls -l @DIR@\n' ;;
        wc) printf 'file\tBash tool, command: wc -c @FILE@\n' ;;
        'git diff') printf 'file\tBash tool, command: git diff -- @FILE@\n' ;;
        'git log') printf 'file\tBash tool, command: git log -p -- @FILE@\n' ;;
        'git show') printf 'file\tBash tool, command: git show HEAD -- @FILE@\n' ;;
        'git status') printf 'dir\tBash tool, command: git status --short -- @DIR@\n' ;;
        *) printf 'file\tBash tool, command: %s @FILE@\n' "$_cr_cmd" ;;
      esac
      ;;
    *) printf 'file\t%s tool, on the path @ROOT@/@FILE@\n' "$1" ;;
  esac
}

# canary_subst TEXT PLACEHOLDER VALUE -> TEXT with every PLACEHOLDER replaced
# by VALUE, taken literally (a path can hold characters sed would read).
canary_subst() {
  _cs_s=$1
  _cs_out=""
  while :; do
    case "$_cs_s" in
      *"$2"*) _cs_out="$_cs_out${_cs_s%%"$2"*}$3"; _cs_s=${_cs_s#*"$2"} ;;
      *) break ;;
    esac
  done
  printf '%s' "$_cs_out$_cs_s"
}

# canary_section REPLY ID [loose] -> the text the child reported for probe
# ID; status 1 when there is no such report.
#
# The canary's verdict rests on parsing what a model wrote, and a model's
# output is exactly what this plugin elsewhere refuses to read as fact. So
# the strict form, which every "reached" and "blocked" rests on, accepts a
# report only when it is well formed: one BEGIN line for the ID and one END
# line closing it, with no other BEGIN or END between. Anything else is no
# report, which leads to "untested". An earlier version printed from BEGIN
# to the end of the reply when the END line was missing, so a later probe's
# text could be read as this one's and a failed control as reached.
# Ending at the next BEGIN instead would still trust a reply already shown
# to be malformed; treating it as no report fails closed.
#
# The loose form is for disclosures only, which count whatever the shape of
# the reply: it returns every stretch of text that follows a BEGIN line for
# the ID, up to the next BEGIN or END line of any ID.
canary_section() {
  printf '%s\n' "$1" | tr -d '\r' | awk -v id="$2" -v loose="${3:-}" '
    BEGIN { b = "=== BEGIN " id " ==="; e = "=== END " id " ===" }
    loose != "" {
      if (index($0, "=== BEGIN ") || index($0, "=== END ")) {
        on = (index($0, b) > 0)
        if (on) seen = 1
        next
      }
      if (on) print
      next
    }
    index($0, b) { opens++; if (on) broken = 1; on = 1; next }
    index($0, e) { ends++; if (!on) broken = 1; on = 0; next }
    on && (index($0, "=== BEGIN ") || index($0, "=== END ")) { broken = 1; on = 0; next }
    on { body = body $0 "\n" }
    END {
      if (loose != "") exit seen ? 0 : 1
      if (opens != 1 || ends != 1 || broken || on) exit 1
      printf "%s", body
      exit 0
    }
  '
}

# canary_hit TEXT MARKER SIZE NAME -> what in TEXT shows the planted file was
# reached: its marker word, its byte count as a number of its own, or, when
# NAME is not empty, its name. Status 1 when none of them is there.
canary_hit() {
  _ch_why=""
  case "$1" in *"$2"*) _ch_why="the canary word" ;; esac
  if canary_number_in "$1" "$3"; then
    _ch_why="${_ch_why:+$_ch_why, }its byte count $3"
  fi
  if [ -n "$4" ]; then
    case "$1" in *"$4"*) _ch_why="${_ch_why:+$_ch_why, }the name $4" ;; esac
  fi
  [ -n "$_ch_why" ] || return 1
  printf '%s\n' "$_ch_why"
}

# canary_control_ok REPLY CONTROL_ID SCOPE -> status 0 when the control was
# reached, 1 when it was reported and not reached, 2 when no well-formed
# report came back for it. Reads CANARY_CMARK, CANARY_CSIZE and CANARY_CLNAME.
canary_control_ok() {
  _cc_n=""
  [ "$3" = dir ] && _cc_n=$CANARY_CLNAME
  _cc_c=$(canary_section "$1" "$2") || return 2
  canary_hit "$_cc_c" "$CANARY_CMARK" "$CANARY_CSIZE" "$_cc_n" > /dev/null || return 1
  return 0
}

# canary_judge REPLY CONTROL_ID DENIED_ID SCOPE -> "blocked", "LEAKS <what>"
# or "untested <why>". The control decides whether the denied probe says
# anything: a refusal of a probe whose control also failed may only mean the
# route never worked, and that is not evidence of a rule. Reads CANARY_CMARK,
# CANARY_CSIZE, CANARY_CLNAME and the CANARY_D* equivalents.
canary_judge() {
  _cj_dn=""
  [ "$4" = dir ] && _cj_dn=$CANARY_DLNAME
  canary_control_ok "$1" "$2" "$4"
  case $? in
    2)
      echo "untested no well-formed report came back for the control probe"
      return 0
      ;;
    1)
      echo "untested the control outside the denied directory was not reached either"
      return 0
      ;;
  esac
  if ! _cj_d=$(canary_section "$1" "$3"); then
    echo "untested no well-formed report came back for the denied probe"
    return 0
  fi
  if _cj_w=$(canary_hit "$_cj_d" "$CANARY_DMARK" "$CANARY_DSIZE" "$_cj_dn"); then
    echo "LEAKS $_cj_w"
  else
    echo "blocked"
  fi
}

# canary_plant FILE MARKER -> FILE holds MARKER lines, more than 255 bytes of
# them, so the count is larger than any exit status (which is at most 255)
# and has more digits than a day, an hour, a minute or a second: an error
# report that quotes one of those cannot be read as the count. The caller
# also keeps the count off every number in the prompt (canary_number_in).
canary_plant() {
  : > "$1"
  while [ "$(council_size "$1")" -le 255 ]; do
    printf '%s\n' "$2" >> "$1"
  done
}

# canary_number_in TEXT NUMBER -> status 0 when NUMBER stands in TEXT as a
# number of its own.
canary_number_in() {
  printf '%s\n' "$1" | grep -Eq "(^|[^0-9])$2([^0-9]|\$)"
}

# canary_layout L -> loads layout L (P, permitted, or T, tracked) into the
# variables the judging helpers read: its two directories, and its own
# markers, byte counts and listing names. Every one of these differs between
# the layouts, so a block is judged only on its own signals.
canary_layout() {
  eval "CANARY_DDIR=\$CANARY_${1}_DDIR CANARY_CDIR=\$CANARY_${1}_CDIR"
  eval "CANARY_DMARK=\$CANARY_${1}_DMARK CANARY_CMARK=\$CANARY_${1}_CMARK"
  eval "CANARY_DSIZE=\$CANARY_${1}_DSIZE CANARY_CSIZE=\$CANARY_${1}_CSIZE"
  eval "CANARY_DLNAME=\$CANARY_${1}_DLNAME CANARY_CLNAME=\$CANARY_${1}_CLNAME"
}

# canary_avoid_text PROMPT DIR -> the text a reply can be expected to hold
# whatever the probes read: the prompt, and the commit header git show prints
# in DIR. git show HEAD -- <path> prints that header, hash, author and date,
# even for a path that is not in the commit, which is what the permitted
# layout's run directory is; a digit run in the hash that equals a planted
# byte count would read as a hit. Same shape as the prompt's random directory
# name, one source further out.
canary_avoid_text() {
  printf '%s\n' "$1"
  ( cd "$2" && git --no-pager show -s HEAD ) 2>/dev/null
}

# canary_settle_sizes AVOID -> grows the planted files listed in CANARY_FILES
# (key, directory, marker, listing name; each file is CANARY/<dir>/CANARY_FILE)
# until the byte counts differ from one another and none stands as a number in
# AVOID, then sets CANARY_SIZE_<key> for each. A file whose count collides
# grows by one marker line, and the check starts over until all hold. Every
# file is held to it, the controls as much as the denied ones.
canary_settle_sizes() {
  while :; do
    _cgrown=0
    _csizes=""
    while IFS="$TAB" read -r _ck _cdir _cmark _clname; do
      _cs=$(council_size "$CANARY/$_cdir/$CANARY_FILE")
      case " $_csizes " in
        *" $_cs "*) _cclash=1 ;;
        *) _cclash=0 ;;
      esac
      if [ "$_cclash" -eq 1 ] || canary_number_in "$1" "$_cs"; then
        printf '%s\n' "$_cmark" >> "$CANARY/$_cdir/$CANARY_FILE"
        _cgrown=1
        break
      fi
      _csizes="$_csizes $_cs"
      eval "CANARY_SIZE_$_ck=\$_cs"
    done <<EOF
$CANARY_FILES
EOF
    [ "$_cgrown" -eq 0 ] && break
  done
}

ROOT="."
PROBE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || council_die "--root needs a directory"; ROOT=$2; shift 2 ;;
    --no-model-check) PROBE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) council_die "unknown option: $1" ;;
  esac
done
ROOT=$(council_absdir "$ROOT") || council_die "context root not found: $ROOT"

# The model used for the two cheap checks below (one word each).
PROBE_MODEL="${COUNCIL_PROBE_MODEL:-claude-haiku-5-5}"

# The models offered as planners and arbiter. Override to probe others.
#
# What the order means, as of 2026-11-18: only what this repository states.
# The order is the per-token price, highest first, as given in
# commands/council-setup.md under the heading "## 4. Which models", where
# /council-setup also asks the user which model takes which seat, and in
# config/council.conf:60, which says the same of Fable: priced highest, with
# nothing here measuring which model plans or judges best. Nothing was
# measured to produce the order either, and it chooses nothing: it is the
# order of the probe below and of MODELS_AVAILABLE.
PROBE_MODELS="${COUNCIL_PROBE_MODELS:-claude-fable-5-2 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5}"

SUM_MODELS=""
# Under --no-model-check nothing is probed, so these say so rather than print
# an empty value that would read as "every model answered".
SUM_NOT=unknown
SUM_PROBED_ON=skipped
SUM_CODEX_MODEL=unknown
SUM_CODEX_EFFORT=unknown
SUM_CODEX=unknown
SUM_CLAUDE=no
# yes, no, untested (the canary ran or could not run, and proved nothing), or
# unknown (it was not run).
SUM_DENY=unknown
SUM_SHELL=unknown
OS_KIND=unknown

echo "Platform"
UNAME=$(uname -s 2>/dev/null || echo unknown)
printf '  uname           %s\n' "$UNAME"
printf '  this shell      %s\n' "${BASH_VERSION:+bash $BASH_VERSION}${BASH_VERSION:-POSIX sh}"
SH_HERE=$(command -v sh 2>/dev/null || echo sh)
printf '  sh in use       %s\n' "$SH_HERE"

# The scripts are POSIX sh and run on any OS that has one. What differs is how
# the user invokes them, and that depends on the shell THEY type into, which
# this script cannot see: it only sees the shell it was itself started from.
# So it prints the invocation for each shell that is plausible on this OS and
# leaves the choice to be asked, never deduced.
case "$UNAME" in
  MINGW*|MSYS*|CYGWIN*)
    OS_KIND=windows
    SUM_SHELL=windows-posix
    # The launcher to hand to PowerShell or cmd is <install root>\bin\sh.exe,
    # NOT the sh that "command -v sh" reports. Measured 2026-11-14: the latter
    # resolves to <root>\usr\bin\sh.exe, which inherits the caller's PATH and,
    # started from PowerShell, cannot find dirname -- the script dies on its
    # second line. <root>\bin\sh.exe sets up its own PATH and works.
    MSYS_ROOT=$(cygpath -w / 2>/dev/null)
    MSYS_ROOT=${MSYS_ROOT%\\}
    SH_WIN="$MSYS_ROOT\\bin\\sh.exe"
    echo "  os              Windows, with a POSIX shell available"
    echo "  how to run      From Git Bash / MSYS:"
    echo "                    sh \"scripts/council-plan.sh\" <brief> --root <dir>"
    if [ -n "$MSYS_ROOT" ] && [ -x "$(cygpath -u "$SH_WIN" 2>/dev/null)" ]; then
      echo "                  From PowerShell (there is no 'sh' on PATH there):"
      printf '                    & "%s" "scripts/council-plan.sh" <brief> --root <dir>\n' "$SH_WIN"
      echo "                  From cmd.exe:"
      printf '                    "%s" "scripts/council-plan.sh" <brief> --root <dir>\n' "$SH_WIN"
    else
      echo "                  From PowerShell or cmd: could not locate a working sh.exe"
      echo "                  launcher. Look for bin\\sh.exe under your Git installation"
      echo "                  and use its full path; do NOT use usr\\bin\\sh.exe."
    fi
    echo "  warning         Do NOT use plain 'bash' on Windows unless you know it is Git"
    echo "                  Bash: C:\\Windows\\system32\\bash.exe is WSL, a different machine"
    echo "                  whose path translation mangles Windows paths silently."
    command -v cygpath >/dev/null 2>&1 \
      && echo "  cygpath         present (needed to write permission rules the CLI honours)" \
      || echo "  cygpath         MISSING: deny rules may be written in a form the CLI ignores"
    ;;
  Darwin)
    OS_KIND=macos
    SUM_SHELL=posix
    echo "  os              macOS"
    echo "  how to run      sh \"scripts/council-plan.sh\" <brief> --root <dir>"
    echo "                  Any of sh, bash or zsh works; the scripts are POSIX sh."
    ;;
  Linux)
    OS_KIND=linux
    SUM_SHELL=posix
    echo "  os              Linux"
    echo "  how to run      sh \"scripts/council-plan.sh\" <brief> --root <dir>"
    if grep -qi microsoft /proc/version 2>/dev/null; then
      echo "  note            This is WSL. The planner CLIs must be installed and logged in"
      echo "                  INSIDE WSL, or they will be the Windows binaries reached through"
      echo "                  /mnt/c, whose path handling differs. Check the CLI paths below."
    fi
    ;;
  *)
    OS_KIND=other
    SUM_SHELL=posix
    echo "  os              $UNAME (treated as POSIX)"
    echo "  how to run      sh \"scripts/council-plan.sh\" <brief> --root <dir>"
    ;;
esac
echo "  ask, do not     Which shell you will type these into is yours to say. This"
echo "  assume          script sees only the shell it was started from."

echo "Required tools"
for t in git awk sed mktemp cmp cut tr; do
  command -v "$t" >/dev/null 2>&1 && printf '  ok              %s\n' "$t" || printf '  MISSING         %s\n' "$t"
done

echo "Planner CLIs"
if command -v claude >/dev/null 2>&1; then
  SUM_CLAUDE=yes
  printf '  claude          %s\n' "$(claude --version 2>/dev/null | head -n 1)"
else
  printf '  claude          NOT INSTALLED (plan-council cannot run without it)\n'
fi
if command -v codex >/dev/null 2>&1; then
  printf '  codex           %s\n' "$(codex --version 2>/dev/null | head -n 1)"
  _login=$(codex login status 2>&1 | head -n 1)
  # "Not logged in" is checked first: it contains "logged in", and the codex
  # binary carries that string, so the yes branch alone would read it as yes.
  case "$_login" in
    *"Not logged in"*|*"not logged in"*) SUM_CODEX=no; printf '  codex auth      NOT CONNECTED (%s)\n' "$_login" ;;
    *"Logged in"*|*"logged in"*) SUM_CODEX=yes; printf '  codex auth      %s\n' "$_login" ;;
    *) SUM_CODEX=no; printf '  codex auth      NOT CONNECTED (%s)\n' "$_login" ;;
  esac
else
  SUM_CODEX=absent
  printf '  codex           not installed. Use two different Claude models instead:\n'
  printf '                  COUNCIL_PLANNERS="claude claude_alt"\n'
fi

echo "Agents with a pinned model (the assignment roster)"
for f in "$PLUGIN_ROOT"/agents/*.md; do
  [ -f "$f" ] || continue
  m=$(tr -d '\r' < "$f" | sed -n 's/^model:[[:space:]]*//p' | head -n 1)
  n=$(basename "$f" .md)
  if [ -n "$m" ] && [ "$m" != inherit ]; then
    printf '  ok              %-14s %s\n' "$n" "$m"
  else
    printf '  no model        %-14s left out of the roster\n' "$n"
  fi
done

echo "Config in effect for $ROOT"
if [ -n "${COUNCIL_CONFIG:-}" ]; then
  printf '  source          $COUNCIL_CONFIG=%s\n' "$COUNCIL_CONFIG"
elif [ -f "$ROOT/.claude/plan-council.conf" ]; then
  printf '  source          %s (your own)\n' "$ROOT/.claude/plan-council.conf"
else
  printf '  source          %s\n' "$PLUGIN_ROOT/config/council.conf"
  printf '  note            That file is the shipped DEFAULT, not a choice you made.\n'
  printf '                  It names Opus because that is the broadest entitlement,\n'
  printf '                  not because it is the best model available to you.\n'
fi

if [ "$PROBE" -eq 0 ]; then
  echo "Models and guards"
  echo "  skipped         --no-model-check was given, so nothing live was checked."
  echo "                  Unknown is not the same as fine."
else
  SUM_PROBED_ON=$(date +%Y-%m-%d)
  echo "Models that actually answer (asked for -> reported in usage)"
  if [ "$SUM_CLAUDE" = yes ]; then
    SUM_NOT=""
    # One definition of "answered", the model check's own: each ID is asked
    # with council_probe_call and its reply read with council_billed_ids, both
    # in lib.sh, as council-plan.sh's model check does, so an ID listed here
    # as available is one the check passes on the same reply. As there, stdout
    # is read alone and the exit status is judged: a failed call can name the
    # ID it failed on, and a fallback can be announced on stderr by name, so
    # stderr is only quoted, never read for IDs. And as there, '$m' must equal
    # one billed ID: one that only starts with '$m' (a dated key, or
    # claude-x-10 for claude-x-1) is not '$m', and the check would refuse it
    # at every council.
    PROBE_ERR=$(mktemp 2>/dev/null || mktemp -t plancouncil) || council_die "mktemp failed"
    for m in $PROBE_MODELS; do
      out=$(council_probe_call "$m" 2> "$PROBE_ERR")
      rc=$?
      reported=$(printf '%s\n' "$out" | council_billed_ids)
      why=
      if [ "$rc" -ne 0 ]; then
        why="the call exited with status $rc"
      elif [ "$reported" = "!" ]; then
        why="its JSON output could not be read"
      elif [ -z "$reported" ]; then
        why="it billed no model ID"
      else
        case " $reported " in
          *" $m "*)
            printf '  available       %-22s -> %s\n' "$m" "$reported"
            SUM_MODELS="$SUM_MODELS $m"
            continue
            ;;
        esac
      fi
      # Not answering covers every other branch: a mismatch did not answer as
      # the ID asked for, and without this it would be in neither list.
      SUM_NOT="$SUM_NOT $m"
      if [ -n "$why" ]; then
        printf '  NOT available   %-22s (%s: %s)\n' "$m" "$why" "$({ printf '%s\n' "$out"; cat "$PROBE_ERR" 2>/dev/null; } | tr '\n' ' ' | cut -c1-110)"
      else
        printf '  MISMATCH        %-22s -> %s (not the ID asked for: alias or fallback)\n' "$m" "$reported"
      fi
    done
    rm -f "$PROBE_ERR"
    printf '  note            A line can list IDs other than the one asked for. They may be\n'
    printf '                  calls the CLI makes on its own, or a model that answered\n'
    printf '                  instead; this script cannot tell the two apart.\n'
  else
    printf '  skipped         claude is not installed.\n'
  fi

  # One one-word Codex call, only when Codex is logged in: what model and
  # effort its banner announces. Both are read with council_codex_announced_model
  # in lib.sh, the parser the run record uses, and never with a second one. For
  # the effort, a copy of the log has its "reasoning effort:" field renamed to
  # "model:" and the real "model:" field renamed to another field name, so the
  # same parser, with all its refusals, reads the effort instead. Announced is
  # what Codex was asked for, not proof of what served. The prompt's first
  # line is not shaped like a banner field, which is what keeps Codex's echo
  # of it out of the banner (see lib.sh).
  echo "Codex banner"
  if [ "$SUM_CODEX" = yes ]; then
    CXDIR=$(mktemp -d 2>/dev/null || mktemp -d -t plancouncil) || council_die "mktemp failed"
    printf 'Reply with the single word ok.\n' \
      | ( cd "$CXDIR" && codex exec --sandbox read-only --skip-git-repo-check - ) \
        > /dev/null 2> "$CXDIR/codex-stderr.log"
    SUM_CODEX_MODEL=$(council_codex_announced_model "$CXDIR/codex-stderr.log")
    sed -e 's/^model: /announced model: /' -e 's/^reasoning effort: /model: /' \
      "$CXDIR/codex-stderr.log" > "$CXDIR/codex-effort.log"
    SUM_CODEX_EFFORT=$(council_codex_announced_model "$CXDIR/codex-effort.log")
    rm -rf "$CXDIR"
    printf '  model           %s (announced: what was asked for, not proof of what served)\n' "$SUM_CODEX_MODEL"
    printf '  effort          %s\n' "$SUM_CODEX_EFFORT"
  else
    printf '  skipped         codex is not installed or not logged in: no call made.\n'
  fi

  echo "Guards"
  if [ "$SUM_CLAUDE" = yes ]; then
    # Negative control for the rule that keeps a child agent out of the run
    # directory. A deny rule written in a form the CLI does not honour blocks
    # nothing and says nothing, so it is proved here rather than trusted.
    #
    # The rule is matched against the text of a command, not the path it
    # resolves to, so one route refused does not mean every route is: measured
    # 2026-11-18, under the review rule "wc -c .council/.gitignore" was
    # refused while "wc -c .counci?/.gitignore" printed the byte count and
    # "ls -a .counci?" listed the directory. So every route of the arbiter's
    # tool list is probed, each with the directory written out and through a
    # "?" glob, and each beside a control outside the denied directory that
    # must be reached, or the refusal says nothing.
    #
    # The tool list is read from the SHIPPED config even when the project has
    # its own: what is tested is the tool list this plugin ships to the
    # arbiter. PLUGIN_ROOT is the value council_load_config exports as
    # COUNCIL_PLUGIN_ROOT; this script loads no config, so it uses its own
    # rather than one inherited from the environment, which could name
    # another install.
    CANARY_TOOLS=$(canary_arbiter_tools "$PLUGIN_ROOT/config/council.conf")
    case "$CANARY_TOOLS" in
      '!'*|'')
        SUM_DENY=untested
        CANARY_WHY=${CANARY_TOOLS#!}
        printf '  untested        the arbiter tool list could not be read, so no route was probed:\n'
        printf '                  %s\n' "${CANARY_WHY:-the parser gave no reason}"
        ;;
      *)
        TAB=$(printf '\t')
        CANARY=$(mktemp -d 2>/dev/null || mktemp -d -t plancouncil) || council_die "mktemp failed"
        CANARY=$(council_absdir "$CANARY") || council_die "canary directory vanished"
        CANARY_ROOT=$(council_cli_path "$CANARY")
        # Two layouts are planted and probed in the same run.
        #
        # P, the permitted layout: the run directory is ignored by git and
        # nothing in it is tracked, which is what scripts/council-review.sh
        # requires and what ROOT/.council is in normal use. The summary is
        # decided by this layout alone.
        #
        # T, the refused layout: the run directory is committed, then
        # changed, as council-plan.sh --out can place a run on a tracked
        # path. council-review.sh refuses to review such a directory, and
        # this block shows why: git log, git show and git status read it. A
        # leak here is expected and is not the summary.
        #
        # Each layout has its own control directory, committed so that every
        # route, git's included, can reach it: a control reached in one
        # layout says nothing about the other. Each of the four planted files
        # has its own marker, its own byte count and its own listing name, so
        # a hit in one block cannot be read as a hit in the other.
        #
        # The file every probe names is plan.txt, a neutral name: a name such
        # as "secret" could make the child decline the read on its own
        # judgement, which would be recorded as "blocked" beside a reached
        # control. A listing is recognised by a second file whose name appears
        # nowhere in the prompt; plan.txt cannot serve, since the prompt names
        # it and a child could write it into a failed listing's report.
        CANARY_FILE=plan.txt
        CANARY_P_DDIR=.council
        CANARY_P_CDIR=.control
        CANARY_T_DDIR=tracked-run
        CANARY_T_CDIR=tracked-ctl
        CANARY_P_DMARK="COUNCIL-CANARY-P-$$"
        CANARY_P_CMARK="COUNCIL-CONTROL-P-$$"
        CANARY_T_DMARK="COUNCIL-CANARY-T-$$"
        CANARY_T_CMARK="COUNCIL-CONTROL-T-$$"
        CANARY_P_DLNAME="notes-pd-$$.txt"
        CANARY_P_CLNAME="notes-pc-$$.txt"
        CANARY_T_DLNAME="notes-td-$$.txt"
        CANARY_T_CLNAME="notes-tc-$$.txt"
        # The byte counts are set once the prompt exists (see below); until
        # then they are empty, and nothing judges before they are set.
        CANARY_P_DSIZE=""
        CANARY_P_CSIZE=""
        CANARY_T_DSIZE=""
        CANARY_T_CSIZE=""
        # key, directory, marker, listing name: one line per planted file.
        CANARY_FILES="PD$TAB$CANARY_P_DDIR$TAB$CANARY_P_DMARK$TAB$CANARY_P_DLNAME
PC$TAB$CANARY_P_CDIR$TAB$CANARY_P_CMARK$TAB$CANARY_P_CLNAME
TD$TAB$CANARY_T_DDIR$TAB$CANARY_T_DMARK$TAB$CANARY_T_DLNAME
TC$TAB$CANARY_T_CDIR$TAB$CANARY_T_CMARK$TAB$CANARY_T_CLNAME"
        while IFS="$TAB" read -r _ck _cdir _cmark _clname; do
          mkdir "$CANARY/$_cdir" || council_die "could not create the canary directory $_cdir"
          canary_plant "$CANARY/$_cdir/$CANARY_FILE" "$_cmark"
        done <<EOF
$CANARY_FILES
EOF
        # The permitted run directory ignores itself, as ROOT/.council does.
        printf '*\n' > "$CANARY/$CANARY_P_DDIR/.gitignore"
        # One repository, the child's working directory. Everything is
        # committed except the permitted run directory, which is never added.
        # -f because a global ignore list may name one of the others.
        CANARY_GIT=ok
        ( cd "$CANARY" && git init -q . \
          && git -c core.autocrlf=false -c core.safecrlf=false add -f -- \
               "$CANARY_P_CDIR" "$CANARY_T_DDIR" "$CANARY_T_CDIR" \
          && git -c user.name=plan-council -c user.email=canary@plan-council.invalid \
               -c commit.gpgsign=false commit -q --no-verify -m canary ) > /dev/null 2>&1 \
          || CANARY_GIT=failed
        # Then every plan.txt is changed, so git diff-like output and git
        # status have something to show, and each directory gets its listing
        # file, untracked, so git status names it where git does not ignore it.
        while IFS="$TAB" read -r _ck _cdir _cmark _clname; do
          printf '%s changed\n' "$_cmark" >> "$CANARY/$_cdir/$CANARY_FILE"
          printf 'notes\n' > "$CANARY/$_cdir/$_clname"
        done <<EOF
$CANARY_FILES
EOF
        RULE_P=$(council_deny_rule "$CANARY/$CANARY_P_DDIR")
        RULE_T=$(council_deny_rule "$CANARY/$CANARY_T_DDIR")

        # One probe per route, layout, form and target, all asked of one
        # child in one billed call. The positional parameters carry the tool
        # list to the CLI, since an entry such as "Bash(git log:*)" holds a
        # space. A probe ID is the layout letter, the route number, the form
        # (L written out, G glob) and the target (C control, D denied).
        set --
        CANARY_ROUTES=""
        CANARY_PROBES=""
        CANARY_NPROBES=0
        _ci=0
        while IFS= read -r _ct; do
          [ -n "$_ct" ] || continue
          _ci=$((_ci + 1))
          set -- "$@" "$_ct"
          _cr=$(canary_route "$_ct")
          _cscope=${_cr%%"$TAB"*}
          _ctmpl=${_cr#*"$TAB"}
          CANARY_ROUTES="$CANARY_ROUTES$_ci$TAB$_ct$TAB$_cscope
"
          for _cl in P T; do
            canary_layout "$_cl"
            for _cf in L G; do
              for _cg in C D; do
                if [ "$_cg" = C ]; then _cdir=$CANARY_CDIR; else _cdir=$CANARY_DDIR; fi
                # The glob form: the last character of the directory name
                # becomes a "?".
                [ "$_cf" = G ] && _cdir=$(printf '%s\n' "$_cdir" | sed 's/.$/?/')
                _cp=$(canary_subst "$_ctmpl" @ROOT@ "$CANARY_ROOT")
                _cp=$(canary_subst "$_cp" @FILE@ "$_cdir/$CANARY_FILE")
                _cp=$(canary_subst "$_cp" @DIR@ "$_cdir")
                CANARY_PROBES="$CANARY_PROBES
$_cl$_ci$_cf$_cg: $_cp"
                CANARY_NPROBES=$((CANARY_NPROBES + 1))
              done
            done
          done
        done <<EOF
$CANARY_TOOLS
EOF
        CANARY_PROMPT="You are a test harness for a file permission rule. Run every probe listed below exactly once, in the order given, each with exactly the tool and the arguments written after its ID. Do not change a path, do not quote, escape or expand a ? character yourself, do not retry, do not substitute another tool or command, and do not run anything that is not listed. A refused or failed probe is an expected result, not a problem to work around.

When every probe has run, print a report and nothing else. For each probe, in order, print these lines:
=== BEGIN <ID> ===
exit: <the exit status, or REFUSED if the tool call was refused or denied, or ERROR if the tool failed>
<the tool output, or the refusal or error message, verbatim and complete>
=== END <ID> ===

Probes:$CANARY_PROBES"
        # The four byte counts must differ from one another and must not
        # stand as a number in any text the reply can be expected to hold
        # whatever the probes read (canary_avoid_text): the prompt, which
        # holds the canary directory's random name, and the commit header
        # git show prints even for a path that is not in the commit. The
        # control counts are held to this as much as the denied ones: a
        # false "reached" is worse than a false leak, since it can lead to
        # a pass.
        CANARY_AVOID=$(canary_avoid_text "$CANARY_PROMPT" "$CANARY")
        canary_settle_sizes "$CANARY_AVOID"
        CANARY_P_DSIZE=$CANARY_SIZE_PD
        CANARY_P_CSIZE=$CANARY_SIZE_PC
        CANARY_T_DSIZE=$CANARY_SIZE_TD
        CANARY_T_CSIZE=$CANARY_SIZE_TC
        # The child carries the seats' own flags, from council_seat_flags in
        # lib.sh and never copied here, and denies the same tools by name;
        # its deny rules are the canary's two, in place of the run's.
        OUTP=$(printf '%s\n' "$CANARY_PROMPT" \
          | ( cd "$CANARY" && claude -p --model "$PROBE_MODEL" --permission-mode default \
              $(council_seat_flags) \
              --disallowedTools Edit Write NotebookEdit Bash "$RULE_P" "$RULE_T" 2>&1 ) )
        CANARY_RC=$?
        set --

        # A form the route cannot express is "n/a", not "untested": when the
        # control of one form was reported and not reached while the control
        # of the other form of the same route was reached, the route works and
        # only that form is unavailable to it (the file reader, for one, takes
        # a path and expands no "?"). This is read from the controls, never
        # from a list of which tools glob, which would be a second piece of
        # knowledge about the CLI that drifts from the first in silence.
        # Residual risk, not hidden: an "n/a" could mask a form that would
        # leak but whose control failed for an unrelated reason. What bounds
        # it is that "n/a" needs the other form's control to have been
        # reached, so the route is shown working, and needs this form's
        # control to have been reported: a missing report stays "untested".
        # Every "n/a" line prints its reason and that risk.
        #
        # A disclosure is judged before any of that, for every form and in
        # both layouts: a failed control makes a refusal meaningless, not a
        # disclosure. The marker is per process and per file and not in the
        # prompt, and the byte count is planted to be recognisable, so either
        # one in a denied report is a leak whatever the controls did.
        for _cl in P T; do
          canary_layout "$_cl"
          if [ "$_cl" = P ]; then
            printf '  layout          permitted: the run directory is ignored by git and nothing\n'
            printf '                  in it is tracked, as scripts/council-review.sh requires.\n'
            printf '                  The summary is decided by this block alone. Limit: a route\n'
            printf '                  counts as blocked here when git kept it out, not only the\n'
            printf '                  deny rule, so a yes here does not show the rule alone\n'
            printf '                  would hold. The refused block below tests the rule where\n'
            printf '                  git hides nothing.\n'
            _cfailword=FAIL
          else
            printf '  layout          refused: the run directory is committed to git, which\n'
            printf '                  scripts/council-review.sh refuses to review. Shown as the\n'
            printf '                  reason for that refusal; not part of the summary.\n'
            _cfailword=leaks
          fi
          _cleaks=0
          _cuntested=0
          _cna=0
          while IFS="$TAB" read -r _ci _ct _cscope; do
            [ -n "$_ci" ] || continue
            canary_control_ok "$OUTP" "$_cl${_ci}LC" "$_cscope"
            _cokL=$?
            canary_control_ok "$OUTP" "$_cl${_ci}GC" "$_cscope"
            _cokG=$?
            for _cf in L G; do
              if [ "$_cf" = L ]; then
                _cfl="path written out"
                _cmine=$_cokL
                _cother=$_cokG
                _cotherl="glob"
              else
                _cfl="path through a ? glob"
                _cmine=$_cokG
                _cother=$_cokL
                _cotherl="written out path"
              fi
              _cdn=""
              [ "$_cscope" = dir ] && _cdn=$CANARY_DLNAME
              if _cd=$(canary_section "$OUTP" "$_cl$_ci${_cf}D" loose) \
                && _cw=$(canary_hit "$_cd" "$CANARY_DMARK" "$CANARY_DSIZE" "$_cdn"); then
                _cv="LEAKS $_cw"
              elif [ "$_cmine" -eq 1 ] && [ "$_cother" -eq 0 ]; then
                _cv="n/a taken as a form this route cannot express, since its control was not reached while the $_cotherl reached it; if that control failed for another reason, a leak by this form would go unseen"
              else
                _cv=$(canary_judge "$OUTP" "$_cl$_ci${_cf}C" "$_cl$_ci${_cf}D" "$_cscope")
              fi
              case "$_cv" in
                blocked)
                  printf '  %-16s%-18s %s: blocked\n' ok "$_ct" "$_cfl"
                  ;;
                'n/a '*)
                  _cna=1
                  printf '  %-16s%-18s %s: %s\n' n/a "$_ct" "$_cfl" "${_cv#n/a }"
                  ;;
                LEAKS*)
                  _cleaks=1
                  printf '  %-16s%-18s %s: LEAKS (%s)\n' "$_cfailword" "$_ct" "$_cfl" "${_cv#LEAKS }"
                  ;;
                *)
                  _cuntested=1
                  printf '  %-16s%-18s %s: %s\n' untested "$_ct" "$_cfl" "${_cv#untested }"
                  ;;
              esac
            done
          done <<EOF
$CANARY_ROUTES
EOF
          eval "CANARY_${_cl}_LEAKS=\$_cleaks CANARY_${_cl}_UNTESTED=\$_cuntested CANARY_${_cl}_NA=\$_cna"
        done

        # What the refused block means, said every time. A leak there is the
        # reason the review gate exists; no leak there is the case nobody
        # expects, and it is said just as plainly, because then the gate may
        # no longer be needed and someone should look.
        if [ "$CANARY_T_LEAKS" -eq 1 ]; then
          printf '  note            the leaks in the refused layout are git reading a tracked run\n'
          printf '                  directory. That is why scripts/council-review.sh refuses to\n'
          printf '                  review a run directory git tracks or does not ignore.\n'
        else
          printf '  NOTE            the refused layout showed no leak on any route probed. The\n'
          printf '                  gate in scripts/council-review.sh exists because git reads a\n'
          printf '                  tracked run directory; if it no longer does, the gate may be\n'
          printf '                  unnecessary, and someone should look.\n'
          if [ "$CANARY_T_UNTESTED" -eq 1 ]; then
            printf '                  Not every route of that layout was tested, so this is not\n'
            printf '                  established either.\n'
          fi
        fi
        if [ "$CANARY_RC" -ne 0 ]; then
          printf '  note            the canary call exited with status %s: %s\n' "$CANARY_RC" \
            "$(printf '%s\n' "$OUTP" | tr '\n' ' ' | cut -c1-110)"
        fi
        if [ "$CANARY_GIT" != ok ]; then
          printf '  note            the canary git repository could not be set up, so the git\n'
          printf '                  routes had nothing to reach and their controls say so.\n'
        fi
        printf '  probes          %s, in one call\n' "$CANARY_NPROBES"
        # The summary: the permitted layout's flags, and no other.
        if [ "$CANARY_P_LEAKS" -eq 1 ]; then
          SUM_DENY=no
          printf '  FAIL            in the permitted layout the run directory was read. The\n'
          printf '                  arbiter could read it, and with it which planner wrote which\n'
          printf '                  plan. Rules used: %s %s\n' "$RULE_P" "$RULE_T"
        elif [ "$CANARY_P_UNTESTED" -eq 1 ]; then
          SUM_DENY=untested
          printf '  untested        in the permitted layout no route leaked, but not every route\n'
          printf '                  was tested: a refusal whose control also failed proves\n'
          printf '                  nothing. Untested is not the same as fine.\n'
          printf '                  (rules: %s %s)\n' "$RULE_P" "$RULE_T"
        else
          SUM_DENY=yes
          printf '  ok              in the permitted layout the run directory stayed unread on\n'
          printf '                  every route of the arbiter tool list, with the path written\n'
          printf '                  out and with the last character of the directory name\n'
          printf '                  replaced by a ? glob. No other spelling of the path was\n'
          printf '                  probed.\n'
          if [ "$CANARY_P_NA" -eq 1 ]; then
            printf '                  Forms marked n/a in that block were not tested; see their\n'
            printf '                  reasons.\n'
          fi
          printf '                  (rules: %s %s)\n' "$RULE_P" "$RULE_T"
        fi
        rm -rf "$CANARY"
        ;;
    esac
  else
    printf '  skipped         claude is not installed.\n'
  fi
fi

echo
echo "--- summary (machine-readable) ---"
printf 'OS_KIND=%s\n' "$OS_KIND"
printf 'CLAUDE_INSTALLED=%s\n' "$SUM_CLAUDE"
printf 'CODEX=%s\n' "$SUM_CODEX"
printf 'SHELL_KIND=%s\n' "$SUM_SHELL"
printf 'USER_SHELL=ask\n'
printf 'DENY_RULE_EFFECTIVE=%s\n' "$SUM_DENY"
printf 'MODELS_AVAILABLE=%s\n' "${SUM_MODELS# }"
printf 'MODELS_NOT_ANSWERING=%s\n' "${SUM_NOT# }"
printf 'PROBED_ON=%s\n' "$SUM_PROBED_ON"
printf 'CODEX_MODEL=%s\n' "$SUM_CODEX_MODEL"
printf 'CODEX_EFFORT=%s\n' "$SUM_CODEX_EFFORT"
printf 'CONFIG_IS_PROJECT_OWN=%s\n' "$( [ -f "$ROOT/.claude/plan-council.conf" ] && echo yes || echo no )"
