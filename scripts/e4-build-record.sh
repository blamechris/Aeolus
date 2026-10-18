#!/bin/bash -p
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
# leaves no partial record to paste. The script writes no file, does not run any binary it
# reads, and does not need root.
#
# ## What is printed
#
# - **A successful record** prints fixed labels, the source tree's branch and HEAD, the bundle's
#   two version strings, the helper's build string, and per binary the architecture, the
#   sha256 CDHash and the signing identifier. It contains no file name from the source tree,
#   no name of the app bundle, and no path. It does not print the Team ID or the signing
#   authority that `codesign` reports: the raw output is held in a variable and two `sed`
#   extractions read the identifier and the hash, so a record can be pasted anywhere.
# - **A refusal** (any non-zero exit) writes to standard error, in words this script chooses:
#   no `codesign` or `git` output is passed through. It may name repo-relative paths from the
#   source tree, because the operator needs them to act and no record is produced.
#
# ## The environment
#
# The script does not trust the one it is started in. `#!/bin/bash -p` makes macOS's bash 3.2
# ignore BASH_ENV, ENV and SHELLOPTS and import no shell function from the environment; it is
# used instead of `env -i` so the script keeps its own name and arguments. It does not make
# bash 3.2 ignore CDPATH or GLOBIGNORE (CDPATH is still honoured by `cd`), which the scrub
# below unsets for that reason; BASHOPTS does not exist in 3.2.
#
# `bash script` ignores the flag on the shebang line and imports functions, so the first thing
# the script does is refuse to run unless bash was started with `-p`. The refusal is a
# parameter expansion, `${…:?}`, because every command name, `echo` and `exit` included, could
# be an imported function that swallows the refusal; a parameter expansion and `case` are
# syntax and cannot be replaced. Bash 3.2 exits 1 for it, writes no record, and says why on
# standard error. Two tests, both required:
# - `$-` contains `p`.
# - The kernel's record of this process's arguments, `/bin/ps -ww -o args= -p $$` (a path, so
#   never a function), has `-p` straight after the shell's own name.
# The first alone is not proof: `SHELLOPTS=privileged bash script`, and a BASH_ENV file that
# runs `set -p` and unsets itself, both put `p` in `$-` after bash has imported the functions
# or run the file. Neither puts `-p` in the arguments, which bash reads before it touches the
# environment. (A parent that execs bash under a forged argument vector controls the process,
# which is beyond what a script can check.) `SHELLOPTS=noexec bash script` is the one start
# this cannot refuse, because noexec skips every command, the guard included: it exits 0 and
# prints nothing, and no record is not a record.
#
# It then refuses (exit 2) to run with BASH_ENV or ENV set, or with xtrace or verbose on,
# either of which would print the signature it reads. It pins PATH to /usr/bin:/bin and the
# locale to C, and unsets GREP_*, GIT_*, DYLD_*, PERL*, LD_*, CDPATH, GLOBIGNORE and
# POSIXLY_CORRECT.
#
# ## The toolchain
#
# /usr/bin/git, /usr/bin/lipo and /usr/bin/strings are not the tools: they are launchers that
# ask xcrun which developer directory to run the real one from, and DEVELOPER_DIR answers.
# Pinning PATH does not help, because the launcher is on the pinned PATH. A directory holding
# an `xcrun` of its own (macOS 27.0.1 runs `$DEVELOPER_DIR/usr/bin/xcrun`) is enough to
# answer `git status` with nothing, so a tree with a tracked change and an untracked .swift
# file recorded as `clean`. The script therefore unsets DEVELOPER_DIR, and TOOLCHAINS and
# SDKROOT with it: xcrun(1) documents all three as choosing what it runs, though only
# DEVELOPER_DIR was shown to redirect these tools. The launchers then use the active developer
# directory (`xcode-select -p`). Not tested: whether xcrun's cache under $TMPDIR can be
# planted. scripts/e4-verify-running.sh runs no launcher (`otool -L` shows none of its tools
# linked against libxcselect), so it needs no such scrub.
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
# <source-worktree> must be the top level of its work tree (exit 2 otherwise): a subdirectory
# would be checked without the files outside it. Every git call runs with
# `-c core.fsmonitor=false -c core.untrackedCache=false`, so a monitor that says nothing
# changed is not believed. Then:
# - No tracked path has a `filter` attribute (exit 3), from any attribute source:
#   `git check-attr filter` over every tracked path. A clean filter can make a modified file
#   compare equal to the committed one. The repository has no .gitattributes, and a filter
#   driver merely being configured is not refused: git-lfs is configured globally on many Macs
#   and applies to nothing here.
# - `git status --porcelain --untracked-files=all --ignore-submodules=none` is empty: no
#   tracked change (staged or not), no untracked file, no change inside a submodule.
# - No tracked file is marked `--assume-unchanged` or `--skip-worktree` (`git ls-files -v`
#   shows a lowercase letter or `S`), because git then reports a modified file as clean.
# - **Every** untracked path, ignored or not, whatever ignored it (.gitignore,
#   .git/info/exclude or core.excludesFile), must be in this explicit allowed set, and
#   anything else is refused. SwiftPM compiles every .swift file under Sources/, reads a
#   root Package@swift-*.swift, and treats an ignored Packages/ directory as an edited
#   dependency. The allowed set is what the repository's own .gitignore names as local or
#   generated, and a build tolerates:
#     Configs/Signing.xcconfig             local signing settings; read by Full builds only
#     Configs/Aeolus-Info.plist            generated from project.yml by xcodegen
#     Configs/AeolusHelper-Info.plist      generated from project.yml by xcodegen
#     Configs/fanctl-Info.plist            generated from project.yml by xcodegen
#     Aeolus.xcodeproj/                    generated from project.yml (and, inside it, the
#                                          Xcode user state and IDEWorkspaceChecks.plist)
#     .build/                              SwiftPM's build output
#     DerivedData/, build/                 Xcode's build output
#     dist/                                release artifacts a build only writes
#     .DS_Store                            Finder state, anywhere
#     .claude/settings.local.json          an agent's local settings; nothing builds from it
#     autonomous-session-*.md              an agent's session log at the root; the same
#   Everything else the .gitignore lists is refused on purpose: *.p12, *.cer,
#   *.provisionprofile and AuthKey_*.p8 (signing secrets that have no business in the tree),
#   Packages/, Pods/ and Carthage/Build/ (dependencies a build would read), .swiftpm/ (it can
#   hold a package mirror configuration), and *.hmap, *.dSYM, *.ipa, *.dmg, *.xcuserstate and
#   the like outside the directories above.
#
# ## What it does not prove
#
# - **That the app was built from that HEAD.** Nothing in a binary names its commit, so the
#   link between the source and the hashes is the operator making the record straight after
#   building from that clean tree. A record made later, or against another tree, is only as
#   good as the operator's care. The script cannot tell.
# - **That the ignored-but-allowed inputs were right.** Configs/Signing.xcconfig decides the
#   signing identity, and nothing here reads it. The generated Info.plists and
#   Aeolus.xcodeproj/ come from project.yml and can be stale: this script does not regenerate
#   or compare them. The record says only whether each is present.
# - **That the bundle is intact.** It reads three binaries; it does not run
#   `codesign --verify --deep --strict` on the app, and it does not read the app's resources.
# - **That any signature is trustworthy.** It reads each CDHash and identifier and nothing
#   about who signed.
# - **That the helper is running, or what it is doing.** Never run here; see the verify script.
#
# The helper's build string (`AeolusHelperMain.build`) is read from the binary's string table
# by pattern, because the helper must not be run to ask it. It is display-grade and appears
# only when exactly one string in the binary has the shape `N.N.N (text)`; otherwise the
# record says it could not be read, and whether that is because `strings` or `grep` failed or
# because no (or more than one) such string exists. It is never evidence of which build this
# is. The CDHash is.
#
# Exit status:
#   0  the record was printed
#   2  the arguments, the environment or the source tree cannot be used: wrong number of
#      arguments; BASH_ENV, ENV, xtrace or verbose is on; git is not available; the source
#      tree is not a git work tree, is not its top level, or has no HEAD commit
#   3  the source tree is not clean in the sense above: a record of a dirty build names no
#      source anyone can review, so none is made
#   4  an input of the app is missing: Contents/Info.plist, one of its two version keys, or
#      one of the three binaries
#   5  a binary is unsigned, or its signature or architectures cannot be read
#   6  a system tool failed where it should not have (git, date, grep, or any other utility);
#      the message says that and names no output of it
#   1  (macOS's bash 3.2, for a failed `${…:?}`; not a code of this script's own) bash was not
#      started with -p: see "The environment"; no record is made

