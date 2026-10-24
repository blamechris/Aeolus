#!/usr/bin/env bash
# Compiles each probe against the modules `swift build` produced, with the toolchain that runs this
# script, and requires the compiler to accept every `allowed-*.swift` probe and to refuse every
# `refused-*.swift` probe for exactly the reason it states:
#
# - every error the compile reports, in any file, must be in that probe and say exactly the
#   diagnostic its `// expect:` names; and
# - the shape's own line, its `// expect-line:`, must carry that error, or the move checker's
#   "consumed here" note that points at it (the move checker reports the error at the borrowed
#   parameter and the note at the use that would keep it).
#
# Any other error — a missing ownership keyword, an undefined type, an error in another file —
# fails the probe, so a probe cannot pass because it broke some other way.
#
# Before any probe it runs the matcher against canned diagnostics (the "controls"), which need no
# compiler: they fail the script if the comparison is ever loosened, even while every probe is
# intact. And the script has to reach its last line to pass; see `finished` below.
#
# **`// expect:` is the whole message, as text, never a pattern or a fragment.** The message is
# what follows `error: ` on the compiler's line, and it must equal the expectation: nothing
# before it, nothing after it, no escapes. So an alternation such as `copy|noncopyable` is just
# the literal text and matches no diagnostic (round 1 of #440's review found exactly that
# alternation accepted), and a fragment such as `c` or `'` matches none either, which the
# substring test this replaced let through (#451): a probe broken another way then still passed,
# because these messages all carry a `c`. Write the message as the compiler prints it, in full:
# the two compiler-bug probes included, with their "Please file a bug…" tail. When a toolchain
# rewords a refusal, replace the expectation with the new diagnostic, and never broaden it: no
# alternation, and no shorter fragment that an unrelated error would also carry.
#
# Two families of probe live here, and the harness holds them to the same rules:
#
# - **The lending shapes** (ten `refused-*.swift` and their `allowed-lend-and-call.swift` control).
#   ADR 0012's #440 amendment rests "§ 3's handback is lent, never kept" on the compiler refusing
#   to let a `borrowing` parameter of a generic constrained `FanRestoring & ~Copyable` be stored,
#   boxed, copied, consumed or captured. Those refusals were observed on one toolchain. Each is a
#   shape that must *not* compile, so no test can hold it: this compiles each one, fully (`-c`,
#   never `-typecheck`, because the move checker runs in SIL), on every CI run's toolchain.
# - **The lease-control boundary** (`refused-heartbeat-accessor.swift` and its
#   `allowed-lease-driver-state.swift` control; #489, #491). `LeaseDriver.runningHeartbeat` is
#   `internal`, for the test suite alone, and the `AeolusLeaseControl` target is what puts every
#   other module out of its reach. That is an access-level refusal, not an ownership one, and
#   nothing in the suite can hold it, because a test sees the accessor through `@testable`.
#   Widening the accessor to `package` or `public`, or folding the target back into `AeolusUI`,
#   leaves every test green; this goes red. The probe imports the module plainly, never
#   `@testable`, which is the app's side of the boundary.
#
# A probe whose compile succeeds has stopped being refused, and the failure says what to read
# first: its `// see:` line, or, for the lending shapes that carry none, ADR 0012's amendment.
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
# The run has to say it finished. macOS's bash 3.2 exits 0, not 1, when `set -u` aborts a script
# that has an EXIT trap, so a crash in this script would read as a pass; the trap turns every
# exit that did not reach the end into a failure.
finished=0
trap 'rm -rf "${out}"; [ "${finished}" -eq 1 ] || exit 1' EXIT

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

# The matcher's own controls, which need no compiler: the expectation is the whole message, so a
# fragment of it, the message and something more, the same message in another file, or the same
# text as a note, is refused, and an error or the "consumed here" note at the wrong line is too.
# Without these, loosening the comparison back to a substring test would leave every probe green.
controls=0
control() {
    local want="$1" what="$2" got=0
    shift 2
    controls=$((controls + 1))
    "$@" || got=1
    if [ "${got}" -ne "${want}" ]; then
        echo "error: the matcher's control failed: ${what}"
        failures=$((failures + 1))
    fi
}

