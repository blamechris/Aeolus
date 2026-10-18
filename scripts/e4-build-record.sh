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
# leaves no partial record to paste. Diagnostics go to standard error. The script writes no
# file, does not run any binary it reads, and does not need root.
#
# ## What a record proves
#
# That, when it was made, the source tree at <source-worktree> was clean at the HEAD it names,
# and that the three binaries in the app had the CDHashes it lists. Paired with
# scripts/e4-verify-running.sh, which compares the helper the kernel is running against the
# CDHash recorded here, it lets a reviewer say "the helper on that Mac is the build the gate
# reviewed" and have the sentence rest on two hashes instead of on a belief.
#
# ## What it does not prove
#
# - **That the app was built from that HEAD.** Nothing in a binary names its commit, so the
#   link between the source and the hashes is the operator making the record straight after
#   building from that clean tree. A record made later, or against another tree, is only as
#   good as the operator's care. The script cannot tell.
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
# record says it could not be read. It is never evidence of which build this is. The CDHash is.
#
# Exit status:
#   0  the record was printed
#   2  usage: wrong arguments, or the source tree is not a git work tree
#   3  the source tree is dirty (tracked changes or untracked files): a record of a dirty
#      build names no source anyone can review, so none is made
#   4  a binary or the app's Info.plist is missing
#   5  a binary is unsigned, or its signature or architectures cannot be read

set -euo pipefail

readonly EX_USAGE=2
readonly EX_DIRTY=3
readonly EX_MISSING=4
readonly EX_UNSIGNED=5

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

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    die "${EX_USAGE}" "usage: $(basename "$0") <path-to-Aeolus.app> [<source-worktree>]"
fi

app="${1%/}"
source_tree="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

# --- The source ---------------------------------------------------------------------------

command -v git >/dev/null 2>&1 || die "${EX_USAGE}" "git is not on PATH"
git -C "${source_tree}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "${EX_USAGE}" "the source tree is not a git work tree"

branch=$(git -C "${source_tree}" symbolic-ref --short -q HEAD || true)
if [ -z "${branch}" ]; then
    branch="(detached HEAD)"
fi
head_sha=$(git -C "${source_tree}" rev-parse HEAD) \
    || die "${EX_USAGE}" "the source tree has no HEAD commit"

# Untracked files count: SwiftPM compiles every .swift file under Sources, tracked or not.
# Ignored files do not: the build leaves .build and Configs/Signing.xcconfig behind.
dirty=$(git -C "${source_tree}" status --porcelain --untracked-files=all) \
    || die "${EX_USAGE}" "could not read the source tree's status"
if [ -n "${dirty}" ]; then
    count=$(printf '%s\n' "${dirty}" | wc -l | tr -d ' ')
    {
        echo "error: the source tree is dirty (${count} path(s)); commit or discard them and build again."
        echo "A record of a dirty build names no source a reviewer can read. First paths:"
        printf '%s\n' "${dirty}" | sed -n '1,10p' | sed 's/^/  /'
    } >&2
    exit "${EX_DIRTY}"
fi

# --- The app ------------------------------------------------------------------------------

info="${app}/Contents/Info.plist"
[ -f "${info}" ] || die "${EX_MISSING}" "missing: Contents/Info.plist in $(basename "${app}")"

plist_value() {
    "${PLISTBUDDY}" -c "Print :$1" "${info}" 2>/dev/null \
        || die "${EX_MISSING}" "Contents/Info.plist has no $1"
}
short_version=$(plist_value CFBundleShortVersionString)
bundle_version=$(plist_value CFBundleVersion)

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

# The helper's build string, by pattern, without running the helper.
helper_build_line() {
    local binary="${app}/Contents/MacOS/AeolusHelper" matches count
    matches=$("${STRINGS}" -a "${binary}" 2>/dev/null \
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
aeolus_lines=$(binary_lines Aeolus)
helper_lines=$(binary_lines AeolusHelper)
fanctl_lines=$(binary_lines fanctl)
build_line=$(helper_build_line)
recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat <<EOF
E4 build record
  recorded (UTC): ${recorded_at}
  source branch:  ${branch}
  source HEAD:    ${head_sha}
  source tree:    clean (no tracked changes, no untracked files)
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
