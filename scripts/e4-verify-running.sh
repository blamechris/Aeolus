#!/bin/bash
# Checks that the AeolusHelper running on this Mac has the CDHash a build record names.
#
#     scripts/e4-verify-running.sh <expected-helper-cdhash>
#
# <expected-helper-cdhash> is the 64-hex sha256 CDHash of AeolusHelper from a record made by
# scripts/e4-build-record.sh. A universal helper has one per architecture; give the one for
# the architecture it runs as (an Apple Silicon Mac runs arm64).
#
# ## How the running hash is read
#
# From the kernel, with csops(2): the hash of the code signature the kernel validated when it
# launched the process. It is not read from the file on disk, because the file can be replaced
# after launch (a rebuild, an installer, someone swapping it) and then says nothing about what
# is running. Measured on macOS 27.0.1: a process started from one binary, whose file was then
# replaced by another, still answers with the first binary's hash through csops, while
# `codesign -d <pid>` reports the replacement's.
#
#   csops(pid, CS_OPS_CDHASH_WITH_INFO = 18, buf, 66): the full hash, as a csops_cdhash_t: 64
#       bytes of hash, a type byte (2 = sha256) and a length byte. This is compared in full.
#   csops(pid, CS_OPS_CDHASH = 5, buf, 20): the older, truncated 20-byte hash, used only if the
#       call above is refused as invalid. Only the first 40 hex digits of the expected hash
#       are then compared, and the output says so.
#   csops(pid, CS_OPS_STATUS = 0, buf, 4): the flags. The hash of a process whose signature
#       the kernel no longer calls CS_VALID (0x1) is not evidence, and the check refuses it.
#
# macOS has no man page for csops, and the public SDK has no <sys/codesign.h>. What the SDK
# does have: SYS_csops (169) in <sys/syscall.h>, and CS_VALID and csops_cdhash_t in
# <kern/cs_blobs.h>, whose comment names CS_OPS_CDHASH_WITH_INFO. The three CS_OPS_ numbers
# above are not in any header on this machine; they are XNU's (bsd/sys/codesign.h), and what
# stands behind them here is behaviour: the two hash calls answered with the hash `codesign -d`
# gives for launchd (pid 1), for a root daemon and for a process started for the purpose, and
# the status call answered with a flags word with CS_VALID set for each of them. perl makes
# the call because it ships with macOS (/usr/bin/perl on 27.0.1) and can issue a syscall
# without a compiler. Before it reads the helper it reads its own status and gives up if csops
# does not behave like csops. `man codesign` documents the pid forms of -d and -v that the
# fallback below uses.
#
# ## Does it need root?
#
# Not on macOS 27.0.1, where an ordinary user reads the hash of root's own daemons (launchd,
# fseventsd). That is the evidence: the installed helper was NOT read to find it out, and this
# script has never been run against it. If the kernel does refuse (EPERM or EACCES) the script
# says so and exits 14; rerun it under sudo. It never runs sudo itself.
#
# ## The fallback, and what it weakens
#
# If perl or csops cannot be used, the script falls back to the file: `codesign -v <pid>`
# (which asks whether the code on disk matches what is running) and then the hash that
# `codesign -d` reads from the file. The output says "FALLBACK" and that this is weaker
# evidence: a match then says the file at the process's path is the recorded one and that
# the process still agrees with it, not that the kernel's own hash was read. If the file no
# longer agrees with the process the hash of what is running is unknown, and the exit is 13.
#
# ## What a match proves
#
# That the process currently named AeolusHelper was launched from code whose CodeDirectory
# hashes to the recorded value, and that the kernel still considers its signature valid. A
# CodeDirectory hash covers the binary's pages, its entitlements and its Info.plist, so it
# names that build and no other.
#
# ## What it does not prove
#
# - That the recorded hash is the build the gate reviewed. The record says so; this checks
#   only that the running helper agrees with the record.
# - Anything about the app, fanctl, or any process that is not the one found.
# - What the helper is doing, or whether it is healthy. It is not asked anything; it is not
#   sent a message and it is not signalled.
#
# ## Testing seams (not for operators)
#
#   E4_VERIFY_PROCESS_NAME       the process name to look for. Default AeolusHelper. The test
#                                points it at a copy of a small binary it starts itself.
#   E4_VERIFY_NO_CSOPS=1         forces the fallback.
#   E4_VERIFY_SIMULATE_ERRNO=N   makes the csops read fail with errno N.
#   E4_VERIFY_SIMULATE_INVALID=1 reads the flags as if the kernel had cleared CS_VALID.
#
# None of them can make a hash that differs from the expected one compare equal. They select
# what is looked at, a failure, or the weaker fallback (which says that it is one).
#
# Exit status:
#   0   match
#   2   usage: not exactly one 64-hex argument
#   10  mismatch: the helper is running and is not the recorded build
#   11  no helper is running (or it exited while being read)
#   12  more than one helper is running
#   13  the signature could not be read, or cannot be trusted
#   14  reading it needs root: rerun under sudo

