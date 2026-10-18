#!/bin/bash
# Prints one build record for an Aeolus.app, to paste into a review record.
#
#     scripts/e4-build-record.sh <path-to-Aeolus.app> [<source-worktree>]
#
# The record names the source (branch, HEAD, clean), the app's versions, and the sha256
# CDHash and signing identifier of each of the three binaries the app ships:
# Contents/MacOS/Aeolus, Contents/MacOS/AeolusHelper and Contents/MacOS/fanctl. A universal
# binary has one CodeDirectory per architecture, hence one CDHash per architecture, and the
# record lists every one: the kernel holds the hash of the slice a process actually runs.
#
# The block goes to standard output and only once every check has passed, so a failed run
# leaves no partial record to paste. Diagnostics go to standard error, in words this script
# chooses: no `codesign` or `git` output is passed through, and no path that could carry a
# user name is printed (the app is named by its basename, the binaries by their place in the
# bundle). The script writes no file, does not run any binary it reads, and does not need root.
#
# ## What a record proves
#
# That, when it was made, the source tree at <source-worktree> was clean at the HEAD it names
# (see "clean" below for exactly what that checks), and that the three binaries in the app had
# the CDHashes it lists. Paired with scripts/e4-verify-running.sh, which compares the helper
# the kernel is running against the CDHash recorded here, it lets a reviewer say "the helper
# on that Mac is the build the gate reviewed" and have the sentence rest on two hashes
# instead of on a belief.
#
# ## What "clean" checks
#
# - `git status --porcelain --untracked-files=all --ignore-submodules=none` is empty: no
#   tracked change (staged or not), no untracked file, no change inside a submodule.
# - No tracked file is marked `--assume-unchanged` or `--skip-worktree` (`git ls-files -v`
#   shows a lowercase letter or `S`), because git then reports a modified file as clean.
# - No untracked file, ignored or not, sits under Sources/, Tests/, Tools/, Resources/ or
#   Configs/, whatever ignored it (.gitignore, .git/info/exclude or core.excludesFile).
#   SwiftPM compiles every .swift file under Sources/, tracked or not. The only exceptions are
#   the files this repository's own .gitignore names as generated or local, and which a build
#   needs: Configs/Signing.xcconfig, Configs/Aeolus-Info.plist,
#   Configs/AeolusHelper-Info.plist, Configs/fanctl-Info.plist, and .DS_Store anywhere.
#   The record lists which of those exist, by name only.
#
# ## What it does not prove
#
# - **That the app was built from that HEAD.** Nothing in a binary names its commit, so the
#   link between the source and the hashes is the operator making the record straight after
#   building from that clean tree. A record made later, or against another tree, is only as
#   good as the operator's care. The script cannot tell.
# - **That the ignored-but-expected inputs were right.** Configs/Signing.xcconfig is local and
#   ignored: it decides the signing identity, and nothing here reads it. The generated
#   Info.plists and Aeolus.xcodeproj/ come from project.yml and can be stale: this script does
#   not regenerate or compare them.
# - **That the bundle is intact.** It reads three binaries; it does not run
#   `codesign --verify --deep --strict` on the app, and it does not read the app's resources.
# - **That any signature is trustworthy.** It reads each CDHash and identifier and nothing
#   about who signed. `codesign` also prints the Team ID and the signing authority; this
#   script reads past those lines and prints neither, so a record can be pasted anywhere.
# - **That the helper is running, or what it is doing.** Never run here; see the verify script.
#
# The helper's build string (`AeolusHelperMain.build`) is read from the binary's string table
# by pattern, because the helper must not be run to ask it. It is display-grade and appears
# only when exactly one string in the binary has the shape `N.N.N (text)`; otherwise the
# record says it could not be read, and whether that is because `strings` failed or because
# no (or more than one) such string exists. It is never evidence of which build this is. The
# CDHash is.
#
# Exit status:
#   0  the record was printed
#   2  the arguments or the source tree cannot be used: wrong number of arguments, git not on
#      PATH, the source tree is not a git work tree, or it has no HEAD commit
#   3  the source tree is not clean in the sense above: a record of a dirty build names no
#      source anyone can review, so none is made
#   4  an input of the app is missing: Contents/Info.plist, one of its two version keys, or
#      one of the three binaries
#   5  a binary is unsigned, or its signature or architectures cannot be read
#   6  a system tool failed where it should not have (git, date, or any other utility); the
#      message says that and names no output of it

set -Eeuo pipefail

readonly EX_USAGE=2
readonly EX_DIRTY=3
readonly EX_MISSING=4
readonly EX_UNSIGNED=5
readonly EX_TOOL=6

readonly CODESIGN=/usr/bin/codesign
readonly LIPO=/usr/bin/lipo
readonly STRINGS=/usr/bin/strings
readonly PLISTBUDDY=/usr/libexec/PlistBuddy

