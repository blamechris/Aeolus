#!/usr/bin/env bash
# Compiles each lending probe against the helper module `swift build` produced, with the toolchain
# that runs this script, and requires the compiler to refuse every `refused-*.swift` probe — with
# the diagnostic its `// expect:` line names, in that probe's own file — and to accept every
# `allowed-*.swift` probe.
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
    swiftc -c -parse-as-library -swift-version 6 -I "${modules}" "$1" \
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
    if [ -z "${expect}" ]; then
        echo "error: ${name} has no // expect: line"
        failures=$((failures + 1))
        continue
    fi
    if compile "${probe}"; then
        echo "error: ${name} compiled. This toolchain no longer refuses the shape, so the"
        echo "       handback can be kept: see ADR 0012's #440 amendment before going further."
        failures=$((failures + 1))
        continue
    fi
    if grep -E -q -- "${name}:[0-9]+:[0-9]+: error: .*(${expect})" "${out}/log"; then
        echo "ok: ${name} refused: $(grep -E -m 1 -- "${name}:[0-9]+:[0-9]+: error:" "${out}/log")"
    else
        echo "error: ${name} failed to compile, but not with '${expect}' in its own file:"
        cat "${out}/log"
        failures=$((failures + 1))
    fi
done

# Coverage, not decoration: a glob that matched nothing would pass over no probe at all.
if [ "${allowed}" -ne 1 ] || [ "${refused}" -ne 8 ]; then
    echo "error: found ${allowed} allowed and ${refused} refused probes; expected 1 and 8"
    failures=$((failures + 1))
fi

if [ "${failures}" -ne 0 ]; then
    echo "LENDING PROBES FAILED: ${failures} problem(s)"
    exit 1
fi
echo "LENDING PROBES PASSED: ${refused} shapes refused, ${allowed} lend compiled"