# --- The environment ----------------------------------------------------------------------

# Nothing in this block names a command until it has passed: a function imported from the
# environment would replace one. `case` and parameter expansions are syntax, and /bin/ps has a
# path, which is never looked up as a function. `${name:?word}` ends a non-interactive shell,
# whatever `exit` or `:` have been redefined to. See "The environment" in the header for why
# both tests are needed.
shell_privileged=${-//[!p]/}
: "${shell_privileged:?refusing to run unless bash was started with -p, because without it bash imports shell functions from the environment; run the script itself (its first line asks for -p) or use bash -p}"
shell_arguments=$(/bin/ps -ww -o args= -p "$$") || shell_arguments=
shell_arguments=${shell_arguments#* }
shell_started_with_p=
case "${shell_arguments}" in
    "-p" | "-p "*) shell_started_with_p=yes ;;
esac
: "${shell_started_with_p:?refusing to run: bash was not started with -p as its first argument, so SHELLOPTS or a BASH_ENV file may have put p in the flags after bash imported functions or ran the file; run the script itself (its first line asks for -p) or use bash -p}"

case "$-" in
    *[xv]*)
        echo "error: refusing to run with xtrace or verbose on: they would print the signature output this script keeps out of the record" >&2
        exit 2
        ;;
esac
if [ -n "${BASH_ENV:-}" ] || [ -n "${ENV:-}" ]; then
    echo "error: refusing to run with BASH_ENV or ENV set: the file would run before this script and could change what it does" >&2
    exit 2