set -euo pipefail

readonly EX_USAGE=2
readonly EX_MISMATCH=10
readonly EX_NONE=11
readonly EX_MANY=12
readonly EX_UNREADABLE=13
readonly EX_NEEDS_ROOT=14

readonly PGREP=/usr/bin/pgrep
readonly PERL=/usr/bin/perl
readonly CODESIGN=/usr/bin/codesign

die() {
    local status="$1"
    shift
    echo "error: $*" >&2
    exit "${status}"
}

if [ "$#" -ne 1 ]; then
    die "${EX_USAGE}" "usage: $(basename "$0") <expected-helper-cdhash>   (the 64-hex sha256 CDHash from the build record)"
fi
expected=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
if ! [[ "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
    die "${EX_USAGE}" "the expected CDHash must be the full 64-hex sha256 value from the record, not a truncated one"
fi

process_name="${E4_VERIFY_PROCESS_NAME:-AeolusHelper}"

# --- Find the helper ----------------------------------------------------------------------

pids=$("${PGREP}" -x "${process_name}" || true)
count=$(printf '%s' "${pids}" | grep -c . || true)
if [ "${count}" -eq 0 ]; then
    die "${EX_NONE}" "no process named ${process_name} is running"
fi
if [ "${count}" -gt 1 ]; then
    die "${EX_MANY}" "${count} processes named ${process_name} are running (pids $(printf '%s' "${pids}" | tr '\n' ' ')); a check of one of them says nothing about the others"
fi
pid="${pids}"

# The path the kernel has for the process. Informational: it is not what is compared.
executable=$("${CODESIGN}" -d "${pid}" 2>&1 | sed -n 's/^Executable=//p' | sed -n '1p' || true)
if [ -z "${executable}" ]; then
    executable="(not readable)"
fi

# --- Read the running hash from the kernel ------------------------------------------------

# Prints "status=0x..", "bytes=N" and "cdhash=<hex>" on success. On failure prints
# "errno=N" and exits non-zero. 66 is the size of csops_cdhash_t: 64 bytes of hash, the type
# and the length.
read -r -d '' PERL_READER <<'PERL' || true
use strict; use warnings;
my ($pid, $simulate) = @ARGV;
sub csops {
    my ($target, $op, $size) = @_;
    my $buf = "\0" x $size;
    my $r = syscall(169, $target + 0, $op + 0, $buf, $size + 0);
    return ($r == 0) ? $buf : undef;
}
if ($simulate ne "") { print "errno=$simulate\n"; exit 1; }
# csops must behave like csops before it is believed: this process is signed and valid.
my $self = csops($$, 0, 4);
if (!defined $self || !(unpack("V", $self) & 0x1)) { print "errno=selfcheck\n"; exit 1; }
my $status = csops($pid, 0, 4);
if (!defined $status) { print "errno=", $! + 0, "\n"; exit 1; }
printf "status=0x%08x\n", unpack("V", $status);
my $full = csops($pid, 18, 66);
if (defined $full) {
    my ($type, $length) = unpack("x64 C C", $full);
    if ($type != 2 || $length != 32) { print "errno=hashtype\n"; exit 1; }
    print "bytes=32\ncdhash=", unpack("H64", $full), "\n";
    exit 0;
}
if ($! + 0 != 22) { print "errno=", $! + 0, "\n"; exit 1; }
my $short = csops($pid, 5, 20);
if (!defined $short) { print "errno=", $! + 0, "\n"; exit 1; }
print "bytes=20\ncdhash=", unpack("H40", $short), "\n";
PERL

kernel_reading=""
kernel_errno=""
if [ -z "${E4_VERIFY_NO_CSOPS:-}" ] && [ -x "${PERL}" ]; then
    if kernel_reading=$("${PERL}" -e "${PERL_READER}" -- "${pid}" "${E4_VERIFY_SIMULATE_ERRNO:-}" 2>/dev/null); then
        kernel_errno=""
    else
        kernel_errno=$(printf '%s\n' "${kernel_reading}" | sed -n 's/^errno=//p')
        kernel_reading=""
    fi
else
    kernel_errno="unavailable"
fi

case "${kernel_errno}" in
    1 | 13)
        die "${EX_NEEDS_ROOT}" "the kernel refused to give a non-root user the signature of pid ${pid} (errno ${kernel_errno}); rerun this under sudo. This script does not run sudo."
        ;;
    3)
        die "${EX_NONE}" "pid ${pid} (${process_name}) exited while it was being read"
        ;;
