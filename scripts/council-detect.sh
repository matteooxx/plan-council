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
PROBE_MODELS="${COUNCIL_PROBE_MODELS:-claude-fable-5-2 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5}"

SUM_MODELS=""
SUM_CODEX=unknown
SUM_CLAUDE=no
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
  case "$_login" in
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
  echo "Models that actually answer (asked for -> reported in usage)"
  if [ "$SUM_CLAUDE" = yes ]; then
    for m in $PROBE_MODELS; do
      json=$(printf 'Reply with the single word ok.' | claude -p --model "$m" --output-format json 2>&1)
      reported=$(printf '%s' "$json" | grep -o '"claude-[A-Za-z0-9._-]*"' | tr -d '"' | sort -u | tr '\n' ' ')
      case " $reported" in
        *" $m"*)
          printf '  available       %-22s -> %s\n' "$m" "$reported"
          SUM_MODELS="$SUM_MODELS $m"
          ;;
        *)
          if [ -z "$reported" ]; then
            printf '  NOT available   %-22s (%s)\n' "$m" "$(printf '%s' "$json" | tr '\n' ' ' | cut -c1-110)"
          else
            printf '  MISMATCH        %-22s -> %s (not the ID asked for: alias or fallback)\n' "$m" "$reported"
          fi
          ;;
      esac
    done
    printf '  note            Other IDs in a line are the CLI own background calls, not a fallback.\n'
  else
    printf '  skipped         claude is not installed.\n'
  fi

  echo "Guards"
  if [ "$SUM_CLAUDE" = yes ]; then
    # Negative control for the rule that keeps a child agent out of the run
    # directory. A deny rule written in a form the CLI does not honour blocks
    # nothing and says nothing, so it is proved here rather than trusted.
    CANARY=$(mktemp -d 2>/dev/null || mktemp -d -t plancouncil) || council_die "mktemp failed"
    CANARY=$(council_absdir "$CANARY") || council_die "canary directory vanished"
    printf 'COUNCIL-CANARY-%s\n' "$$" > "$CANARY/secret.txt"
    RULE=$(council_deny_rule "$CANARY")
    OUTP=$(printf 'Read the file secret.txt in the current directory and print its contents verbatim. If the read is refused, print only the word REFUSED.\n' \
      | ( cd "$CANARY" && claude -p --model "$PROBE_MODEL" --permission-mode default \
          --allowedTools Read Glob Grep --disallowedTools "$RULE" 2>&1 ) )
    case "$OUTP" in
      *COUNCIL-CANARY*)
        SUM_DENY=no
        printf '  FAIL            the deny rule did not block the read. The arbiter could read\n'
        printf '                  the run directory, and with it which planner wrote which plan.\n'
        printf '                  Rule used: %s\n' "$RULE"
        ;;
      *)
        SUM_DENY=yes
        printf '  ok              deny rule honoured: a denied directory stayed unreadable\n'
        printf '                  (rule: %s)\n' "$RULE"
        ;;
    esac
    rm -rf "$CANARY"
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
printf 'CONFIG_IS_PROJECT_OWN=%s\n' "$( [ -f "$ROOT/.claude/plan-council.conf" ] && echo yes || echo no )"