fi
PATH=/usr/bin:/bin
export PATH
LC_ALL=C
export LC_ALL
for scrub_name in $(compgen -e); do
    case "${scrub_name}" in
        GIT_* | GREP_* | DYLD_* | PERL* | LD_* | CDPATH | GLOBIGNORE | POSIXLY_CORRECT | DEVELOPER_DIR | TOOLCHAINS | SDKROOT)
            unset "${scrub_name}"
            ;;
    esac
done

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

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    die "${EX_USAGE}" "usage: $(basename "$0") <path-to-Aeolus.app> [<source-worktree>]"
fi

app="${1%/}"
source_tree="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

# --- The source ---------------------------------------------------------------------------

# Every git call goes through here. Its standard error can carry the tree's path, so it is
# never passed on; and a file-system monitor or an untracked cache is never believed.
git_in_tree() {
    git -C "${source_tree}" -c core.fsmonitor=false -c core.untrackedCache=false "$@" 2>/dev/null
}

command -v git >/dev/null 2>&1 || die "${EX_USAGE}" "git is not available"
git_in_tree rev-parse --is-inside-work-tree >/dev/null \
    || die "${EX_USAGE}" "the source tree is not a git work tree"

top_level=$(git_in_tree rev-parse --show-toplevel) \
    || die "${EX_USAGE}" "the source tree's top level could not be read"
here=$(cd "${source_tree}" && pwd -P) \
    || die "${EX_USAGE}" "the source tree could not be entered"
if [ "${top_level}" != "${here}" ]; then
    die "${EX_USAGE}" "the source tree must be the top level of its work tree, not a subdirectory of it"
fi

branch=$(git_in_tree symbolic-ref --short -q HEAD || true)
if [ -z "${branch}" ]; then
    branch="(detached HEAD)"
fi
head_sha=$(git_in_tree rev-parse HEAD) \
    || die "${EX_USAGE}" "the source tree has no HEAD commit"

