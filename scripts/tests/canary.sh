#!/bin/sh
# Tests for the deny canary in ../council-detect.sh: how it judges each
# route it probes, from what a stand-in child returns.
#
# Usage: sh scripts/tests/canary.sh
#        dash scripts/tests/canary.sh
#
# Every assertion names the run and the line or summary key it reads, and
# prints one line. The exit status is non-zero when any assertion failed.
#
# No model is called. A stand-in "claude", written to a temporary directory
# and put first on PATH, records every argument it receives and the prompt.
# Asked for one word with JSON, it bills the model asked for; started with
# --allowedTools, as the write control is, it runs the one git show --output
# it was asked for; started with --tools, as the canary's child is, it
# carries out every probe in the prompt itself, on the files the canary
# planted, with the tools named in --tools. By default it is a CLI on which
# the rule holds, which is this file's choice and not a measurement: its
# Read, Glob and Grep refuse a path a Read(DIR/**) rule covers, after
# resolving ".." and case, and one outside the working directory under
# --restricted. Its Glob lists git-ignored files and drops denied ones and
# its Grep drops both, as an arbiter found from its own seat (the comment
# above canary_run in council-detect.sh). Bash is refused when it is denied
# by name. STUB_* variables make it misbehave on purpose, one route at a
# time. A stand-in "codex" reports that it is not logged in, so it is never
# called. Everything is written to a temporary directory, removed on exit.
set -u

T_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
T_PLUGIN=$(dirname "$(dirname "$T_DIR")")

T_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t plancouncil) || {
  echo "mktemp failed" >&2
  exit 1
}
T_TMP=$(cd "$T_TMP" && pwd -P)
trap 'rm -rf "$T_TMP"' EXIT
trap 'exit 1' HUP INT TERM

T_PASS=0
T_FAIL=0

# T_ONLY, when set, names the runs to make (as t_detect is given them, or
# without their shell prefix); the assertions of every other run are skipped
# and say nothing. It exists to make a mutation's run short.
T_SKIP=0

t_ok() {
  [ "$T_SKIP" -eq 0 ] || return 0
  T_PASS=$((T_PASS + 1))
  printf 'ok    %s\n' "$1"
}

t_bad() {
  [ "$T_SKIP" -eq 0 ] || return 0
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

GIT_CEILING_DIRECTORIES=$T_TMP
export GIT_CEILING_DIRECTORIES

# ---------------------------------------------------------------------------
# The stand-ins.
mkdir -p "$T_TMP/bin" "$T_TMP/stub" "$T_TMP/root"
cat > "$T_TMP/bin/codex" <<'STUB'
#!/bin/sh
# Stand-in codex for scripts/tests/canary.sh: never logged in.
case "${1-}" in
  --version) echo "codex-stub 0" ;;
  login) echo "Not logged in" ;;
  *) echo "the codex stand-in was called" >&2; exit 9 ;;
esac
STUB
cat > "$T_TMP/bin/claude" <<'STUB'
#!/bin/sh
# Stand-in claude for scripts/tests/canary.sh. See that file.
if [ "${1-}" = --version ]; then
  echo "claude-stub 0"
  exit 0
fi
{
  echo "--- call"
  for a in "$@"; do printf 'arg:%s\n' "$a"; done
} >> "$STUB_LOG"
n=$(grep -c '^--- call$' "$STUB_LOG")
prompt=$(cat)
printf '%s\n' "$prompt" > "$STUB_DIR/prompt.$n"

model=""
tools=""
restricted=0
allowed=0
bashdenied=0
indis=0
rules=""
prev=""
for a in "$@"; do
  case "$prev" in
    --model) model=$a ;;
    --tools) tools=$a ;;
  esac
  case "$a" in
    --disallowedTools) indis=1 ;;
    -*) indis=0 ;;
  esac
  [ "$indis" = 1 ] && [ "$a" = Bash ] && bashdenied=1
  [ "$a" = --restricted ] && restricted=1
  [ "$a" = --allowedTools ] && allowed=1
  case "$a" in
    'Read('*'/**)') d=${a#Read(}; d=${d%/\*\*)}; rules="$rules
$d" ;;
  esac
  prev=$a
done

if [ "$prompt" = "Reply with the single word ok." ]; then
  printf '{"type":"result","result":"ok","modelUsage":{"%s":{"costUSD":0}}}\n' "$model"
  exit 0
fi

# The write control, on the flags of 0.4.0: runs the one command it is given.
if [ "$allowed" = 1 ]; then
  f=$(printf '%s\n' "$prompt" | sed -n 's/^git show --output=\([^ ]*\) -s HEAD$/\1/p' | head -n 1)
  if [ "${STUB_CTLWRITE:-yes}" = yes ] && [ -n "$f" ]; then
    git show --output="$f" -s HEAD > /dev/null 2>&1
  fi
  echo done
  exit 0
fi

case "${STUB_FORMAT:-}" in
  fail) echo "stub failure" >&2; exit 3 ;;
  empty) exit 0 ;;
  garbage) echo "I would rather not run these."; exit 0 ;;
