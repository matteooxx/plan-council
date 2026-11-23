#!/bin/sh
# Tests for the repository block: what the runner tells the seats about the
# repository, since no seat has a shell to ask git itself.
# council_git_facts, council_git_block and council_check_prompts_identical in
# ../lib.sh, and the prompts council-plan.sh and council-review.sh send.
#
# Usage: sh scripts/tests/repository-block.sh
#        dash scripts/tests/repository-block.sh
#
# Every assertion names the function or script it runs and the output or
# file it reads, and prints one line. The exit status is non-zero when any
# assertion failed.
#
# No model is called. Every repository is built by this file in a temporary
# directory, which is removed on exit, and GIT_CEILING_DIRECTORIES keeps git
# from finding any repository above it. A stand-in "claude", first on PATH,
# saves the prompt it receives on stdin, byte for byte, to one file per call,
# and answers with a plain text long enough to be accepted. The runners are
# called with --no-seat-check and no mode, so the only calls are the seats'
# own, and the assertions read the exact bytes each seat was sent.
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

# t_count LABEL N FILE TEXT -- exactly N lines of FILE are TEXT, whole.
t_count() {
  _t_got=$(grep -c -x -F -e "$4" "$3" 2>/dev/null)
  t_same "$1: lines that are [$4]" "$2" "$_t_got"
}

GIT_CEILING_DIRECTORIES=$T_TMP
export GIT_CEILING_DIRECTORIES

# t_git DIR ARGS... -- git in DIR, with an identity and no hooks, signing or
# user configuration of the machine's own, so a commit made here cannot
# depend on how this machine is set up.
t_git() {
  _t_d=$1
  shift
  ( cd "$_t_d" && HOME="$T_TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T_TMP/home/gitconfig" \
    git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
      -c core.hooksPath="$T_TMP/no-hooks" -c init.defaultBranch=main -c core.autocrlf=false "$@" )
}
mkdir -p "$T_TMP/home" "$T_TMP/no-hooks"
: > "$T_TMP/home/gitconfig"

# t_repo DIR -- a repository in DIR with one commit, a.txt.
t_repo() {
  mkdir -p "$1"
  t_git "$1" init -q
  printf 'one\n' > "$1/a.txt"
  t_git "$1" add a.txt
  t_git "$1" commit -q -m one
}

# t_facts DIR -- council_git_facts DIR, then one line per variable, in
# $T_TMP/facts.
t_facts() {
  council_git_facts "$1"
  {
    printf 'HEAD=%s\n' "$COUNCIL_GIT_HEAD"
    printf 'BRANCH=%s\n' "$COUNCIL_GIT_BRANCH"
    printf 'TREE=%s\n' "$COUNCIL_GIT_TREE"
    printf 'STATUS=%s\n' "$COUNCIL_GIT_STATUS"
  } > "$T_TMP/facts"
}

# ---------------------------------------------------------------------------
echo "council_git_facts, one repository per case"

R="$T_TMP/clean"
t_repo "$R"
T_HEAD=$(t_git "$R" rev-parse HEAD)
t_facts "$R"
t_same "clean: COUNCIL_GIT_HEAD is git rev-parse HEAD" "$T_HEAD" "$COUNCIL_GIT_HEAD"
t_same "clean: COUNCIL_GIT_BRANCH" main "$COUNCIL_GIT_BRANCH"
t_same "clean: COUNCIL_GIT_TREE" clean "$COUNCIL_GIT_TREE"
t_same "clean: COUNCIL_GIT_STATUS" "" "$COUNCIL_GIT_STATUS"
if council_git_is_commit "$COUNCIL_GIT_HEAD"; then _t_got=yes; else _t_got=no; fi
t_same "clean: council_git_is_commit on that HEAD" yes "$_t_got"