# Prints up to ten of the lines it is given, indented, to standard error.
show_first_ten() { printf '%s\n' "$1" | sed -n '1,10p' | sed 's/^/  /' >&2; }

# 0. No filter may apply to a tracked file: a clean filter can make a modified file compare
#    equal to the committed one. A driver being configured is not enough to refuse (git-lfs is
#    configured globally on many Macs and applies to nothing here); what matters is whether
#    any attribute source (.gitattributes, .git/info/attributes, core.attributesFile, the
#    system file) sets `filter` on a tracked path. `git check-attr` reads them all.
tracked_paths=$(git_in_tree ls-files) || die "${EX_TOOL}" "git could not list the tracked files"
attribute_lines=$(printf '%s\n' "${tracked_paths}" | git_in_tree check-attr --stdin filter) \
    || die "${EX_TOOL}" "git could not read the attributes of the tracked files"
filtered=""
while IFS= read -r line; do
    case "${line}" in
        '' | *": filter: unspecified") ;;
        *) filtered="${filtered}${line}"$'\n' ;;
    esac
done <<EOF
${attribute_lines}
EOF
if [ -n "${filtered}" ]; then
    echo "error: a filter attribute applies to tracked files, and a clean filter can make a modified file compare equal. First paths:" >&2
    show_first_ten "${filtered}"
    exit "${EX_DIRTY}"
fi

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
#    `git ls-files -v` prefixes each path with a letter: lowercase for assume-unchanged, S for
#    skip-worktree. The test is a shell pattern and not grep, so no environment can change it.
listing=$(git_in_tree ls-files -v) || die "${EX_TOOL}" "git could not list the source tree's files"
hidden=""
while IFS= read -r line; do
    case "${line}" in
        [a-zS]\ *) hidden="${hidden}${line}"$'\n' ;;
    esac
done <<EOF
${listing}
EOF
if [ -n "${hidden}" ]; then
    echo "error: tracked files are marked assume-unchanged or skip-worktree, so git cannot say whether they changed." >&2
    echo "(lowercase letter or S in 'git ls-files -v'; undo with 'git update-index --no-assume-unchanged' or '--no-skip-worktree'.) First paths:" >&2
    show_first_ten "${hidden}"
    exit "${EX_DIRTY}"
fi

# 3. Every untracked path, ignored or not. Without an exclude option `git ls-files --others`
#    lists ignored paths too, including those hidden by .git/info/exclude and core.excludesFile,
#    and --directory shows a wholly untracked directory as one entry. The allowed set is
#    explicit (see the header); a shell pattern decides, and anything else is refused.
is_allowed_untracked() {
    case "$1" in
        Configs/Signing.xcconfig | Configs/Aeolus-Info.plist | Configs/AeolusHelper-Info.plist | Configs/fanctl-Info.plist) return 0 ;;
        Aeolus.xcodeproj/ | .build/ | DerivedData/ | build/ | dist/) return 0 ;;
        .DS_Store | */.DS_Store) return 0 ;;
        .claude/settings.local.json) return 0 ;;
        autonomous-session-*.md) return 0 ;;
    esac
    return 1
}
untracked=$(git_in_tree ls-files --others --directory) \
    || die "${EX_TOOL}" "git could not list the untracked paths"
unexpected=""
while IFS= read -r entry; do
    if [ -n "${entry}" ] && ! is_allowed_untracked "${entry}"; then
        unexpected="${unexpected}${entry}"$'\n'
    fi
done <<EOF
${untracked}
EOF
if [ -n "${unexpected}" ]; then
    echo "error: untracked paths, ignored or not, are outside the set a build may have here, and a build can read them." >&2
    echo "Remove them, or track them, and build again. First paths:" >&2
    show_first_ten "${unexpected}"
    exit "${EX_DIRTY}"
fi

# Which of the allowed local inputs exist, as fixed labels.
signing_label="absent"
if [ -e "${source_tree}/Configs/Signing.xcconfig" ]; then
    signing_label="present"