esac

# What the canary planted, kept so that the test can check the prompt holds
# none of it.
here=$(pwd -P)
cat "$here"/*/plan.txt "$here"/.[!.]*/plan.txt "$here"/../outside/plan.txt > "$STUB_DIR/planted.$n" 2>/dev/null
ls -a "$here"/* "$here"/.[!.]* "$here"/../outside >> "$STUB_DIR/planted.$n" 2>/dev/null

if command -v cygpath > /dev/null 2>&1; then HAVE_CYG=1; else HAVE_CYG=0; fi
cli() {
  if [ "$HAVE_CYG" = 1 ]; then cygpath -m -f -; else cat; fi
}
cwd=$(printf '%s\n' "$here" | cli)
# One table of every file the child could reach: its path in the CLI's form,
# its path for this shell, and whether git ignores it. Built with one find,
# one cygpath and one git check-ignore, so that the probes below cost no
# process each.
find "$here" -name .git -prune -o -type f -print > "$STUB_DIR/files.$n"
( cd "$here/../outside" 2>/dev/null && find "$(pwd -P)" -type f -print ) >> "$STUB_DIR/files.$n"
cli < "$STUB_DIR/files.$n" > "$STUB_DIR/clis.$n"
git -C "$here" check-ignore --stdin < "$STUB_DIR/clis.$n" > "$STUB_DIR/ignored.$n" 2>/dev/null
printf '%s\n' "$prompt" | tr -d '\r' > "$STUB_DIR/in.$n"

rules=$(printf '%s' "$rules" | tr '\n' '|')
LC_ALL=C awk -v cwd="$cwd" -v rules="$rules" -v tools="$tools" \
  -v restricted="$restricted" -v bashdenied="$bashdenied" \
  -v leak=" ${STUB_LEAK:-} " -v refuse=" ${STUB_REFUSE:-} " -v drop=" ${STUB_DROP:-} " \
  -v noend=" ${STUB_NOEND:-} " -v textmatch="${STUB_TEXTMATCH:-}" \
  -v rootnames="${STUB_ROOT_NAMES:-}" -v globignore="${STUB_GLOB_IGNORE:-}" \
  -v write="${STUB_WRITE:-}" -v echo="${STUB_ECHO:-}" \
  -v fclis="$STUB_DIR/clis.$n" -v fpaths="$STUB_DIR/files.$n" -v fign="$STUB_DIR/ignored.$n" '
  function canon(p,   q) {
    while (1) { q = p; sub(/\/[^\/]+\/\.\.\//, "/", q); if (q == p) break; p = q }
    while (1) { q = p; sub(/\/[^\/]+\/\.\.$/, "", q); if (q == p) break; p = q }
    return p
  }
  function under(t, d) { return substr(t "/", 1, length(d) + 1) == d "/" }
  function denied(p,   i, t, d) {
    t = (textmatch == "1") ? p : tolower(canon(p))
    for (i = 1; i <= nr; i++) {
      d = (textmatch == "1") ? rule[i] : tolower(rule[i])
      if (d != "" && under(t, d)) return 1
    }
    return 0
  }
  function outside(p) { return restricted == "1" && !under(tolower(canon(p)), tolower(cwd)) }
  function param(k,   s, i, v) {
    s = ", " rest
    i = index(s, ", " k ": ")
    if (!i) { if (index(rest, k ": ") == 1) i = -1; else return "" }
    if (i == -1) v = substr(rest, length(k) + 3)
    else v = substr(s, i + length(k) + 4)
    i = index(v, ", ")
    if (i) v = substr(v, 1, i - 1)
    return v
  }
  function globre(g,   r, i, c) {
    r = ""
    for (i = 1; i <= length(g); i++) {
      c = substr(g, i, 1)
      if (c == "?") r = r "[^/]"
      else if (c ~ /[.+()^$|\[\]\\{}]/) r = r "\\" c
      else r = r c
    }
    return r
  }
  # select(base, pattern): the files under base that pattern takes, as
  # indexes into the table, in sel[1..ns], and their paths as typed in disp.
  function select(base, pat,   cb, i, rel, dre) {
    ns = 0
    cb = tolower(canon(base))
    if (pat ~ /\/\*$/ && pat != "**/*") dre = "^" globre(substr(pat, 1, length(pat) - 2)) "/[^/]+$"
    for (i = 1; i <= nf; i++) {
      if (!under(tolower(cli[i]), cb)) continue
      rel = substr(cli[i], length(cb) + 2)
      if (pat == "*" && index(rel, "/")) continue
      if (dre != "" && tolower(rel) !~ tolower(dre)) continue
      ns++; sel[ns] = i; disp[ns] = base "/" rel
    }
  }
  function firstline(i,   l) {
    l = ""
    if ((getline l < path[i]) <= 0) l = ""
    close(path[i])
    return l
  }
  BEGIN {
    nr = split(rules, rule, "|")
    while ((getline l < fclis) > 0) { nf++; cli[nf] = l }
    while ((getline l < fpaths) > 0) { np++; path[np] = l }
    while ((getline l < fign) > 0) ign[l] = 1
  }
  {
    prompt = prompt $0 "\n"
    if (!match($0, /^[A-Za-z]+\.[A-Z]\.[A-Za-z]+: /)) next
    id = substr($0, 1, RLENGTH - 2)
    rest = substr($0, RLENGTH + 1)
    nid++; ids[nid] = id; rests[nid] = rest; plines = plines $0 "\n"
  }
  END {
    for (k = 1; k <= nid; k++) {
      id = ids[k]; rest = rests[k]
      if (index(drop, " " id " ")) continue
      tool = rest; sub(/ tool,.*/, "", tool)
      lk = index(leak, " " id " ") > 0
      res = "OK"; body = ""
      have = index("," tools ",", "," tool ",") > 0
      if (tool == "Bash" && bashdenied == "1") have = 0
      if (index(refuse, " " id " ")) { res = "REFUSED"; body = "Permission to use " tool " has been denied." }
      else if (!have && !(tool == "Bash" && write == "1")) { res = "REFUSED"; body = "No such tool available: " tool }
      else if (tool == "Bash") {
        c = param("command"); f = c; sub(/^git show --output=/, "", f); sub(/ .*/, "", f)
        system("git show --output=\"" f "\" -s HEAD > /dev/null 2>&1")
        body = "(no output)"
      } else if (tool == "Read") {
        p = param("file_path")
        if (!lk && (outside(p) || denied(p))) { res = "REFUSED"; body = "Permission to read " p " has been denied." }
        else {
          hit = 0
          for (i = 1; i <= nf; i++) if (tolower(cli[i]) == tolower(canon(p))) { body = firstline(i); hit = 1; break }
          if (!hit) { res = "ERROR"; body = "File does not exist." }
        }
      } else {
        p = param("path")
        if (!lk && (outside(p) || denied(p))) { res = "REFUSED"; body = "Permission to search " p " has been denied." }
        else {
          pat = (tool == "Glob") ? param("pattern") : param("glob")
          if (pat == "") pat = "**/*"
          select(p, pat)
          for (j = 1; j <= ns; j++) {
            i = sel[j]
            # STUB_ROOT_NAMES: a root-level search returns the names of the
            # denied files, and never their content.
            names = 0
            if (!lk && denied(disp[j])) {
              if (pat == "**/*" && rootnames == "1") names = 1
              else continue
            }
            if ((tool == "Grep" || globignore == "1") && (cli[i] in ign)) continue
            if (tool == "Glob" || names) body = body disp[j] "\n"
            else {
              l = firstline(i)
              if (index(l, param("pattern"))) body = body disp[j] ":" l "\n"
            }
          }
          if (body == "") body = "No files found"
          else sub(/\n$/, "", body)
        }
      }
      # STUB_ECHO: every report repeats the probe lines of the prompt, which
      # hold the search word and every path, and nothing it read.
      if (echo == "1") body = plines
      print "=== BEGIN " id " ==="
      print "result: " res
      print body
      if (!index(noend, " " id " ")) print "=== END " id " ==="
    }
  }
