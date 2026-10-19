#!/usr/bin/env bash
# Compiles each lending probe against the helper module `swift build` produced, with the toolchain
# that runs this script, and requires the compiler to accept every `allowed-*.swift` probe and to
# refuse every `refused-*.swift` probe for exactly the reason it states:
#
# - every error the compile reports, in any file, must be in that probe and say exactly the
#   ownership-specific diagnostic its `// expect:` names; and
# - the shape's own line, its `// expect-line:`, must carry that error, or the move checker's
#   "consumed here" note that points at it (the move checker reports the error at the borrowed
#   parameter and the note at the use that would keep it).
#
# Any other error — a missing ownership keyword, an undefined type, an error in another file —
# fails the probe, so a probe cannot pass because it broke some other way.
#
# **`// expect:` is the whole message, as text, never a pattern or a fragment.** The message is
# what follows `error: ` on the compiler's line, and it must equal the expectation: nothing
# before it, nothing after it, no escapes. So an alternation such as `copy|noncopyable` is just
# the literal text and matches no diagnostic (round 1 of #440's review found exactly that
# alternation accepted), and a fragment such as `c` or `'` matches none either, which the
# substring test this replaced let through (#451): a probe broken another way then still passed,
# because any message carries a `c`. Write the message as the compiler prints it, in full — the two
# compiler-bug probes included, with their "Please file a bug…" tail. When a toolchain rewords a
# refusal, replace the expectation with the new ownership-specific diagnostic, and never broaden
# it: no alternation, and no shorter fragment that an unrelated error would also carry.
#
# Why it exists: ADR 0012's #440 amendment rests "§ 3's handback is lent, never kept" on the
# compiler refusing to let a `borrowing` parameter of a generic constrained
# `FanRestoring & ~Copyable` be stored, boxed, copied, consumed or captured. Those refusals were
# observed on one toolchain. Each is a shape that must *not* compile, so no test can hold it: this
# compiles each one, fully (`-c`, never `-typecheck`, because the move checker runs in SIL), on
# every CI run's toolchain.
#
# Reads only: it writes its objects to a temporary directory and touches nothing in the tree.
# Run it after `swift build`, from anywhere in the repository.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
probes="${root}/scripts/lending-probes"
cd "${root}"

bin="$(swift build --show-bin-path)"
module="$(find "${bin}" -maxdepth 2 -name AeolusHelper.swiftmodule -print -quit)"
if [ -z "${module}" ]; then
    echo "error: no AeolusHelper.swiftmodule under ${bin}; run swift build first"
    exit 1
fi
modules="$(dirname "${module}")"
out="$(mktemp -d)"
trap 'rm -rf "${out}"' EXIT

swiftc --version
echo "modules: ${modules}"

compile() {
    swiftc -c -parse-as-library -swift-version 6 -diagnostic-style llvm -I "${modules}" "$1" \
        -o "${out}/$(basename "$1" .swift).o" > "${out}/log" 2>&1
}

# Splits the compiler's line $3 when it is a diagnostic of kind $2 ("error" or "note") located in
# probe $1: sets `diag_line` to its line and `diag_message` to everything after "<kind>: ", to the
# end of the line. Fails for any other line: another file, no location, another kind. The whole
# line is anchored, so a path to the probe quoted inside some other diagnostic is not a location.
# The probe's name is a pattern whose dots match themselves; the message is captured, never matched.
split_diagnostic() {
    local pattern="^([^:]*/)?${1//./[.]}:([0-9]+):[0-9]+: $2: (.*)\$"
    [[ "$3" =~ ${pattern} ]] || return 1
    diag_line="${BASH_REMATCH[2]}"
    diag_message="${BASH_REMATCH[3]}"
}

# Whether every line on stdin is an error located in probe $1 whose whole message is the
# expectation $2. Both are compared as text, never as patterns, and the comparison is equality.
all_expected() {
    local diagnostic
    while IFS= read -r diagnostic; do
        split_diagnostic "$1" error "${diagnostic}" || return 1
        [ "${diag_message}" = "$2" ] || return 1
    done
}

# Whether the log $4 has, at line $2 of probe $1, either an error whose whole message is the
# expectation $3 or the move checker's note, whose whole message is "consumed here".
at_the_shape() {
    local diagnostic
    while IFS= read -r diagnostic; do
        if split_diagnostic "$1" error "${diagnostic}" \
            && [ "${diag_line}" = "$2" ] && [ "${diag_message}" = "$3" ]; then
            return 0
        fi
        if split_diagnostic "$1" note "${diagnostic}" \
            && [ "${diag_line}" = "$2" ] && [ "${diag_message}" = "consumed here" ]; then
            return 0
        fi
    done < "$4"
    return 1
}

failures=0
allowed=0
refused=0

for probe in "${probes}"/allowed-*.swift; do
    allowed=$((allowed + 1))
    if compile "${probe}"; then
        echo "ok: $(basename "${probe}") compiles"
    else
        echo "error: $(basename "${probe}") must compile, and did not:"
        cat "${out}/log"
        failures=$((failures + 1))
    fi
done

for probe in "${probes}"/refused-*.swift; do
    refused=$((refused + 1))
    name="$(basename "${probe}")"
    expect="$(sed -n 's|^// expect: ||p' "${probe}" | head -1)"
    line="$(sed -n 's|^// expect-line: ||p' "${probe}" | head -1)"
    if [ -z "${expect}" ] || ! [[ "${line}" =~ ^[0-9]+$ ]]; then
        echo "error: ${name} needs a // expect: diagnostic and a numeric // expect-line:"
        failures=$((failures + 1))
        continue
    fi
    if compile "${probe}"; then
        echo "error: ${name} compiled. This toolchain no longer refuses the shape, so the"
        echo "       handback can be kept: see ADR 0012's #440 amendment before going further."
        failures=$((failures + 1))
        continue
    fi
    # Every error the compile reported: located in any file, or unlocated.
    errors="$(grep -E -- '(:[0-9]+:[0-9]+: error: |^<unknown>:0: error: |^error: )' "${out}/log" \
        || true)"
    if [ -n "${errors}" ] && all_expected "${name}" "${expect}" <<< "${errors}" \
        && at_the_shape "${name}" "${line}" "${expect}" "${out}/log"; then
        echo "ok: ${name} refused at line ${line}: ${expect}"
    else
        echo "error: ${name} must fail only with exactly '${expect}', marked at line ${line}; it said:"
        cat "${out}/log"
        failures=$((failures + 1))
    fi
done

# Coverage, not decoration: a glob that matched nothing would pass over no probe at all.
if [ "${allowed}" -ne 1 ] || [ "${refused}" -ne 10 ]; then
    echo "error: found ${allowed} allowed and ${refused} refused probes; expected 1 and 10"
    failures=$((failures + 1))
fi

if [ "${failures}" -ne 0 ]; then
    echo "LENDING PROBES FAILED: ${failures} problem(s)"
    exit 1
fi
echo "LENDING PROBES PASSED: ${refused} shapes refused, ${allowed} lend compiled"