R="$T_TMP/dirty"
t_repo "$R"
printf 'two\n' >> "$R/a.txt"
t_facts "$R"
t_same "dirty: COUNCIL_GIT_TREE" dirty "$COUNCIL_GIT_TREE"
t_same "dirty: COUNCIL_GIT_STATUS, verbatim" " M a.txt" "$COUNCIL_GIT_STATUS"

R="$T_TMP/untracked"
t_repo "$R"
printf 'scratch\n' > "$R/scratch.txt"
t_facts "$R"
t_same "untracked: COUNCIL_GIT_TREE" dirty "$COUNCIL_GIT_TREE"
t_same "untracked: COUNCIL_GIT_STATUS names the untracked file" "?? scratch.txt" "$COUNCIL_GIT_STATUS"

R="$T_TMP/ignored"
t_repo "$R"
mkdir -p "$R/.git/info"
printf 'scratch.txt\n' > "$R/.git/info/exclude"
printf 'scratch\n' > "$R/scratch.txt"
t_facts "$R"
t_same "an ignored untracked file: COUNCIL_GIT_TREE" clean "$COUNCIL_GIT_TREE"

R="$T_TMP/subroot"
t_repo "$R"
mkdir -p "$R/sub"
printf 'x\n' > "$R/sub/in.txt"
t_git "$R" add sub/in.txt
t_git "$R" commit -q -m sub
printf 'scratch\n' > "$R/outside.txt"
t_facts "$R/sub"
t_same "a root that is a subdirectory: COUNCIL_GIT_STATUS names a file outside it" "?? outside.txt" "$COUNCIL_GIT_STATUS"

R="$T_TMP/empty"
mkdir -p "$R"
t_git "$R" init -q
_t_rc=0
t_git "$R" rev-parse --verify -q HEAD > /dev/null 2>&1 || _t_rc=$?
t_same "no commits: git rev-parse --verify HEAD fails, as the case needs" 1 "$_t_rc"
t_facts "$R"
t_same "no commits: COUNCIL_GIT_HEAD" "none: HEAD names no commit (a repository with no commits yet, or a branch with none)" "$COUNCIL_GIT_HEAD"
t_same "no commits: COUNCIL_GIT_BRANCH, the unborn branch" main "$COUNCIL_GIT_BRANCH"
t_same "no commits, no files: COUNCIL_GIT_TREE" clean "$COUNCIL_GIT_TREE"
printf 'x\n' > "$R/new.txt"
t_facts "$R"
t_same "no commits, one file: COUNCIL_GIT_STATUS" "?? new.txt" "$COUNCIL_GIT_STATUS"

R="$T_TMP/detached"
t_repo "$R"
t_git "$R" checkout -q --detach
t_facts "$R"
t_same "detached: COUNCIL_GIT_BRANCH" "none: detached HEAD" "$COUNCIL_GIT_BRANCH"
t_same "detached: COUNCIL_GIT_HEAD" "$(t_git "$R" rev-parse HEAD)" "$COUNCIL_GIT_HEAD"
t_same "detached: COUNCIL_GIT_TREE" clean "$COUNCIL_GIT_TREE"

R="$T_TMP/plain"
mkdir -p "$R"
t_facts "$R"
t_same "not a work tree: COUNCIL_GIT_HEAD" "none: not a git work tree" "$COUNCIL_GIT_HEAD"
t_same "not a work tree: COUNCIL_GIT_BRANCH" "none: not a git work tree" "$COUNCIL_GIT_BRANCH"
t_same "not a work tree: COUNCIL_GIT_TREE" "not a git work tree" "$COUNCIL_GIT_TREE"

R="$T_TMP/clean"
mkdir -p "$T_TMP/nogit"
(
  PATH="$T_TMP/nogit"
  council_git_facts "$R"
  printf '%s|%s|%s|%s\n' "$COUNCIL_GIT_HEAD" "$COUNCIL_GIT_BRANCH" "$COUNCIL_GIT_TREE" "$COUNCIL_GIT_STATUS"
) > "$T_TMP/nogit.out"
t_same "git absent from PATH: council_git_facts" "unknown: git is not on PATH|unknown: git is not on PATH|unknown: git is not on PATH|" "$(cat "$T_TMP/nogit.out")"