' "$STUB_DIR/in.$n"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$T_TMP/bin/claude" "$T_TMP/bin/codex"
PATH="$T_TMP/bin:$PATH"
STUB_LOG="$T_TMP/stub.log"
STUB_DIR="$T_TMP/stub"
export PATH STUB_LOG STUB_DIR
unset COUNCIL_CONFIG STUB_FORMAT STUB_LEAK STUB_REFUSE STUB_DROP STUB_NOEND \
  STUB_TEXTMATCH STUB_ROOT_NAMES STUB_GLOB_IGNORE STUB_WRITE STUB_CTLWRITE STUB_ECHO

# t_detect NAME SH PLUGIN [VAR=VALUE...] -- council-detect.sh of PLUGIN, run
# by SH with the stand-ins and the variables given, from a fresh log. Its
# output goes to $T_TMP/NAME.out, split into NAME.P (the ignored layout),
# NAME.U (the unignored one), NAME.O (outside the root) and NAME.W (the
# write probe and everything after). Its temporary directory is
# $T_TMP/NAME.tmp, checked empty afterwards.
t_detect() {
  _t_name=$1
  _t_sh=$2
  _t_plugin=$3
  shift 3
  T_SKIP=0
  if [ -n "${T_ONLY:-}" ]; then
    case " $T_ONLY " in
      *" $_t_name "*|*" ${_t_name#*-} "*) ;;
      *) T_SKIP=1; return 0 ;;
    esac
  fi
  : > "$STUB_LOG"
  rm -f "$STUB_DIR"/*
  mkdir -p "$T_TMP/$_t_name.tmp"
  T_RC=0
  env TMPDIR="$T_TMP/$_t_name.tmp" COUNCIL_PROBE_MODEL=claude-stub-1 COUNCIL_PROBE_MODELS=claude-stub-1 "$@" \
    "$_t_sh" "$_t_plugin/scripts/council-detect.sh" --root "$T_TMP/root" \
    > "$T_TMP/$_t_name.out" 2> "$T_TMP/$_t_name.err" || T_RC=$?
  sed -n '/^  layout          ignored/,/^  layout          unignored/p' "$T_TMP/$_t_name.out" > "$T_TMP/$_t_name.P"
  sed -n '/^  layout          unignored/,/^  outside /p' "$T_TMP/$_t_name.out" > "$T_TMP/$_t_name.U"
  sed -n '/^  outside /,/^  write /p' "$T_TMP/$_t_name.out" > "$T_TMP/$_t_name.O"
  sed -n '/^  write /,$p' "$T_TMP/$_t_name.out" > "$T_TMP/$_t_name.W"
  t_same "$_t_name: council-detect.sh exits" 0 "$T_RC"
  _t_got=$(ls -A "$T_TMP/$_t_name.tmp")
  t_same "$_t_name: what is left in its temporary directory" "" "$_t_got"
}

# t_key NAME KEY VALUE -- the summary of run NAME says KEY=VALUE.
t_key() {
  _t_got=$(sed -n "s/^$2=//p" "$T_TMP/$1.out")
  t_same "$1: $2" "$3" "$_t_got"
}

# t_calls -- the calls the stand-in claude recorded, the version check aside.
t_calls() {
  grep -c '^--- call$' "$STUB_LOG"
}

# t_label SPELLING -> the label council-detect.sh prints for it.
t_label() {
  case "$1" in
    L) printf 'path written out' ;;
    U) printf 'path in upper case' ;;
    D) printf 'path through sub/..' ;;
    N) printf 'search naming the directory' ;;
    Q) printf 'search naming it through a ?' ;;
    R) printf 'root-level search' ;;
    O) printf 'absolute path outside the root' ;;
    A) printf 'path out of the root through ..' ;;
  esac
}

# t_line NAME BLOCK STATUS TOOL SPELLING DETAIL -- BLOCK of run NAME holds
# the line for TOOL and SPELLING with STATUS and DETAIL, exactly once.
t_line() {
  _t_want=$(printf '  %-16s%-5s %-32s %s' "$3" "$4" "$(t_label "$5")" "$6")
  _t_got=$(grep -c -x -F -e "$_t_want" "$T_TMP/$1.$2")
  t_same "$1, block $2: $3 $4 $(t_label "$5")" 1 "$_t_got"
}

# t_status NAME BLOCK STATUS TOOL SPELLING -- BLOCK of run NAME holds the
# line for TOOL and SPELLING with STATUS, whatever its detail, exactly once.
t_status() {
  _t_want=$(printf '  %-16s%-5s %-32s ' "$3" "$4" "$(t_label "$5")")
  _t_got=$(grep -c -F -e "$_t_want" "$T_TMP/$1.$2")
  t_same "$1, block $2: $3 $4 $(t_label "$5")" 1 "$_t_got"
}

T_BLOCKED="not reached"
T_HIDDEN="not reached, and nor was the ignored control beside it: git's ignore file hid both, so this says nothing about the rule"

# T_SHELLS, when set, names the shells to run council-detect.sh with; by
# default sh, and /usr/bin/dash where it exists.
if [ -z "${T_SHELLS:-}" ]; then
  T_SHELLS="sh"
  [ -x /usr/bin/dash ] && T_SHELLS="$T_SHELLS /usr/bin/dash"
fi
for T_SH in $T_SHELLS; do
  T_N=${T_SH##*/}

  # ------------------------------------------------------------------------
  echo "$T_N: a child that behaves as measured"
  R="$T_N-measured"
  t_detect "$R" "$T_SH" "$T_PLUGIN"
  t_key "$R" DENY_RULE_EFFECTIVE yes
  t_key "$R" OUTSIDE_ROOT_REFUSED yes
  t_key "$R" WRITE_REFUSED yes
  for _t_s in L U D; do
    t_line "$R" P ok Read "$_t_s" "$T_BLOCKED"
    t_line "$R" U ok Read "$_t_s" "$T_BLOCKED"
  done
  for _t_s in L U D N Q; do
    t_line "$R" P ok Glob "$_t_s" "$T_BLOCKED"
    t_line "$R" U ok Glob "$_t_s" "$T_BLOCKED"
    t_line "$R" P "hidden by git" Grep "$_t_s" "$T_HIDDEN"
    t_line "$R" U ok Grep "$_t_s" "$T_BLOCKED"
  done
  t_line "$R" P "hidden by git" Grep R "$T_HIDDEN"
  t_line "$R" U ok Grep R "$T_BLOCKED"
  t_line "$R" P note Glob R "names not listed (names only; Glob returns no content)"
  t_line "$R" U note Glob R "names not listed (names only; Glob returns no content)"
  for _t_t in Read Glob Grep; do
    t_line "$R" O ok "$_t_t" O "$T_BLOCKED"
    t_line "$R" O ok "$_t_t" A "$T_BLOCKED"
  done
  t_has "$R: the write probe" "$T_TMP/$R.W" "  ok              no file appeared, and the control on the flags of 0.4.0"
  t_has "$R: the probe count" "$T_TMP/$R.out" "  probes          74 in one call; 2 call(s) in all"
  t_lacks "$R: the output" "$T_TMP/$R.out" "FAIL"
  t_lacks "$R: the output" "$T_TMP/$R.out" "untested"
  t_same "$R: calls the stand-in recorded (one model, the canary, the write control)" 3 "$(t_calls)"
  # The canary's child is started as a seat is: the seat flags, Bash and the
  # editors denied by name, and the two rules. The control is not.
  _t_main=$(awk '/^--- call$/ { c++ } c == 2' "$STUB_LOG")
  _t_ctl=$(awk '/^--- call$/ { c++ } c == 3' "$STUB_LOG")
  printf '%s\n' "$_t_main" > "$T_TMP/$R.main"
  printf '%s\n' "$_t_ctl" > "$T_TMP/$R.ctl"
  for _t_a in --restricted --tools Read,Glob,Grep --setting-sources project,local --strict-mcp-config --disable-slash-commands --disallowedTools Bash Edit Write NotebookEdit; do
    t_has "$R: the canary's child, argument" "$T_TMP/$R.main" "arg:$_t_a"
  done
  _t_got=$(grep -c '^arg:Read(.*/\*\*)$' "$T_TMP/$R.main")
  t_same "$R: the canary's child, deny rules" 2 "$_t_got"
  t_lacks "$R: the canary's child" "$T_TMP/$R.main" "arg:--allowedTools"
  t_has "$R: the write control" "$T_TMP/$R.ctl" "arg:--allowedTools"
  t_has "$R: the write control" "$T_TMP/$R.ctl" "arg:Bash(git show:*)"
  t_lacks "$R: the write control" "$T_TMP/$R.ctl" "arg:--tools"
  _t_got=$(grep -c -x 'arg:Bash' "$T_TMP/$R.ctl")
  t_same "$R: the write control, Bash denied by name" 0 "$_t_got"
  # No planted token is in the prompt: the evidence is not the search term.
  _t_got=0
  for _t_k in $(sed -n 's/^ledgerline //p' "$STUB_DIR/planted.2") \
              $(sed -n 's/^notes-\([0-9a-f]*\)\.txt$/\1/p' "$STUB_DIR/planted.2"); do
    grep -F -q -e "$_t_k" "$STUB_DIR/prompt.2" && _t_got=$((_t_got + 1))
  done
  t_same "$R: planted tokens found in the prompt" 0 "$_t_got"
  _t_got=$(sed -n 's/^ledgerline //p' "$STUB_DIR/planted.2" | grep -c .)
  t_same "$R: planted content tokens the stand-in saw" 6 "$_t_got"
  t_has "$R: the prompt" "$STUB_DIR/prompt.2" "ledgerline"
  # Each spelling is spelled as its label says, and the root-level search
  # names no directory.
  T_ROOT=$(sed -n 's#^Read\.L\.PC: Read tool, file_path: \(.*\)/\.control/plan\.txt$#\1#p' "$STUB_DIR/prompt.2")
  T_OUT="${T_ROOT%/*}/outside"
  for _t_p in \
    "Read.L.PD: Read tool, file_path: $T_ROOT/.council/plan.txt" \
    "Read.U.PD: Read tool, file_path: $T_ROOT/.COUNCIL/plan.txt" \
    "Read.D.UD: Read tool, file_path: $T_ROOT/sub/../tracked-run/plan.txt" \
    "Glob.U.UD: Glob tool, path: $T_ROOT/TRACKED-RUN, pattern: *" \
    "Glob.N.PD: Glob tool, path: $T_ROOT, pattern: .council/*" \
    "Glob.Q.PD: Glob tool, path: $T_ROOT, pattern: .counci?/*" \
    "Grep.L.UD: Grep tool, path: $T_ROOT/tracked-run, pattern: ledgerline, output_mode: content" \
    "Grep.Q.UD: Grep tool, path: $T_ROOT, glob: tracked-ru?/*, pattern: ledgerline, output_mode: content" \
    "Glob.R.root: Glob tool, path: $T_ROOT, pattern: **/*" \
    "Grep.R.root: Grep tool, path: $T_ROOT, pattern: ledgerline, output_mode: content" \
    "Read.O.OUT: Read tool, file_path: $T_OUT/plan.txt" \
    "Read.A.OUT: Read tool, file_path: $T_ROOT/../outside/plan.txt" \
    "Grep.A.OUT: Grep tool, path: $T_ROOT/../outside, pattern: ledgerline, output_mode: content"; do
    _t_got=$(grep -c -x -F -e "$_t_p" "$STUB_DIR/prompt.2")
    t_same "$R: the prompt holds the probe [$_t_p]" 1 "$_t_got"
  done
  _t_got=$(grep -c -x -E 'Bash\.W\.write: Bash tool, command: git show --output=written-[0-9a-f]{16}\.txt -s HEAD' "$STUB_DIR/prompt.2")
  t_same "$R: the prompt holds the write probe" 1 "$_t_got"

  # ------------------------------------------------------------------------
  echo "$T_N: every route refused by the rule leaks, one line each"
  T_ALL=""
  for _t_t in Read Glob Grep; do
    for _t_s in L U D N Q; do
      T_ALL="$T_ALL $_t_t.$_t_s.PD $_t_t.$_t_s.UD"
    done
    T_ALL="$T_ALL $_t_t.R.root $_t_t.O.OUT $_t_t.A.OUT"
  done
  R="$T_N-leaks"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_LEAK="$T_ALL"
  t_key "$R" DENY_RULE_EFFECTIVE no
  t_key "$R" OUTSIDE_ROOT_REFUSED no
  t_key "$R" WRITE_REFUSED yes
  for _t_s in L U D; do
    t_line "$R" P FAIL Read "$_t_s" "REACHED (content)"
    t_line "$R" U FAIL Read "$_t_s" "REACHED (content)"
  done
  for _t_s in L U D N Q; do
    t_line "$R" P FAIL Glob "$_t_s" "REACHED (name)"
    t_line "$R" U FAIL Glob "$_t_s" "REACHED (name)"
    # Grep honours git's ignore file whatever the rule does, so in the
    # ignored layout it is still hidden; the unignored layout shows it.
    t_line "$R" P "hidden by git" Grep "$_t_s" "$T_HIDDEN"
    t_line "$R" U FAIL Grep "$_t_s" "REACHED (content)"
  done
  t_line "$R" P "hidden by git" Grep R "$T_HIDDEN"
  t_line "$R" U FAIL Grep R "REACHED (content)"
  t_line "$R" P note Glob R "the run directory's file names were LISTED (names only; a note)"
  t_line "$R" U note Glob R "the run directory's file names were LISTED (names only; a note)"
  t_line "$R" O FAIL Read O "REACHED (content)"
  t_line "$R" O FAIL Read A "REACHED (content)"
  t_line "$R" O FAIL Glob O "REACHED (name)"
  t_line "$R" O FAIL Glob A "REACHED (name)"
  t_line "$R" O FAIL Grep O "REACHED (content)"
  t_line "$R" O FAIL Grep A "REACHED (content)"
  t_has "$R: the summary line" "$T_TMP/$R.W" "  FAIL            the run directory was read on a route marked FAIL above."

  # ------------------------------------------------------------------------
  echo "$T_N: a rule matched against text, as written"
  R="$T_N-text"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_TEXTMATCH=1
  t_key "$R" DENY_RULE_EFFECTIVE no
  t_line "$R" U FAIL Read U "REACHED (content)"
  t_line "$R" U FAIL Read D "REACHED (content)"
  t_line "$R" U ok Read L "$T_BLOCKED"
  t_line "$R" U FAIL Glob U "REACHED (name)"
  t_line "$R" U FAIL Grep D "REACHED (content)"

  # ------------------------------------------------------------------------
  echo "$T_N: one route alone decides the summary"
  R="$T_N-one"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_LEAK="Grep.R.root"
  t_key "$R" DENY_RULE_EFFECTIVE no
  t_key "$R" OUTSIDE_ROOT_REFUSED yes
  t_line "$R" U FAIL Grep R "REACHED (content)"
  t_line "$R" P "hidden by git" Grep R "$T_HIDDEN"
  _t_got=$(grep -c '^  FAIL ' "$T_TMP/$R.out")
  t_same "$R: FAIL lines (the route, and the summary)" 2 "$_t_got"

  R="$T_N-one-p"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_LEAK="Read.L.PD"
  t_key "$R" DENY_RULE_EFFECTIVE no
  t_line "$R" P FAIL Read L "REACHED (content)"
  t_line "$R" U ok Read L "$T_BLOCKED"
  _t_got=$(grep -c '^  FAIL ' "$T_TMP/$R.out")
  t_same "$R: FAIL lines (the route, and the summary)" 2 "$_t_got"

  # ------------------------------------------------------------------------
  echo "$T_N: a control that is not reached makes its route untested"
  T_CTL=""
  for _t_t in Read Glob Grep; do
    for _t_s in L U D N Q; do
      T_CTL="$T_CTL $_t_t.$_t_s.PC $_t_t.$_t_s.UC"
    done
  done
  R="$T_N-controls"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_REFUSE="$T_CTL"
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_key "$R" OUTSIDE_ROOT_REFUSED untested
  for _t_s in L U D; do
    t_status "$R" P untested Read "$_t_s"
    t_status "$R" U untested Read "$_t_s"
  done
  for _t_s in L U D N Q; do
    t_status "$R" P untested Glob "$_t_s"
    t_status "$R" U untested Grep "$_t_s"
  done
  t_line "$R" U untested Read L "its control (Read.L.UC) was not reached, so a refusal here may only mean the route never worked"
  t_line "$R" O untested Read O "its control (Read.L.PC) was not reached, so a refusal here may only mean the route never worked"
  t_line "$R" O untested Grep A "its control (Grep.D.PC) was not reached, so a refusal here may only mean the route never worked"
  t_lacks "$R: the output" "$T_TMP/$R.out" "  ok              in both layouts"

  R="$T_N-ignored-dropped"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_DROP="Glob.L.PI"
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_line "$R" P untested Glob L "no well-formed report came back for its ignored control (Glob.L.PI)"
  t_line "$R" U ok Glob L "$T_BLOCKED"

  R="$T_N-glob-ignores"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_GLOB_IGNORE=1
  t_key "$R" DENY_RULE_EFFECTIVE yes
  t_line "$R" P "hidden by git" Glob L "$T_HIDDEN"
  t_line "$R" U ok Glob L "$T_BLOCKED"
  t_line "$R" P note Glob R "names not listed, and git hid the ignored control too"
  t_has "$R: the summary" "$T_TMP/$R.W" "Routes hidden by git in the ignored layout were tested for the"

  # ------------------------------------------------------------------------
  echo "$T_N: names at the root are a note, not a verdict"
  R="$T_N-names"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_ROOT_NAMES=1
  t_key "$R" DENY_RULE_EFFECTIVE yes
  t_line "$R" P note Glob R "the run directory's file names were LISTED (names only; a note)"
  t_line "$R" U note Glob R "the run directory's file names were LISTED (names only; a note)"
  t_line "$R" U ok Grep R "$T_BLOCKED"
  t_line "$R" U note Grep R "the run directory's file names were LISTED (names only; a note)"
  t_line "$R" P "hidden by git" Grep R "$T_HIDDEN"
  t_has "$R: the note" "$T_TMP/$R.out" "verdict: a run names its files by letter and by role, never by"

  # ------------------------------------------------------------------------
  echo "$T_N: replies that cannot be read"
  R="$T_N-empty"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_FORMAT=empty
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_key "$R" OUTSIDE_ROOT_REFUSED untested
  t_key "$R" WRITE_REFUSED untested
  t_line "$R" P untested Read L "no well-formed report came back for its control (Read.L.PC)"
  t_has "$R: the write probe" "$T_TMP/$R.W" "  untested        no well-formed report came back for the write probe"
  t_same "$R: calls (no write control)" 2 "$(t_calls)"
  t_lacks "$R: the output" "$T_TMP/$R.out" "FAIL"

  R="$T_N-garbage"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_FORMAT=garbage
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_key "$R" WRITE_REFUSED untested

  R="$T_N-noend"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_NOEND="Read.D.UD"
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_line "$R" U untested Read D "no well-formed report came back for it (Read.D.UD)"
  t_line "$R" U ok Read L "$T_BLOCKED"

  R="$T_N-fail"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_FORMAT=fail
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_key "$R" OUTSIDE_ROOT_REFUSED untested
  t_key "$R" WRITE_REFUSED untested
  t_has "$R: the note" "$T_TMP/$R.W" "  note            the canary call exited with status 3, so nothing below can"
  t_has "$R: the write probe" "$T_TMP/$R.W" "the call exited with status 3, so the write probe may never have been tried"

  # A full, well-formed report from a call that exited non-zero: every route
  # is judged as usual, and no summary can be yes.
  R="$T_N-exit"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_EXIT=3
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_key "$R" OUTSIDE_ROOT_REFUSED untested
  t_key "$R" WRITE_REFUSED untested
  t_line "$R" U ok Read L "$T_BLOCKED"
  t_has "$R: the note" "$T_TMP/$R.W" "  note            the canary call exited with status 3, so nothing below can"

  R="$T_N-echo"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_ECHO=1
  t_key "$R" DENY_RULE_EFFECTIVE untested
  t_key "$R" OUTSIDE_ROOT_REFUSED untested
  t_lacks "$R: the output" "$T_TMP/$R.out" "FAIL"
  t_status "$R" U untested Grep R

  # ------------------------------------------------------------------------
  echo "$T_N: the write probe and its control"
  R="$T_N-writes"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_WRITE=1
  t_key "$R" WRITE_REFUSED no
  t_key "$R" DENY_RULE_EFFECTIVE yes
  t_has "$R: the write probe" "$T_TMP/$R.W" "appeared inside the root"
  t_same "$R: calls (no write control)" 2 "$(t_calls)"

  R="$T_N-ctl-nowrite"
  t_detect "$R" "$T_SH" "$T_PLUGIN" STUB_CTLWRITE=no
  t_key "$R" WRITE_REFUSED untested
  t_key "$R" DENY_RULE_EFFECTIVE yes
  t_has "$R: the write probe" "$T_TMP/$R.W" "  untested        the control on 0.4.0's flags did not write its file either (it exited with status 0), so a refusal under the current flags shows nothing"
  t_same "$R: calls (with the write control)" 3 "$(t_calls)"