die() {
    local status="$1"
    shift
    echo "error: $*" >&2
    exit "${status}"
}

# Any command that fails where this script did not expect it to ends here, with a code of this
# script's own and not the failing command's. In a subshell it only leaves it, with the failing
# command's status, and the main shell reads that through `carry_out` where it matters.
trap 'status=$?; if [ "${BASH_SUBSHELL}" -gt 0 ]; then exit "${status}"; fi; die "${EX_TOOL}" "a system tool failed unexpectedly (line ${LINENO}); no record was made"' ERR

# Carries the status of a function that ended its subshell out to the main shell: one of this
# script's own codes goes through; anything else was a tool failing, and is EX_TOOL.
carry_out() {
    case "$1" in
        2 | 3 | 4 | 5 | 6) exit "$1" ;;
        *) die "${EX_TOOL}" "a system tool failed unexpectedly; no record was made" ;;
    esac
}

# A caller's git environment must not point git somewhere other than the tree it was given.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    die "${EX_USAGE}" "usage: $(basename "$0") <path-to-Aeolus.app> [<source-worktree>]"
fi

app="${1%/}"
source_tree="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

# --- The source ---------------------------------------------------------------------------

# Every git call goes through here: its standard error can carry the tree's path, so it is
# never passed on.
git_in_tree() { git -C "${source_tree}" "$@" 2>/dev/null; }

command -v git >/dev/null 2>&1 || die "${EX_USAGE}" "git is not on PATH"
git_in_tree rev-parse --is-inside-work-tree >/dev/null \
    || die "${EX_USAGE}" "the source tree is not a git work tree"

branch=$(git_in_tree symbolic-ref --short -q HEAD || true)
if [ -z "${branch}" ]; then
    branch="(detached HEAD)"
fi
head_sha=$(git_in_tree rev-parse HEAD) \
    || die "${EX_USAGE}" "the source tree has no HEAD commit"

# Prints up to ten of the lines it is given, indented, to standard error.
show_first_ten() { printf '%s\n' "$1" | sed -n '1,10p' | sed 's/^/  /' >&2; }

# 1. Tracked changes, untracked files and anything inside a submodule. Untracked files count:
#    SwiftPM compiles every .swift file under Sources, tracked or not.
dirty=$(git_in_tree status --porcelain --untracked-files=all --ignore-submodules=none) \
    || die "${EX_TOOL}" "git could not read the source tree's status"
if [ -n "${dirty}" ]; then
    count=$(printf '%s\n' "${dirty}" | wc -l | tr -d ' ')
    echo "error: the source tree is dirty (${count} path(s)); commit or discard them and build again." >&2
    echo "A record of a dirty build names no source a reviewer can read. First paths:" >&2
    show_first_ten "${dirty}"
    exit "${EX_DIRTY}"
fi

# 2. Tracked files git has been told to treat as unchanged: a modified one reports as clean.
listing=$(git_in_tree ls-files -v) || die "${EX_TOOL}" "git could not list the source tree's files"
hidden=$(printf '%s\n' "${listing}" | grep -E '^[a-zS] ' || true)
if [ -n "${hidden}" ]; then
    echo "error: tracked files are marked assume-unchanged or skip-worktree, so git cannot say whether they changed." >&2
    echo "(lowercase letter or S in 'git ls-files -v'; undo with 'git update-index --no-assume-unchanged' or '--no-skip-worktree'.) First paths:" >&2
    show_first_ten "${hidden}"
    exit "${EX_DIRTY}"
fi

# 3. Untracked files in the directories a build reads, whatever ignored them. Without an
#    exclude option `git ls-files --others` lists ignored files too, including those hidden
#    by .git/info/exclude and core.excludesFile.
readonly EXPECTED_IGNORED="Configs/Signing.xcconfig
Configs/Aeolus-Info.plist
Configs/AeolusHelper-Info.plist
Configs/fanctl-Info.plist"
untracked=$(git_in_tree ls-files --others -- Sources Tests Tools Resources Configs) \
    || die "${EX_TOOL}" "git could not list the untracked files"
unexpected=$(printf '%s\n' "${untracked}" \
    | grep -v -x -F -e "${EXPECTED_IGNORED}" | grep -v -E '(^|/)\.DS_Store$' | grep . || true)
if [ -n "${unexpected}" ]; then
    echo "error: untracked files sit in the build's directories (ignored or not), and a build reads them." >&2
    echo "Remove them, or track them, and build again. First paths:" >&2
    show_first_ten "${unexpected}"
    exit "${EX_DIRTY}"
fi

# Which of the expected-ignored inputs exist, by name only.
present=""
while IFS= read -r name; do
    if [ -e "${source_tree}/${name}" ]; then
        present="${present:+${present}, }${name}"
    fi
done <<EOF
${EXPECTED_IGNORED}
EOF
if [ -z "${present}" ]; then
    present="none"
