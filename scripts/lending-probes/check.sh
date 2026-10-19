#!/usr/bin/env bash
# Compiles each lending probe against the helper module `swift build` produced, with the toolchain
# that runs this script, and requires the compiler to accept every `allowed-*.swift` probe and to
# refuse every `refused-*.swift` probe for exactly the reason it states:
#
# - every error the compile reports, in any file, must be in that probe and match the
#   ownership-specific diagnostic its `// expect:` names; and
# - the shape's own line, its `// expect-line:`, must carry that error, or the move checker's
#   "consumed here" note that points at it (the move checker reports the error at the borrowed
#   parameter and the note at the use that would keep it).
#
# Any other error — a missing ownership keyword, an undefined type, an error in another file —
# fails the probe, so a probe cannot pass because it broke some other way.
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
    expected="(^|/)${name}:[0-9]+:[0-9]+: error: (${expect})"
    at_shape="(^|/)${name}:${line}:[0-9]+: (error: (${expect})|note: consumed here)"
    if [ -n "${errors}" ] && ! printf '%s\n' "${errors}" | grep -E -v -q -- "${expected}" \
        && grep -E -q -- "${at_shape}" "${out}/log"; then
        echo "ok: ${name} refused at line ${line}: $(printf '%s\n' "${errors}" | head -1 | sed 's|.*: error: ||')"
    else
        echo "error: ${name} must fail only with '${expect}', marked at line ${line}; it said:"
        cat "${out}/log"
        failures=$((failures + 1))
    fi
done

# Coverage, not decoration: a glob that matched nothing would pass over no probe at all.
if [ "${allowed}" -ne 1 ] || [ "${refused}" -ne 9 ]; then
    echo "error: found ${allowed} allowed and ${refused} refused probes; expected 1 and 9"
    failures=$((failures + 1))
fi

if [ "${failures}" -ne 0 ]; then
    echo "LENDING PROBES FAILED: ${failures} problem(s)"
    exit 1
fi
echo "LENDING PROBES PASSED: ${refused} shapes refused, ${allowed} lend compiled"