done

# ---------------------------------------------------------------------------
echo "Seat flags the canary does not know"

# A copy of the plugin whose council_seat_flags is changed, the one input the
# canary reads from lib.sh.
t_plugin_with() {
  rm -rf "$T_TMP/plugin"
  mkdir -p "$T_TMP/plugin"
  cp -R "$T_PLUGIN/scripts" "$T_PLUGIN/config" "$T_PLUGIN/agents" "$T_TMP/plugin/"
  sed "s/--tools Read,Glob,Grep/$1/" "$T_PLUGIN/scripts/lib.sh" > "$T_TMP/plugin/scripts/lib.sh"
}
t_plugin_with "--tools Read,Glob,Grep,WebFetch"
R="extra-tool"
t_detect "$R" sh "$T_TMP/plugin"
t_key "$R" DENY_RULE_EFFECTIVE untested
t_key "$R" OUTSIDE_ROOT_REFUSED untested
t_key "$R" WRITE_REFUSED untested
t_has "$R: the reason" "$T_TMP/$R.W" "  untested        the seats also hold: WebFetch. This canary has no route for it,"
t_line "$R" U ok Read L "$T_BLOCKED"

t_plugin_with "--tools-gone Read"
R="no-tools"
t_detect "$R" sh "$T_TMP/plugin"
t_key "$R" DENY_RULE_EFFECTIVE untested
t_key "$R" WRITE_REFUSED untested
t_has "$R: the reason" "$T_TMP/$R.out" "  untested        no route was probed: council_seat_flags does not give exactly one --tools list"
t_same "$R: calls (the model only)" 1 "$(t_calls)"