fi

# --- The app ------------------------------------------------------------------------------

info="${app}/Contents/Info.plist"
[ -f "${info}" ] || die "${EX_MISSING}" "missing: Contents/Info.plist in $(basename "${app}")"

plist_value() {
    "${PLISTBUDDY}" -c "Print :$1" "${info}" 2>/dev/null \
        || die "${EX_MISSING}" "Contents/Info.plist has no $1"
}
# A function that dies inside $( ) ends only its subshell; `carry_out` carries its code out.
short_version=$(plist_value CFBundleShortVersionString) || carry_out "$?"
bundle_version=$(plist_value CFBundleVersion) || carry_out "$?"

# Prints "<identifier> <sha256 CDHash>" for one architecture of one binary, or returns 1.
# The raw output is held in a variable and never printed: it carries the Team ID and the
# signing authority, which a record must not.
slice_signature() {
    local binary="$1" arch="$2" output identifier hash
    output=$("${CODESIGN}" -d --verbose=4 --arch "${arch}" "${binary}" 2>&1) || return 1
    identifier=$(printf '%s\n' "${output}" | sed -n 's/^Identifier=//p')
    hash=$(printf '%s\n' "${output}" | sed -n 's/^CandidateCDHashFull sha256=//p')
    if [ -z "${identifier}" ] || [ "$(printf '%s\n' "${identifier}" | wc -l)" -ne 1 ]; then
        return 1
    fi
    if ! [[ "${hash}" =~ ^[0-9a-f]{64}$ ]]; then
        return 1
    fi
    printf '%s %s\n' "${identifier}" "${hash}"
}

# Prints the record's lines for one binary, or exits naming it.
binary_lines() {
    local name="$1" binary="${app}/Contents/MacOS/$1" archs arch signature
    [ -f "${binary}" ] || die "${EX_MISSING}" "missing binary: Contents/MacOS/${name}"
    archs=$("${LIPO}" -archs "${binary}" 2>/dev/null) \
        || die "${EX_UNSIGNED}" "Contents/MacOS/${name}: cannot read its architectures (is it a Mach-O?)"
    [ -n "${archs}" ] || die "${EX_UNSIGNED}" "Contents/MacOS/${name}: no architectures found"
    printf '%s  (Contents/MacOS/%s)\n' "${name}" "${name}"
    for arch in ${archs}; do
        signature=$(slice_signature "${binary}" "${arch}") \
            || die "${EX_UNSIGNED}" "Contents/MacOS/${name} (${arch}): unsigned, or no sha256 CDHash and identifier can be read from its signature"
        printf '  %-7s sha256 CDHash %s  identifier %s\n' \
            "${arch}" "${signature#* }" "${signature%% *}"
    done
}

# The helper's build string, by pattern, without running the helper. Display only: when it
# cannot be read the record says why, and still makes the record.
helper_build_line() {
    local binary="${app}/Contents/MacOS/AeolusHelper" listing matches count
    if ! listing=$("${STRINGS}" -a "${binary}" 2>/dev/null); then
        echo "not read: the strings tool failed on the binary (the helper was not run)"
        return 0
    fi
    matches=$(printf '%s\n' "${listing}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+ \(.+\)$' | sort -u || true)
    count=$(printf '%s' "${matches}" | grep -c . || true)
    if [ "${count}" -eq 1 ]; then
        printf '%s\n' "${matches}"
    elif [ "${count}" -eq 0 ]; then
        echo "not read: no string of the form N.N.N (text) in the binary (the helper was not run)"
    else
        echo "not read: ${count} strings of the form N.N.N (text) in the binary, so none is taken (the helper was not run)"
    fi
}

# Everything is gathered before anything is printed, so a failure prints no partial record.
aeolus_lines=$(binary_lines Aeolus) || carry_out "$?"
helper_lines=$(binary_lines AeolusHelper) || carry_out "$?"
fanctl_lines=$(binary_lines fanctl) || carry_out "$?"
build_line=$(helper_build_line)
recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
    || die "${EX_TOOL}" "the date could not be read; no record was made"

cat <<EOF
E4 build record
  recorded (UTC): ${recorded_at}
  source branch:  ${branch}
  source HEAD:    ${head_sha}
  source tree:    clean (no tracked change, no untracked file, no assume-unchanged or skip-worktree file)
  ignored inputs present: ${present}
    (names only; they are not part of the tree this record names)
  app:            $(basename "${app}")
  version:        ${short_version} (CFBundleShortVersionString)
  build:          ${bundle_version} (CFBundleVersion)
  helper build string: ${build_line}
    (read from the binary's string table; the helper was not run; display-grade)

${aeolus_lines}

${helper_lines}

${fanctl_lines}

Compare a running helper with: scripts/e4-verify-running.sh <the AeolusHelper sha256 CDHash above>
EOF