fi
plists_found=0
for plist_name in Aeolus-Info.plist AeolusHelper-Info.plist fanctl-Info.plist; do
    if [ -e "${source_tree}/Configs/${plist_name}" ]; then
        plists_found=$((plists_found + 1))
    fi
done
project_label="absent"
if [ -e "${source_tree}/Aeolus.xcodeproj" ]; then
    project_label="present"
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

# Prints "<identifier> <sha256 CDHash>" for one architecture of one binary. Returns 1 if the
# binary is unsigned or the signature gives no single identifier and sha256 hash, 2 if a
# parser failed. The raw output is held in a variable and never printed: it carries the Team
# ID and the signing authority, which a record must not.
slice_signature() {
    local binary="$1" arch="$2" output identifier hash
    output=$("${CODESIGN}" -d --verbose=4 --arch "${arch}" "${binary}" 2>&1) || return 1
    identifier=$(printf '%s\n' "${output}" | sed -n 's/^Identifier=//p') || return 2
    hash=$(printf '%s\n' "${output}" | sed -n 's/^CandidateCDHashFull sha256=//p') || return 2
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
    local name="$1" binary="${app}/Contents/MacOS/$1" archs arch signature signature_status
    [ -f "${binary}" ] || die "${EX_MISSING}" "missing binary: Contents/MacOS/${name}"
    archs=$("${LIPO}" -archs "${binary}" 2>/dev/null) \
        || die "${EX_UNSIGNED}" "Contents/MacOS/${name}: cannot read its architectures (is it a Mach-O?)"
    [ -n "${archs}" ] || die "${EX_UNSIGNED}" "Contents/MacOS/${name}: no architectures found"
    printf '%s  (Contents/MacOS/%s)\n' "${name}" "${name}"
    for arch in ${archs}; do
        signature_status=0
        signature=$(slice_signature "${binary}" "${arch}") || signature_status=$?
        case "${signature_status}" in
            0) ;;
            1) die "${EX_UNSIGNED}" "Contents/MacOS/${name} (${arch}): unsigned, or no sha256 CDHash and identifier can be read from its signature" ;;
            *) die "${EX_TOOL}" "Contents/MacOS/${name} (${arch}): a system tool failed while reading its signature" ;;
        esac
        printf '  %-7s sha256 CDHash %s  identifier %s\n' \
            "${arch}" "${signature#* }" "${signature%% *}"
    done
}

# The helper's build string, by pattern, without running the helper. Display only: when it
# cannot be read the record says why, and still makes the record.
helper_build_line() {
    local binary="${app}/Contents/MacOS/AeolusHelper" listing matches count line match_status=0
    if ! listing=$("${STRINGS}" -a "${binary}" 2>/dev/null); then
        echo "not read: the strings tool failed on the binary (the helper was not run)"
        return 0
    fi
    # grep's exit 1 is "no line matches" and is not a failure; 2 or more is.
    matches=$(printf '%s\n' "${listing}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+ \(.+\)$' | sort -u) || match_status=$?
    if [ "${match_status}" -gt 1 ]; then
        echo "not read: the grep tool failed on the binary's strings (the helper was not run)"
        return 0
    fi
    count=0
    while IFS= read -r line; do
        if [ -n "${line}" ]; then
            count=$((count + 1))
        fi
    done <<EOF
${matches}
EOF
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
  source tree:    clean (top level; no filter, no tracked change, no untracked path outside the allowed set,
                  no assume-unchanged or skip-worktree file)
  local inputs, ignored and not part of the tree this record names (presence only):
    Configs/Signing.xcconfig: ${signing_label}
    generated Info.plists:    ${plists_found} of 3 present
    Aeolus.xcodeproj/:        ${project_label}
  app bundle:     (name not recorded)
  version:        ${short_version} (CFBundleShortVersionString)
  build:          ${bundle_version} (CFBundleVersion)
  helper build string: ${build_line}
    (read from the binary's string table; the helper was not run; display-grade)

${aeolus_lines}

${helper_lines}

${fanctl_lines}

Compare a running helper with: scripts/e4-verify-running.sh <the AeolusHelper sha256 CDHash above>
EOF