esac

report() { # label value
    printf '  %-12s %s\n' "$1" "$2"
}

if [ -n "${kernel_reading}" ]; then
    status_word=$(printf '%s\n' "${kernel_reading}" | sed -n 's/^status=//p')
    bytes=$(printf '%s\n' "${kernel_reading}" | sed -n 's/^bytes=//p')
    running=$(printf '%s\n' "${kernel_reading}" | sed -n 's/^cdhash=//p')
    if ! [[ "${running}" =~ ^[0-9a-f]+$ ]] || [ -z "${bytes}" ] || [ -z "${status_word}" ]; then
        die "${EX_UNREADABLE}" "the kernel's answer for pid ${pid} could not be understood"
    fi
    echo "e4-verify-running: ${process_name} pid ${pid}"
    report "executable:" "${executable}"
    report "read from:" "the kernel (csops), the hash of the signature the process was launched with"
    if [ -n "${E4_VERIFY_SIMULATE_INVALID:-}" ]; then
        status_word=0x00000000
    fi
    report "flags:" "${status_word}"
    if [ $((status_word & 0x1)) -eq 0 ]; then
        die "${EX_UNREADABLE}" "the kernel no longer calls the signature of pid ${pid} valid (CS_VALID is clear in ${status_word}); its hash is not evidence"
    fi
    report "running:" "${running}"
    report "expected:" "${expected}"
    if [ "${bytes}" -eq 20 ]; then
        report "compared:" "the first 40 hex digits only: this kernel gave the truncated 20-byte hash"
        expected_part="${expected:0:40}"
    else
        expected_part="${expected}"
    fi
    if [ "${running}" = "${expected_part}" ]; then
        report "result:" "MATCH"
        exit 0
    fi
    report "result:" "MISMATCH: the running helper is not the recorded build"
    exit "${EX_MISMATCH}"
fi

# --- Fallback: the file, checked against the process --------------------------------------

echo "e4-verify-running: ${process_name} pid ${pid}"
report "executable:" "${executable}"
case "${kernel_errno}" in
    '') why="no answer" ;;
    unavailable) why="perl or csops is not available here" ;;
    selfcheck | hashtype) why="csops did not behave as expected: ${kernel_errno}" ;;
    *) why="errno ${kernel_errno}" ;;
esac
report "read from:" "FALLBACK: the file on disk, not the kernel (csops was not usable: ${why})"
report "evidence:" "WEAKER. A match says the file at that path is the recorded one and the process still agrees with it."

if ! validity=$("${CODESIGN}" -v "${pid}" 2>&1); then
    # The one line codesign gives; it names the pid and the problem, not the signer.
    report "codesign -v:" "$(printf '%s\n' "${validity}" | sed -n '1p')"
    die "${EX_UNREADABLE}" "the file on disk does not agree with the running process, or cannot be checked, so what is running is unknown without csops"
fi
report "codesign -v:" "the code on disk matches what is running"

# The hash codesign reads from the file. Raw output is never printed: it carries the signer.
if ! signature=$("${CODESIGN}" -d --verbose=4 "${pid}" 2>&1); then
    die "${EX_UNREADABLE}" "codesign could not read the signature of pid ${pid}"
fi
running=$(printf '%s\n' "${signature}" | sed -n 's/^CandidateCDHashFull sha256=//p')
if ! [[ "${running}" =~ ^[0-9a-f]{64}$ ]]; then
    die "${EX_UNREADABLE}" "codesign gave no sha256 CDHash for pid ${pid}"
fi
report "running:" "${running} (the file's)"
report "expected:" "${expected}"
if [ "${running}" = "${expected}" ]; then
    report "result:" "MATCH (fallback: weaker evidence)"
    exit 0
fi
report "result:" "MISMATCH: the running helper is not the recorded build"
exit "${EX_MISMATCH}"