# The run directory under the default layout: .council holds a .gitignore of
# "*", which covers itself and every run in it.
R="$T_TMP/layout"
t_repo "$R"
council_ignore_dir "$R/.council"
mkdir -p "$R/.council/run-1"
printf 'planner.A=claude\n' > "$R/.council/run-1/council.txt"
t_facts "$R"
t_same "a run under .council: COUNCIL_GIT_TREE" clean "$COUNCIL_GIT_TREE"
# A run placed with --out at a path git does not ignore: empty, as
# council-plan.sh requires it to be when the block is read, git lists nothing.
mkdir -p "$R/runs/run-2"
t_facts "$R"
t_same "an empty --out directory git does not ignore: COUNCIL_GIT_TREE" clean "$COUNCIL_GIT_TREE"
# An earlier run there, with files in it, is named, as a directory.
printf 'planner.A=claude\n' > "$R/runs/run-2/council.txt"
t_facts "$R"
t_same "an earlier run at a path git does not ignore: COUNCIL_GIT_STATUS" "?? runs/" "$COUNCIL_GIT_STATUS"

# ---------------------------------------------------------------------------
echo "council_git_block"

council_git_block "T" "I" "h" "b" "clean" "" "" > "$T_TMP/block"
printf '\n---\n\n# T\n\nI\n\n~~~\nHEAD: h\nbranch: b\ntree: clean\n~~~\n' > "$T_TMP/block.want"
if cmp -s "$T_TMP/block" "$T_TMP/block.want"; then _t_got=same; else _t_got=$(od -c "$T_TMP/block" | head -n 5); fi
t_same "council_git_block, a clean tree, byte for byte" same "$_t_got"
council_git_block "T" "I" "h" "b" "dirty" "?? ~~~~" "x" > "$T_TMP/block"
t_count "council_git_block, a file name of four tildes: the fence" 2 "$T_TMP/block" "~~~~~"
t_has "council_git_block, the status" "$T_TMP/block" "git status --porcelain:"
t_count "council_git_block, the status line" 1 "$T_TMP/block" "?? ~~~~"
t_count "council_git_block, the extra line" 1 "$T_TMP/block" "x"

# ---------------------------------------------------------------------------
echo "council_check_prompts_identical"

S="$T_TMP/identity"
mkdir -p "$S"
printf '# instructions\n\nthe brief\n' > "$S/base.md"
R="$T_TMP/clean"
council_git_facts "$R"
council_git_block "The repository at planning" "I" "$COUNCIL_GIT_HEAD" "$COUNCIL_GIT_BRANCH" "$COUNCIL_GIT_TREE" "$COUNCIL_GIT_STATUS" "" > "$S/block-1.md"
cat "$S/base.md" "$S/block-1.md" > "$S/prompt.md"
cp "$S/prompt.md" "$S/prompt-A.md"
cp "$S/prompt.md" "$S/prompt-B.md"
_t_rc=0
( council_check_prompts_identical "$S/prompt.md" "$S" A B ) 2> "$S/err" || _t_rc=$?
t_same "the block built once, in the shared prompt: council_check_prompts_identical returns" 0 "$_t_rc"
# Built per planner: the shared prompt without the block, each copy with it.
cp "$S/base.md" "$S/prompt.md"
cat "$S/base.md" "$S/block-1.md" > "$S/prompt-A.md"
cat "$S/base.md" "$S/block-1.md" > "$S/prompt-B.md"
_t_rc=0
( council_check_prompts_identical "$S/prompt.md" "$S" A B ) 2> "$S/err" || _t_rc=$?
t_same "the block built per planner: council_check_prompts_identical returns" 1 "$_t_rc"
t_has "the block built per planner: the refusal" "$S/err" "prompt for planner A differs"
# Built per planner after a commit landed between the two: planner B is told
# another HEAD.
cat "$S/base.md" "$S/block-1.md" > "$S/prompt.md"
cp "$S/prompt.md" "$S/prompt-A.md"
printf 'more\n' >> "$R/a.txt"
t_git "$R" commit -q -a -m two
council_git_facts "$R"
council_git_block "The repository at planning" "I" "$COUNCIL_GIT_HEAD" "$COUNCIL_GIT_BRANCH" "$COUNCIL_GIT_TREE" "$COUNCIL_GIT_STATUS" "" > "$S/block-2.md"
cat "$S/base.md" "$S/block-2.md" > "$S/prompt-B.md"
_t_rc=0
( council_check_prompts_identical "$S/prompt.md" "$S" A B ) 2> "$S/err" || _t_rc=$?
t_same "planner B told another HEAD: council_check_prompts_identical returns" 1 "$_t_rc"
t_has "planner B told another HEAD: the refusal" "$S/err" "prompt for planner B differs"