t_plugin_with "--tools Read"
R="read-only"
t_detect "$R" sh "$T_TMP/plugin"
t_key "$R" DENY_RULE_EFFECTIVE yes
t_has "$R: the probe count" "$T_TMP/$R.out" "  probes          18 in one call; 2 call(s) in all"
t_lacks "$R: no Glob line" "$T_TMP/$R.out" "Glob "

T_SKIP=0
echo "--no-model-check"
R="no-model-check"
: > "$STUB_LOG"
T_RC=0
TMPDIR="$T_TMP" sh "$T_PLUGIN/scripts/council-detect.sh" --root "$T_TMP/root" --no-model-check > "$T_TMP/$R.out" 2>&1 || T_RC=$?
t_same "$R: exits" 0 "$T_RC"
t_key "$R" DENY_RULE_EFFECTIVE unknown
t_key "$R" OUTSIDE_ROOT_REFUSED unknown
t_key "$R" WRITE_REFUSED unknown
t_same "$R: calls" 0 "$(t_calls)"

echo "House rule"

_t_got=$(tr -cd "$(printf '\140')" < "$T_DIR/canary.sh" | wc -c | tr -d ' ')
t_same "scripts/tests/canary.sh: backquote characters" 0 "$_t_got"
_t_got=$(tr -cd "$(printf '\140')" < "$T_PLUGIN/scripts/council-detect.sh" | wc -c | tr -d ' ')
t_same "scripts/council-detect.sh: backquote characters" 0 "$_t_got"
_t_got=$(LC_ALL=C grep -c '[^ -~	]' "$T_PLUGIN/scripts/council-detect.sh")
t_same "scripts/council-detect.sh: lines with a character that is not printable ASCII" 0 "$_t_got"

echo
echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