message="'copy' cannot be applied to noncopyable types"
site="${probes}/refused-copy.swift"
at_seven="${site}:7:5: error: ${message}"
control 0 "the whole message is accepted" \
    all_expected refused-copy.swift "${message}" <<< "${at_seven}"
control 1 "a one-character fragment is refused" \
    all_expected refused-copy.swift "c" <<< "${at_seven}"
control 1 "a lone quote is refused" \
    all_expected refused-copy.swift "'" <<< "${at_seven}"
control 1 "the message without its last character is refused" \
    all_expected refused-copy.swift "${message%?}" <<< "${at_seven}"
control 1 "the message without its first character is refused" \
    all_expected refused-copy.swift "${message#?}" <<< "${at_seven}"
control 1 "the message and something more is refused" \
    all_expected refused-copy.swift "${message}!" <<< "${at_seven}"
control 1 "the message in another probe's file is refused" \
    all_expected refused-cast.swift "${message}" <<< "${at_seven}"
control 1 "the message as a note is refused" \
    all_expected refused-copy.swift "${message}" <<< "${site}:7:5: note: ${message}"
control 1 "a file that merely ends in the probe's name is refused" \
    all_expected refused-copy.swift "${message}" <<< "${probes}/not-${at_seven##*/}"
control 1 "the probe's location quoted inside another file's error is refused" \
    all_expected refused-copy.swift "${message}" <<< "x.swift:1:1: error: see ${at_seven}"
control 1 "a second error that is not the expectation is refused" \
    all_expected refused-copy.swift "${message}" <<< "${at_seven}"$'\n'"${site}:8:5: error: x"
printf '%s\n%s\n' "${at_seven}" "${site}:9:5: note: consumed here" > "${out}/controls"
control 0 "the error at the shape's line is accepted" \
    at_the_shape refused-copy.swift 7 "${message}" "${out}/controls"
control 0 "the move checker's note at the shape's line is accepted" \
    at_the_shape refused-copy.swift 9 "${message}" "${out}/controls"
control 1 "a line that carries neither is refused" \
    at_the_shape refused-copy.swift 8 "${message}" "${out}/controls"
control 1 "the error at its line, under a fragment of its message, is refused" \
    at_the_shape refused-copy.swift 7 "c" "${out}/controls"
control 1 "the error at its line, under its message less a character, is refused" \
    at_the_shape refused-copy.swift 7 "${message%?}" "${out}/controls"
printf '%s\n' "${site}:9:5: note: consumed here too" > "${out}/controls"
control 1 "a note that says more than 'consumed here' is refused" \
    at_the_shape refused-copy.swift 9 "${message}" "${out}/controls"

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
        see="$(sed -n 's|^// see: ||p' "${probe}" | head -1)"
        if [ -z "${see}" ]; then
            see="ADR 0012's #440 amendment (a lending shape: the handback can be kept)"
        fi
        echo "error: ${name} compiled. This compiler no longer refuses the shape it exists to refuse."
        echo "       Read ${see} before going further."
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
        echo "error: ${name} must fail only with exactly '${expect}', marked at line ${line};"
        echo "       it said:"
        cat "${out}/log"
        failures=$((failures + 1))
    fi
done

# Coverage, not decoration: a glob that matched nothing would pass over no probe at all.
if [ "${allowed}" -ne 2 ] || [ "${refused}" -ne 11 ]; then
    echo "error: found ${allowed} allowed and ${refused} refused probes; expected 2 and 11"
    failures=$((failures + 1))
fi
if [ "${controls}" -ne 17 ]; then
    echo "error: ran ${controls} matcher controls; expected 17"
    failures=$((failures + 1))
fi

if [ "${failures}" -ne 0 ]; then
    echo "PROBES FAILED: ${failures} problem(s)"
    exit 1
fi
echo "PROBES PASSED: ${refused} shapes refused, ${allowed} positive controls compiled," \
    "${controls} matcher controls held"
# This must stay the script's last statement: anything after it that crashes would read as a pass
# on bash 3.2 again (see the trap above).
finished=1