# ---------------------------------------------------------------------------
# The stand-in claude: saves its stdin, answers in plain text.
mkdir -p "$T_TMP/bin" "$T_TMP/tmp" "$T_TMP/in"
cat > "$T_TMP/bin/claude" <<'STUB'
#!/bin/sh
# Stand-in claude for scripts/tests/repository-block.sh. See that file.
# The name carries the phase as well as the pid: an attack stand-in and the
# arbiter one can share a pid, because Cygwin reuses a freed one and the
# arbiter runs after the attacks. With the pid alone, one capture then
# overwrote another and the suite failed 5 assertions once, intermittently.
cat > "$STUB_IN/in.${COUNCIL_PHASE:-none}.$$"
i=0
while [ "$i" -lt 12 ]; do
  echo "Plain answer line $i, written as text, as a seat writes a plan or an attack."
  i=$((i + 1))
done
echo "PASS"
exit 0
STUB
chmod +x "$T_TMP/bin/claude"
PATH="$T_TMP/bin:$PATH"
STUB_IN="$T_TMP/in"
COUNCIL_CONFIG=""
unset COUNCIL_CONFIG COUNCIL_MODE
export PATH STUB_IN

# t_prompts -- the prompts the stand-in saved, one path per line, sorted.
t_prompts() {
  ls "$STUB_IN"/in.* 2>/dev/null | sort
}

# t_inputs_clear -- forget the prompts saved so far.
t_inputs_clear() {
  rm -f "$STUB_IN"/in.*
}

# t_load -- T_PS the saved prompts, T_NP how many, P1 and P2 the first two
# (empty when missing, so an assertion on them fails rather than the file
# stopping on an unset parameter).
t_load() {
  T_PS=$(t_prompts)
  T_NP=$(printf '%s\n' "$T_PS" | grep -c .)
  P1=$(printf '%s\n' "$T_PS" | sed -n 1p)
  P2=$(printf '%s\n' "$T_PS" | sed -n 2p)
}

# t_plan SH ROOT [ARGS...] -- council-plan.sh, run by SH, on a brief, with two
# claude planners. T_RC is its exit status, T_RUN the run directory it
# printed, $T_TMP/plan.err its messages.
printf '# A brief\n\nPlan one small change.\n' > "$T_TMP/brief.md"
t_plan() {
  _t_sh=$1
  _t_root=$2
  shift 2
  t_inputs_clear
  T_RC=0
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$_t_sh" "$T_PLUGIN/scripts/council-plan.sh" "$T_TMP/brief.md" --root "$_t_root" --no-seat-check "$@" \
    > "$T_TMP/plan.out" 2> "$T_TMP/plan.err" || T_RC=$?
  T_RUN=$(tail -n 1 "$T_TMP/plan.out")
}

# t_review SH RUN [ARGS...] -- council-review.sh, run by SH, on RUN.
t_review() {
  _t_sh=$1
  _t_run=$2
  shift 2
  t_inputs_clear
  T_RC=0
  COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
    "$_t_sh" "$T_PLUGIN/scripts/council-review.sh" "$_t_run" --no-seat-check "$@" \
    > "$T_TMP/review.out" 2> "$T_TMP/review.err" || T_RC=$?
}

# The fixed start of the line council_run_parallel prints before it starts
# any seat; the staging directory's path follows it, to the end of the line.
T_STAGE_SAY="plan-council: staging directory, where this phase writes answer-*.md; it is deleted when this script exits, and a kill can make it exit, so if the run never returns, copy answer-*.md out of it before you kill it: "

T_SHELLS="sh"
[ -x /usr/bin/dash ] && T_SHELLS="$T_SHELLS /usr/bin/dash"
for T_SH in $T_SHELLS; do
  T_N=${T_SH##*/}

  # ------------------------------------------------------------------------
  echo "$T_N council-plan.sh: the block, once, in the shared prompt"

  R="$T_TMP/$T_N-plan"
  t_repo "$R"
  T_HEAD=$(t_git "$R" rev-parse HEAD)
  t_plan "$T_SH" "$R"
  t_same "$T_N council-plan.sh, a clean tree: exits" 0 "$T_RC"
  # The staging path, printed once. The directory is gone by now (the EXIT
  # trap removed it), so only the string is checked: it must name a
  # directory under the TMPDIR the run was given. Both sides are pwd -P.
  _t_got=$(grep -c -F -e "$T_STAGE_SAY" "$T_TMP/plan.err")
  t_same "$T_N council-plan.sh: lines of its messages that name the staging directory" 1 "$_t_got"
  _t_line=$(grep -F -e "$T_STAGE_SAY" "$T_TMP/plan.err" | head -n 1)
  _t_got=${_t_line#"$T_STAGE_SAY"}
  case $_t_got in
    "$T_TMP/tmp"/*) t_ok "$T_N council-plan.sh: the staging directory it names is under its TMPDIR" ;;
    *) t_bad "$T_N council-plan.sh: the staging directory it names is under its TMPDIR" "$T_TMP/tmp/..." "$_t_got" ;;
  esac
  t_load
  t_same "$T_N council-plan.sh, a clean tree: prompts sent" 2 "$T_NP"
  if cmp -s "$P1" "$P2"; then _t_got=identical; else _t_got=different; fi
  t_same "$T_N council-plan.sh, a clean tree: the two planners' prompts, byte for byte" identical "$_t_got"
  if cmp -s "$P1" "$T_RUN/prompt.md"; then _t_got=identical; else _t_got=different; fi
  t_same "$T_N council-plan.sh, a clean tree: a planner's prompt against the published prompt.md" identical "$_t_got"
  t_count "$T_N council-plan.sh, a clean tree: the prompt" 1 "$P1" "# The repository at planning"
  t_count "$T_N council-plan.sh, a clean tree: the prompt" 1 "$P1" "HEAD: $T_HEAD"
  t_count "$T_N council-plan.sh, a clean tree: the prompt" 1 "$P1" "branch: main"
  t_count "$T_N council-plan.sh, a clean tree: the prompt" 1 "$P1" "tree: clean"
  t_lacks "$T_N council-plan.sh, a clean tree: the prompt" "$P1" "git status --porcelain:"
  _t_got=$(tail -n 1 "$P1")
  t_same "$T_N council-plan.sh, a clean tree: the prompt's last line closes the fence" "~~~" "$_t_got"
  t_count "$T_N council-plan.sh, a clean tree: council.txt" 1 "$T_RUN/council.txt" "head=$T_HEAD"
  t_count "$T_N council-plan.sh, a clean tree: council.txt" 1 "$T_RUN/council.txt" "branch=main"
  t_count "$T_N council-plan.sh, a clean tree: council.txt" 1 "$T_RUN/council.txt" "tree=clean"
  _t_got=$(grep -c '^tree\.[0-9]' "$T_RUN/council.txt")
  t_same "$T_N council-plan.sh, a clean tree: council.txt tree.<n>= lines" 0 "$_t_got"
  T_RUN_CLEAN=$T_RUN
  # A second run on the same HEAD, reviewed below after HEAD has moved.
  t_plan "$T_SH" "$R"
  t_same "$T_N council-plan.sh, a second run: exits" 0 "$T_RC"
  T_RUN_MOVED=$T_RUN

  R="$T_TMP/$T_N-dirty"
  t_repo "$R"
  printf 'two\n' >> "$R/a.txt"
  printf 'scratch\n' > "$R/scratch.txt"
  t_plan "$T_SH" "$R"
  t_same "$T_N council-plan.sh, a dirty tree: exits" 0 "$T_RC"
  t_load
  if cmp -s "$P1" "$P2"; then _t_got=identical; else _t_got=different; fi
  t_same "$T_N council-plan.sh, a dirty tree: the two planners' prompts, byte for byte" identical "$_t_got"
  t_count "$T_N council-plan.sh, a dirty tree: the prompt" 1 "$P1" "tree: dirty"
  t_count "$T_N council-plan.sh, a dirty tree: the prompt" 1 "$P1" " M a.txt"
  t_count "$T_N council-plan.sh, a dirty tree: the prompt" 1 "$P1" "?? scratch.txt"
  t_count "$T_N council-plan.sh, a dirty tree: the prompt" 0 "$P1" "?? .council/"
  t_count "$T_N council-plan.sh, a dirty tree: council.txt" 1 "$T_RUN/council.txt" "tree=dirty"
  t_count "$T_N council-plan.sh, a dirty tree: council.txt" 1 "$T_RUN/council.txt" "tree.1= M a.txt"
  t_count "$T_N council-plan.sh, a dirty tree: council.txt" 1 "$T_RUN/council.txt" "tree.2=?? scratch.txt"

  R="$T_TMP/$T_N-empty"
  mkdir -p "$R"
  t_git "$R" init -q
  t_plan "$T_SH" "$R"
  t_same "$T_N council-plan.sh, no commits: exits" 0 "$T_RC"
  t_load
  t_count "$T_N council-plan.sh, no commits: the prompt" 1 "$P1" "HEAD: none: HEAD names no commit (a repository with no commits yet, or a branch with none)"
  t_count "$T_N council-plan.sh, no commits: the prompt" 1 "$P1" "branch: main"

  R="$T_TMP/$T_N-detached"
  t_repo "$R"
  t_git "$R" checkout -q --detach
  t_plan "$T_SH" "$R"
  t_same "$T_N council-plan.sh, detached HEAD: exits" 0 "$T_RC"
  t_load
  t_count "$T_N council-plan.sh, detached HEAD: the prompt" 1 "$P1" "branch: none: detached HEAD"
  t_count "$T_N council-plan.sh, detached HEAD: the prompt" 1 "$P1" "HEAD: $(t_git "$R" rev-parse HEAD)"

  R="$T_TMP/$T_N-plain"
  mkdir -p "$R"
  t_plan "$T_SH" "$R"
  t_same "$T_N council-plan.sh, not a work tree: exits" 0 "$T_RC"
  t_load
  t_count "$T_N council-plan.sh, not a work tree: the prompt" 1 "$P1" "tree: not a git work tree"
  t_count "$T_N council-plan.sh, not a work tree: council.txt" 1 "$T_RUN/council.txt" "tree=not a git work tree"
  T_RUN_PLAIN=$T_RUN

  # git absent: PATH without any directory that holds git, when what the
  # runner needs is still found there.
  T_NOGIT_PATH=""
  _t_ifs=$IFS
  IFS=:
  for _t_p in $PATH; do
    [ -x "$_t_p/git" ] || [ -x "$_t_p/git.exe" ] || T_NOGIT_PATH="$T_NOGIT_PATH${T_NOGIT_PATH:+:}$_t_p"
  done
  IFS=$_t_ifs
  if PATH=$T_NOGIT_PATH command -v git > /dev/null 2>&1; then _t_ok=no; else _t_ok=yes; fi
  for _t_c in awk sed cmp mktemp cut tr grep date; do
    PATH=$T_NOGIT_PATH command -v "$_t_c" > /dev/null 2>&1 || _t_ok=no
  done
  if [ "$_t_ok" = yes ]; then
    t_inputs_clear
    T_RC=0
    PATH=$T_NOGIT_PATH COUNCIL_PLANNERS="claude claude_alt" TMPDIR="$T_TMP/tmp" \
      "$T_SH" "$T_PLUGIN/scripts/council-plan.sh" "$T_TMP/brief.md" --root "$T_TMP/clean" --no-seat-check \
      --out "$T_TMP/$T_N-nogit-run" > /dev/null 2> "$T_TMP/plan.err" || T_RC=$?
    t_same "$T_N council-plan.sh, git absent from PATH: exits" 0 "$T_RC"
    t_load
    t_count "$T_N council-plan.sh, git absent from PATH: the prompt" 1 "$P1" "tree: unknown: git is not on PATH"
  else
    echo "skip  $T_N council-plan.sh, git absent from PATH: no PATH without git still holds what the runner needs here"
  fi

  # ------------------------------------------------------------------------
  echo "$T_N council-review.sh: two blocks in every prompt"

  t_review "$T_SH" "$T_RUN_CLEAN"
  t_same "$T_N council-review.sh, HEAD unmoved: exits" 0 "$T_RC"
  t_load
  t_same "$T_N council-review.sh, HEAD unmoved: prompts sent (two attacks, one arbiter)" 3 "$T_NP"
  for _t_f in $T_PS; do
    t_count "$T_N council-review.sh, HEAD unmoved: a prompt" 1 "$_t_f" "# The repository at planning"
    t_count "$T_N council-review.sh, HEAD unmoved: a prompt" 1 "$_t_f" "# The repository now"
    t_count "$T_N council-review.sh, HEAD unmoved: a prompt" 2 "$_t_f" "HEAD: $T_HEAD"
    t_count "$T_N council-review.sh, HEAD unmoved: a prompt" 1 "$_t_f" "since planning: HEAD has not moved"
    t_lacks "$T_N council-review.sh, HEAD unmoved: a prompt" "$_t_f" "git diff --stat"
    # The run directory is under .council, so git names nothing new.
    t_count "$T_N council-review.sh, HEAD unmoved: a prompt" 2 "$_t_f" "tree: clean"
  done

  R="$T_TMP/$T_N-plan"
  printf 'three\n' >> "$R/a.txt"
  t_git "$R" commit -q -a -m two
  T_HEAD2=$(t_git "$R" rev-parse HEAD)
  t_review "$T_SH" "$T_RUN_MOVED"
  t_same "$T_N council-review.sh, HEAD moved: exits" 0 "$T_RC"
  t_load
  t_same "$T_N council-review.sh, HEAD moved: prompts sent" 3 "$T_NP"
  for _t_f in $T_PS; do
    t_count "$T_N council-review.sh, HEAD moved: a prompt" 1 "$_t_f" "HEAD: $T_HEAD"
    t_count "$T_N council-review.sh, HEAD moved: a prompt" 1 "$_t_f" "HEAD: $T_HEAD2"
    t_count "$T_N council-review.sh, HEAD moved: a prompt" 1 "$_t_f" "since planning: HEAD has moved"
    t_count "$T_N council-review.sh, HEAD moved: a prompt" 1 "$_t_f" "git diff --stat $T_HEAD $T_HEAD2:"
    t_has "$T_N council-review.sh, HEAD moved: a prompt" "$_t_f" " a.txt | 1 +"
  done
  _t_a=$(sed -n '/^# The repository at planning$/,$p' "$P1")
  _t_b=$(sed -n '/^# The repository at planning$/,$p' "$P2")
  t_same "$T_N council-review.sh, HEAD moved: the repository blocks of two prompts" "$_t_a" "$_t_b"

  t_review "$T_SH" "$T_RUN_PLAIN"
  t_same "$T_N council-review.sh, not a work tree: exits" 0 "$T_RC"
  t_load
  t_count "$T_N council-review.sh, not a work tree: a prompt" 2 "$P1" "tree: not a git work tree"
  t_count "$T_N council-review.sh, not a work tree: a prompt" 1 "$P1" "since planning: no commit then and none now, so there is nothing to compare"
  t_lacks "$T_N council-review.sh, not a work tree: a prompt" "$P1" "git diff --stat"

  # A run planned before council.txt recorded the repository.
  grep -v -e '^head=' -e '^branch=' -e '^tree' "$T_RUN_CLEAN/council.txt" > "$T_TMP/old.txt"
  cp "$T_TMP/old.txt" "$T_RUN_CLEAN/council.txt"
  t_review "$T_SH" "$T_RUN_CLEAN" --arbitrate-only
  t_same "$T_N council-review.sh --arbitrate-only, no head= in council.txt: exits" 0 "$T_RC"
  t_load
  t_same "$T_N council-review.sh --arbitrate-only: prompts sent" 1 "$T_NP"
  t_count "$T_N council-review.sh --arbitrate-only, no head= in council.txt: the prompt" 1 "$P1" "HEAD: not recorded: this run was planned before plan-council recorded the repository"
  t_count "$T_N council-review.sh --arbitrate-only, no head= in council.txt: the prompt" 1 "$P1" "since planning: not known, because no HEAD at planning was recorded"
  t_lacks "$T_N council-review.sh --arbitrate-only, no head= in council.txt: the prompt" "$P1" "git diff --stat"

  # A run directory git does not ignore, then one it tracks: reviewed like
  # any other. The review refused both until 2026-11-20 (the comment where
  # that refusal stood in council-review.sh says why it went).
  R="$T_TMP/$T_N-unignored"
  t_repo "$R"
  t_plan "$T_SH" "$R" --out "$R/runs/run-1"
  t_same "$T_N council-plan.sh --out on a path git does not ignore: exits" 0 "$T_RC"
  T_RUN_UNIGNORED=$T_RUN
  t_review "$T_SH" "$T_RUN_UNIGNORED"
  t_same "$T_N council-review.sh, a run directory git does not ignore: exits" 0 "$T_RC"
  t_lacks "$T_N council-review.sh, a run directory git does not ignore: its messages" "$T_TMP/review.err" "git tracks or does not ignore"
  t_load
  t_same "$T_N council-review.sh, a run directory git does not ignore: prompts sent" 3 "$T_NP"
  t_count "$T_N council-review.sh, a run directory git does not ignore: a prompt names it" 1 "$P1" "?? runs/"
  t_git "$R" add -f runs
  t_git "$R" commit -q -m runs
  _t_got=$(t_git "$R" ls-files runs | grep -c 'council\.txt$')
  t_same "$T_N a run directory git tracks: council.txt is tracked" 1 "$_t_got"
  t_review "$T_SH" "$T_RUN_UNIGNORED" --arbitrate-only
  t_same "$T_N council-review.sh --arbitrate-only, a run directory git tracks: exits" 0 "$T_RC"
  t_load
  t_same "$T_N council-review.sh --arbitrate-only, a run directory git tracks: prompts sent" 1 "$T_NP"
done

# ---------------------------------------------------------------------------
echo "Assignment gets nothing"

_t_got=$(grep -c 'council_git_\|repository_blocks' "$T_PLUGIN/scripts/council-assign.sh")
t_same "scripts/council-assign.sh: references to the repository block" 0 "$_t_got"

echo "House rule"

_t_got=$(tr -cd "$(printf '\140')" < "$T_DIR/repository-block.sh" | wc -c | tr -d ' ')
t_same "scripts/tests/repository-block.sh: backquote characters" 0 "$_t_got"

echo
echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
