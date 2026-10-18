#!/bin/bash -p
# Checks that the AeolusHelper running on this Mac has the CDHash a build record names.
#
#     scripts/e4-verify-running.sh <expected-helper-cdhash>
#
# <expected-helper-cdhash> is the 64-hex sha256 CDHash of AeolusHelper from a record made by
# scripts/e4-build-record.sh. A universal helper has one per architecture; give the one for
# the architecture it runs as (an Apple Silicon Mac runs arm64).
#
# **The operator's test is exactly: exit status 0 and a last line equal to
# `result=verified seams=none`.** Nothing else is a verification. Whenever the script reaches a
# verdict (every exit in the table at the end of this header except 1) the last line of
# standard output is `result=<word> seams=<none|ACTIVE(...)>`, and the exit status says the
# same thing as the word. A consumer that greps must anchor the whole line, never a substring.
#
# ## The environment
#
# The script does not trust the one it is started in. `#!/bin/bash -p` makes macOS's bash 3.2
# ignore BASH_ENV, ENV and SHELLOPTS and import no shell function from the environment. It
# does not make bash 3.2 ignore CDPATH or GLOBIGNORE (CDPATH is still honoured by `cd`), which
# the scrub below unsets for that reason; BASHOPTS does not exist in 3.2.
#
# `bash script` ignores the flag on the shebang line and imports functions, and one imported
# `sed` is enough to print `result=verified seams=none` for a hash the process does not have.
# So the first thing the script does is refuse to run unless bash was started with `-p`. The
# refusal is a parameter expansion, `${…:?}`, because every command name, `echo` and `exit`
# included, could be an imported function that swallows the refusal; a parameter expansion and
# `case` are syntax and cannot be replaced. Bash 3.2 exits 1 for it, prints nothing on
# standard output (so there is no `result=` line, and the operator's test fails on both
# counts), and says why on standard error. Two tests, both required:
# - `$-` contains `p`.
# - The kernel's record of this process's arguments, `/bin/ps -ww -o args= -p $$` (a path, so
#   never a function), has `-p` straight after the shell's own name.
# The first alone is not proof: `SHELLOPTS=privileged bash script`, and a BASH_ENV file that
# runs `set -p` and unsets itself, both put `p` in `$-` after bash has imported the functions
# or run the file. Neither puts `-p` in the arguments, which bash reads before it touches the
# environment. (A parent that execs bash under a forged argument vector controls the process,
# which is beyond what a script can check.) `SHELLOPTS=noexec bash script` is the one start
# this cannot refuse, because noexec skips every command, the guard included: it exits 0 and
# prints nothing, which is why the operator's test above insists on the last line as well as
# the exit status.
#
# It then refuses (exit 2) to run with BASH_ENV or ENV set, or with xtrace or verbose on,
# either of which would print the signature output it reads. It pins PATH to /usr/bin:/bin and
# the locale to C, and unsets GREP_*, GIT_*, DYLD_*, PERL*, LD_*, CDPATH, GLOBIGNORE and
# POSIXLY_CORRECT. The perl reader below runs under `env -i`, with an empty environment and no
# `use` line, so neither PERL5LIB, PERL5OPT nor a module on a search path can replace the code
# that reads the kernel.
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
#   csops(pid, CS_OPS_CDHASH = 5, buf, 20): the older, truncated 20-byte hash.
#   csops(pid, CS_OPS_STATUS = 0, buf, 4): the flags.
#
# **This depends on the OS.** The 66-byte csops_cdhash_t exists in the macOS 27 SDK. The
# macOS 26.5 SDK and XNU's main branch define it as 21 bytes (a 20-byte hash and a type), so
# on macOS 26 the first call is refused as invalid (EINVAL) and every check is the second one:
# only the first 40 hex digits of the expected hash are compared, the output says so, the
# result word is `truncated-match`, and the exit status is 18, never 0. Exit 0 means a full
# 32-byte verification and nothing else. A 160-bit prefix is the kernel's own identity for a
# code directory (CS_CDHASH_LEN), but it is not the whole sha256.
#
# macOS has no man page for csops, and the public SDK has no <sys/codesign.h>. What the SDK
# does have: SYS_csops (169) in <sys/syscall.h>, and CS_VALID, CS_INVALID_ALLOWED,
# CS_DEBUGGED and csops_cdhash_t in <kern/cs_blobs.h>, whose comment names
# CS_OPS_CDHASH_WITH_INFO. The three CS_OPS_ numbers above are not in any header on this
# machine; they are XNU's (bsd/sys/codesign.h), and what stands behind them here is
# behaviour: the two hash calls answered with the hash `codesign -d` gives for launchd
# (pid 1), for a root daemon and for a process started for the purpose, and the status call
# answered with a flags word with CS_VALID set for each of them. perl makes the call because
# it ships with macOS (/usr/bin/perl on 27.0.1) and can issue a syscall without a compiler.
# Before it reads the helper it reads its own status and gives up if csops does not behave
# like csops. `man codesign` documents the pid forms of -d and -v that the fallback below uses.
#
# ## One process, one instance
#
# The answer is tied to a single process instance, in this order:
#   1. pgrep -x finds exactly one process named AeolusHelper. None is 11, more than one is 12,
#      a failing pgrep is 13.
#   2. Its uid and start time are read with ps. The uid must be 0: the real helper is a root
#      launch daemon, and a copy of the name under another user does not verify (17).
#   3. csops reads the flags, then the hash, then the flags again.
#   4. pgrep runs again, and must return the same single pid with the same start time and
#      uid (a reused pid, or a restart, is 13; the process having gone is 11).
#   5. csops reads the flags, the hash and the flags a second time. The hash must equal the
#      first one: a process that exec'd another image between the reads does not verify (13).
#   6. In all four flag reads CS_VALID must be set and CS_DEBUGGED and CS_INVALID_ALLOWED
#      clear (16 for the latter two, 13 for CS_VALID).
# The start time has a resolution of a second, which is enough here: reusing a pid takes the
# pid space going round (99,999 processes), not the same second.
#
# ## Why CS_DEBUGGED and CS_INVALID_ALLOWED refuse
#
# XNU sets CS_DEBUGGED (0x10000000 in <kern/cs_blobs.h>: "currently or has previously been
# debugged and allowed to run with invalid pages") when a debugger attaches, and a debugged
# process may run pages that no longer match its signature without CS_VALID ever clearing.
# Writes to data pages never clear it. CS_INVALID_ALLOWED (0x20, same header: "page
# invalidation allowed by task port policy") appeared with it when a debugger was attached to
# a get-task-allow process. A Full Debug build, the bring-up configuration, carries
# get-task-allow, so a debugger can attach to it. The recorded hash then says what the process
# was launched from and not what it is running, so the script refuses (16) and prints the
# flags it checked. A helper that was debugged earlier needs relaunching.
#
# ## Does it need root?
#
# Not on macOS 27.0.1, where an ordinary user reads the hash of root's own daemons (launchd,
# fseventsd). That is the evidence: the installed helper was NOT read to find it out, and this
# script has never been run against it. If the kernel does refuse (EPERM or EACCES) the script
# says so and exits 14; rerun it under sudo. It never runs sudo itself.
#
# ## The fallback, and why it never says "verified"
#
# If /usr/bin/perl is missing, the script reads the file instead: `codesign -d <pid>`, then
# `codesign -v <pid>` (which asks whether the code on disk matches what is running), then
# `codesign -d <pid>` again. The two hashes must be equal and -v must pass. Even then a match
# is `file-only` and exits 15: the file at the process's path is the recorded one and the
# process agreed with it at that moment, but the kernel's own hash was not read and nothing
# was checked for a debugger. A file swapped in between the reads is 13. The fallback is used
# only when perl is missing; when perl ran and csops answered strangely, the kernel answered,
# and the exit is 13 with no second attempt.
#
# ## What a match proves
#
# `verified`: that the process currently named AeolusHelper, as one root-owned instance, was
# launched from code whose CodeDirectory hashes to the recorded value, twice, either side of a
# second look at the process; that the kernel still considered its signature valid; and that
# no debugger had been allowed to run it with invalid pages. A CodeDirectory hash covers the
# binary's pages, its entitlements and its Info.plist, so it names that build and no other.
#
# ## What it does not prove
#
# - That the recorded hash is the build the gate reviewed. The record says so; this checks
#   only that the running helper agrees with the record.
# - Anything about the app, fanctl, or any process that is not the one found.
# - What the helper is doing, or whether it is healthy. It is not asked anything; it is not
#   sent a message and it is not signalled.
# - That nothing changed after the last read. A check is a moment, not a guarantee.
# - Anything against a process with the privilege to defeat a user-space reader. A root
#   process that can exec into the helper's pid between the two reads and back, or a kernel
#   extension, defeats this check and every other one made from user space. The second read
#   catches an exec that is still in place; it does not make the check proof against root.
#
# ## Output
#
# The executable is named by a label, AeolusHelper or "other", and by whether it is under
# /Applications/ or /Library/. A path elsewhere is never printed, because it can carry a user
# name, and no `codesign` diagnostic is passed on: the messages are this script's own.
#
# ## Testing seams (not for operators)
#
#   E4_VERIFY_PROCESS_NAME       the process name to look for. Default AeolusHelper.
#   E4_VERIFY_ALLOW_NONROOT=1    accept a process that is not owned by uid 0.
#   E4_VERIFY_NO_CSOPS=1         forces the fallback.
#   E4_VERIFY_SIMULATE_ERRNO=N   makes the csops read fail with errno N.
#   E4_VERIFY_SIMULATE_DEBUGGED=1  reads the first flags with CS_DEBUGGED set; =after, the
#                                second; =allowed, the first with CS_INVALID_ALLOWED set.
#   E4_VERIFY_SIMULATE_INVALID=1   reads the first flags with CS_VALID cleared.
#   E4_VERIFY_SIMULATE_INVALID_AFTER=1  the same for the read after the hash.
#   E4_VERIFY_SIMULATE_RESTART=1   reads a different start time on the second look.
#
# **Every active seam is announced**: a banner is the first line of output, the last line
# carries `seams=ACTIVE(...)`, and a run with any seam active never exits 0: where it would
# have, it exits 19, with the result word it would have had. A run made with a seam cannot
# pass for a check of the helper. None of them can make a hash that differs from the expected
# one compare equal; they select what is looked at, accept a non-root process, or produce a
# failure.
#
# ## Result words and exit status
#
# The words share no substring: a plain `grep` for one cannot match another.
#
#   exit  result=            meaning
#   0     verified           the kernel's full sha256 equals the expected one, read twice,
#                            and no seam is active. The only exit 0.
#   2     usage              not exactly one 64-hex argument, or an environment the script
#                            refuses to run in (BASH_ENV, ENV, xtrace, verbose)
#   10    mismatch           the helper is running and is not the recorded build
#   11    not-running        no helper is running, or it went away while being read
#   12    several-running    more than one helper is running
#   13    unreadable         the signature could not be read or cannot be trusted: a tool
#                            failed (including pgrep, ps or a parser), csops answered
#                            unexpectedly, CS_VALID was missing or cleared, the hash changed
#                            between the two reads, or the process changed (pid, start time,
#                            uid) during the check
#   14    needs-root         the kernel refused a non-root reader: rerun under sudo
#   15    file-only          fallback only: the file matches, the running image is not proven
#   16    debugged           CS_DEBUGGED or CS_INVALID_ALLOWED is set: the hash does not say
#                            what is running
#   17    not-root-owned     the process is not owned by uid 0, so it is not the helper
#   18    truncated-match    only the kernel's 20-byte hash exists on this macOS, and its
#                            40 hex digits equal the expected one's first 40
#   19    verified or        a seam is active: the verdict would have been exit 0 or 18, and
#         truncated-match    the word says which; a test run never exits 0
#   1     (none)             not a verdict, and not a code of this script's own: macOS's bash
#                            3.2 ended the run because it was not started with -p. Nothing was
#                            looked at and no `result=` line is printed; see "The environment"

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

refuse_environment() {
    echo "error: $1" >&2
    echo "result=usage seams=none"
    exit 2
}
case "$-" in
    *[xv]*) refuse_environment "refusing to run with xtrace or verbose on: they would print the signature output this script keeps out of its messages" ;;
esac
if [ -n "${BASH_ENV:-}" ] || [ -n "${ENV:-}" ]; then
    refuse_environment "refusing to run with BASH_ENV or ENV set: the file would run before this script and could change what it does"
fi
PATH=/usr/bin:/bin
export PATH
LC_ALL=C
export LC_ALL
for scrub_name in $(compgen -e); do
    case "${scrub_name}" in
        GIT_* | GREP_* | DYLD_* | PERL* | LD_* | CDPATH | GLOBIGNORE | POSIXLY_CORRECT)
            unset "${scrub_name}"
            ;;
    esac
done

set -Eeuo pipefail

readonly EX_USAGE=2
readonly EX_MISMATCH=10
readonly EX_NONE=11
readonly EX_MANY=12
readonly EX_UNREADABLE=13
readonly EX_NEEDS_ROOT=14
readonly EX_FILE_ONLY=15
readonly EX_DEBUGGED=16
readonly EX_NOT_ROOT=17
readonly EX_TRUNCATED=18
readonly EX_SEAMS=19

readonly CS_VALID=$((0x00000001))
readonly CS_INVALID_ALLOWED=$((0x00000020))
readonly CS_DEBUGGED=$((0x10000000))

readonly PGREP=/usr/bin/pgrep
readonly PS=/bin/ps
readonly PERL=/usr/bin/perl
readonly ENV_BIN=/usr/bin/env
readonly CODESIGN=/usr/bin/codesign

# --- Seams, announced first ---------------------------------------------------------------

seams=""
for seam_name in E4_VERIFY_PROCESS_NAME E4_VERIFY_ALLOW_NONROOT E4_VERIFY_NO_CSOPS \
    E4_VERIFY_SIMULATE_ERRNO E4_VERIFY_SIMULATE_DEBUGGED E4_VERIFY_SIMULATE_INVALID \
    E4_VERIFY_SIMULATE_INVALID_AFTER E4_VERIFY_SIMULATE_RESTART; do
    if [ -n "${!seam_name:-}" ]; then
        seams="${seams:+${seams},}${seam_name}"
    fi
done
if [ -n "${seams}" ]; then
    seam_state="ACTIVE(${seams})"
    echo "*** TEST SEAMS ACTIVE: ${seams}. This run tests the script; it does not check the helper. ***"
else
    seam_state="none"
fi

# Ends the run: a message on standard error, then the result line, then the exit status.
# Never called inside $( ), where the result line would be captured.
finish() {
    local word="$1" status="$2"
    shift 2
    if [ "$#" -gt 0 ]; then
        echo "error: $*" >&2
    fi
    echo "result=${word} seams=${seam_state}"
    exit "${status}"
}

# A match ends here. Exit 0 is a full verification with no seam active and nothing else.
conclude_match() { # word: verified | truncated-match
    if [ "${seam_state}" != "none" ]; then
        finish "$1" "${EX_SEAMS}" "a seam is active, so this run tests the script and never exits 0"
    fi
    if [ "$1" = "truncated-match" ]; then
        finish truncated-match "${EX_TRUNCATED}" "only the first 20 bytes of the hash were compared; exit 0 is reserved for the full verification"
    fi
    finish verified 0
}

# A command that fails where this script did not expect it to is an unreadable signature, with
# a code of this script's own and not the failing command's. In a subshell it only leaves it,
# with the failing command's status, for the assignment that ran it to read.
trap 'status=$?; if [ "${BASH_SUBSHELL}" -gt 0 ]; then exit "${status}"; fi; finish unreadable "${EX_UNREADABLE}" "a system tool failed unexpectedly (line ${LINENO}); nothing was verified"' ERR

report() { # label value
    printf '  %-12s %s\n' "$1" "$2"
}

# --- Arguments ----------------------------------------------------------------------------

if [ "$#" -ne 1 ]; then
    finish usage "${EX_USAGE}" "usage: $(basename "$0") <expected-helper-cdhash>   (the 64-hex sha256 CDHash from the build record)"
fi
expected=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
if ! [[ "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
    finish usage "${EX_USAGE}" "the expected CDHash must be the full 64-hex sha256 value from the record, not a truncated one"
fi

process_name="${E4_VERIFY_PROCESS_NAME:-AeolusHelper}"
# What may be said about the name: the helper's own, or "other".
if [ "${process_name}" = "AeolusHelper" ]; then
    process_label="AeolusHelper"
else
    process_label="other"
fi

# --- Looking at the process ---------------------------------------------------------------

# Looks for the process by name. Sets found_pids and returns 0 for exactly one, 1 for none,
# 3 for several, 4 if pgrep itself failed or gave something that is not a pid.
lookup() {
    local output status=0 line count=0
    output=$("${PGREP}" -x "${process_name}" 2>/dev/null) || status=$?
    found_pids=""
    case "${status}" in
        0) ;;
        1) return 1 ;;
        *) return 4 ;;
    esac
    found_pids="${output}"
    while IFS= read -r line; do
        if [ -n "${line}" ]; then
            count=$((count + 1))
        fi
    done <<EOF
${output}
EOF
    if [ "${count}" -gt 1 ]; then
        return 3
    fi
    [[ "${found_pids}" =~ ^[0-9]+$ ]] || return 4
    return 0
}

# Sets instance_uid and instance_start for a pid. Returns 0, 1 if there is no such process,
# or 3 if ps answered and the answer could not be parsed. The parsers' own statuses count.
instance_of() {
    local output
    output=$("${PS}" -p "$1" -o uid= -o lstart= 2>/dev/null) || return 1
    [ -n "${output}" ] || return 1
    instance_uid=$(printf '%s\n' "${output}" | awk '{print $1}') || return 3
    instance_start=$(printf '%s\n' "${output}" | awk '{$1=""; print}' | sed 's/^ *//') || return 3
    [ -n "${instance_start}" ] || return 3
    [[ "${instance_uid}" =~ ^[0-9]+$ ]] || return 3
    return 0
}

# Looks at the process and ends the run if it is gone (11) or ps's answer cannot be parsed (13).
look_at() {
    local look_status=0
    instance_of "$1" || look_status=$?
    case "${look_status}" in
        0) ;;
        1) finish not-running "${EX_NONE}" "pid $1 (${process_label}) went away while it was being read" ;;
        *) finish unreadable "${EX_UNREADABLE}" "ps gave an answer for pid $1 that could not be parsed; nothing was verified" ;;
    esac
}

# What may be said about a path: a label for its name, and whether it is under /Applications/
# or /Library/. Never the path, which can carry a user name.
describe_executable() {
    local path="$1" where label
    case "${path}" in
        /Applications/*) where="under /Applications/" ;;
        /Library/*) where="under /Library/" ;;
        *) where="elsewhere; path not shown" ;;
    esac
    if [ "$(basename "${path}")" = "AeolusHelper" ]; then
        label="AeolusHelper"
    else
        label="other"
    fi
    printf '%s (%s)' "${label}" "${where}"
}

lookup_status=0
lookup || lookup_status=$?
case "${lookup_status}" in
    0) ;;
    1) finish not-running "${EX_NONE}" "no process named ${process_label} is running" ;;
    3) finish several-running "${EX_MANY}" "several processes named ${process_label} are running (pids $(printf '%s' "${found_pids}" | tr '\n' ' ')); a check of one of them says nothing about the others" ;;
    *) finish unreadable "${EX_UNREADABLE}" "pgrep failed, so it is not known whether the helper is running" ;;
esac
pid="${found_pids}"

look_at "${pid}"
uid_first="${instance_uid}"
start_first="${instance_start}"

echo "e4-verify-running: ${process_label} pid ${pid}"
report "process:" "uid ${uid_first}, started ${start_first}"

# The executable's path, for the reader. Best effort and never printed as it is.
raw_executable=$("${CODESIGN}" -d "${pid}" 2>&1 | sed -n 's/^Executable=//p' | sed -n '1p' || true)
if [ -n "${raw_executable}" ]; then
    report "executable:" "$(describe_executable "${raw_executable}")"
else
    report "executable:" "(not readable)"
fi

if [ "${uid_first}" != "0" ] && [ -z "${E4_VERIFY_ALLOW_NONROOT:-}" ]; then
    finish not-root-owned "${EX_NOT_ROOT}" "pid ${pid} is owned by uid ${uid_first}; the helper is a root daemon, so this is not it"
fi

# Looks again, and requires the same single process: the same pid, start time and uid.
# Ends the run on any difference.
confirm_same_instance() {
    local again_status=0 start_again
    lookup || again_status=$?
    case "${again_status}" in
        0) ;;
        1) finish not-running "${EX_NONE}" "the helper went away during the check" ;;
        *) finish unreadable "${EX_UNREADABLE}" "the lookup changed during the check (${found_pids:-pgrep failed}); not the same process" ;;
    esac
    if [ "${found_pids}" != "${pid}" ]; then
        finish unreadable "${EX_UNREADABLE}" "the helper's pid changed during the check; not the same process"
    fi
    look_at "${pid}"
    start_again="${instance_start}"
    if [ -n "${E4_VERIFY_SIMULATE_RESTART:-}" ]; then
        start_again="${start_again} (simulated restart)"
    fi
    if [ "${start_again}" != "${start_first}" ] || [ "${instance_uid}" != "${uid_first}" ]; then
        finish unreadable "${EX_UNREADABLE}" "the process's start time or owner changed during the check; the pid was reused or the helper restarted"
    fi
}

# --- Reading from the kernel --------------------------------------------------------------

# Prints "status1=0x..", "bytes=N", "cdhash=<hex>" and "status2=0x.." on success. On failure
# prints "errno=<N or a word>" and exits non-zero. 66 is the size of csops_cdhash_t on macOS
# 27: 64 bytes of hash, the type and the length. No `use` line: it runs under an empty
# environment, and loads no module.
read -r -d '' PERL_READER <<'PERL' || true
my ($pid, $simulate, $sim_debugged, $sim_invalid, $sim_invalid_after) = @ARGV;
sub csops {
    my ($target, $op, $size) = @_;
    my $buf = "\0" x $size;
    my $r = syscall(169, $target + 0, $op + 0, $buf, $size + 0);
    return ($r == 0) ? $buf : undef;
}
sub fail { print "errno=$_[0]\n"; exit 1; }
if ($simulate ne "") { fail($simulate); }
# csops must behave like csops before it is believed: this process is signed and valid.
my $self = csops($$, 0, 4);
if (!defined $self || !(unpack("V", $self) & 0x1)) { fail("selfcheck"); }
my $first = csops($pid, 0, 4);
if (!defined $first) { fail($! + 0); }
my $flags1 = unpack("V", $first);
if ($sim_debugged eq "allowed") { $flags1 |= 0x20; }
elsif ($sim_debugged ne "" && $sim_debugged ne "after") { $flags1 |= 0x10000000; }
if ($sim_invalid ne "") { $flags1 &= ~0x1; }
my ($bytes, $hex);
my $full = csops($pid, 18, 66);
if (defined $full) {
    my ($type, $length) = unpack("x64 C C", $full);
    if ($type != 2 || $length != 32) { fail("hashtype"); }
    $bytes = 32;
    $hex = unpack("H64", $full);
} else {
    if ($! + 0 != 22) { fail($! + 0); }
    my $short = csops($pid, 5, 20);
    if (!defined $short) { fail($! + 0); }
    $bytes = 20;
    $hex = unpack("H40", $short);
}
my $second = csops($pid, 0, 4);
if (!defined $second) { fail($! + 0); }
my $flags2 = unpack("V", $second);
if ($sim_invalid_after ne "") { $flags2 &= ~0x1; }
if ($sim_debugged eq "after") { $flags2 |= 0x10000000; }
printf "status1=0x%08x\nbytes=%d\ncdhash=%s\nstatus2=0x%08x\n", $flags1, $bytes, $hex, $flags2;
PERL

if [ -z "${E4_VERIFY_NO_CSOPS:-}" ] && [ -x "${PERL}" ] && [ -x "${ENV_BIN}" ]; then
    read_mode="kernel"
else
    read_mode="fallback"
fi

# One kernel read: the flags, the hash, the flags. Sets k_before, k_after, k_bytes and k_hash;
# ends the run on any failure.
kernel_read() {
    local reading="" read_status=0 failure
    reading=$("${ENV_BIN}" -i "${PERL}" -e "${PERL_READER}" -- "${pid}" "${E4_VERIFY_SIMULATE_ERRNO:-}" \
        "${E4_VERIFY_SIMULATE_DEBUGGED:-}" "${E4_VERIFY_SIMULATE_INVALID:-}" \
        "${E4_VERIFY_SIMULATE_INVALID_AFTER:-}" 2>/dev/null) || read_status=$?
    if [ "${read_status}" -ne 0 ]; then
        failure=$(printf '%s\n' "${reading}" | sed -n 's/^errno=//p')
        case "${failure}" in
            1 | 13)
                finish needs-root "${EX_NEEDS_ROOT}" "the kernel refused to give a non-root user the signature of pid ${pid} (errno ${failure}); rerun this under sudo. This script does not run sudo."
                ;;
            3)
                finish not-running "${EX_NONE}" "pid ${pid} (${process_label}) exited while it was being read"
                ;;
            '')
                finish unreadable "${EX_UNREADABLE}" "the reader gave no answer for pid ${pid}; nothing was verified"
                ;;
            *)
                finish unreadable "${EX_UNREADABLE}" "csops answered pid ${pid} unexpectedly (${failure}); the kernel did answer, so there is no second attempt through the file"
                ;;
        esac
    fi
    k_before=$(printf '%s\n' "${reading}" | sed -n 's/^status1=//p')
    k_after=$(printf '%s\n' "${reading}" | sed -n 's/^status2=//p')
    k_bytes=$(printf '%s\n' "${reading}" | sed -n 's/^bytes=//p')
    k_hash=$(printf '%s\n' "${reading}" | sed -n 's/^cdhash=//p')
    if ! [[ "${k_before}" =~ ^0x[0-9a-f]{8}$ ]] || ! [[ "${k_after}" =~ ^0x[0-9a-f]{8}$ ]] \
        || ! [[ "${k_bytes}" =~ ^(20|32)$ ]] || ! [[ "${k_hash}" =~ ^[0-9a-f]+$ ]]; then
        finish unreadable "${EX_UNREADABLE}" "the kernel's answer for pid ${pid} could not be understood"
    fi
}

# Requires the two flag words of one read to show a signature that is valid, with no debugger
# and no page invalidation allowed. $3 names the read. Ends the run otherwise.
check_flags() {
    local flags
    for flags in "$1" "$2"; do
        if [ $((flags & (CS_DEBUGGED | CS_INVALID_ALLOWED))) -ne 0 ]; then
            finish debugged "${EX_DEBUGGED}" "CS_DEBUGGED or CS_INVALID_ALLOWED is set in ${flags} (${3}) for pid ${pid}: a debugger was allowed to run it, so its hash does not say what is running; relaunch the helper"
        fi
    done
    for flags in "$1" "$2"; do
        if [ $((flags & CS_VALID)) -eq 0 ]; then
            finish unreadable "${EX_UNREADABLE}" "CS_VALID is clear in ${flags} (${3}) for pid ${pid}: the kernel no longer calls its signature valid, so its hash is not evidence"
        fi
    done
}

if [ "${read_mode}" = "kernel" ]; then
    kernel_read
    first_hash="${k_hash}"
    first_bytes="${k_bytes}"
    report "read from:" "the kernel (csops), the hash of the signature the process was launched with"
    report "flags:" "first read: before the hash ${k_before}, after ${k_after}"
    check_flags "${k_before}" "${k_after}" "first read"
    report "running:" "${first_hash}"
    report "expected:" "${expected}"
    confirm_same_instance
    kernel_read
    report "flags:" "repeat read: before the hash ${k_before}, after ${k_after}"
    check_flags "${k_before}" "${k_after}" "repeat read"
    if [ "${k_hash}" != "${first_hash}" ] || [ "${k_bytes}" != "${first_bytes}" ]; then
        finish unreadable "${EX_UNREADABLE}" "the kernel's hash for pid ${pid} changed between two reads: the process exec'd another image, so the first read does not describe it"
    fi
    report "checked:" "CS_VALID set, CS_DEBUGGED and CS_INVALID_ALLOWED clear, the hash read twice and equal"
    if [ "${first_bytes}" -eq 20 ]; then
        report "compared:" "the first 40 hex digits only: this macOS gives the kernel's 20-byte hash and no more"
        if [ "${first_hash}" = "${expected:0:40}" ]; then
            conclude_match truncated-match
        fi
    else
        if [ "${first_hash}" = "${expected}" ]; then
            conclude_match verified
        fi
    fi
    finish mismatch "${EX_MISMATCH}" "the running helper is not the recorded build"
fi

# --- Fallback: the file, checked against the process --------------------------------------

# Prints the sha256 CDHash that codesign reads from the file behind a pid, or returns 1. The
# raw output carries the signer and is never printed.
file_hash() {
    local output hash
    output=$("${CODESIGN}" -d --verbose=4 "${pid}" 2>&1) || return 1
    hash=$(printf '%s\n' "${output}" | sed -n 's/^CandidateCDHashFull sha256=//p') || return 1
    [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${hash}"
}

report "read from:" "FALLBACK: the file on disk, not the kernel (the csops route is unavailable here)"
report "evidence:" "WEAKER. The kernel's hash is not read and no debugger check is made; a match is never 'verified'."

# A read through codesign failed. If the process has gone, say so (11); otherwise the
# signature could not be read (13).
fallback_failed() {
    local gone_status=0
    instance_of "${pid}" || gone_status=$?
    if [ "${gone_status}" -eq 1 ]; then
        finish not-running "${EX_NONE}" "pid ${pid} (${process_label}) went away while it was being read"
    fi
    finish unreadable "${EX_UNREADABLE}" "$1"
}

hash_before=$(file_hash) || fallback_failed "codesign could not read the signature of pid ${pid}"
validity_status=0
validity=$("${CODESIGN}" -v "${pid}" 2>&1) || validity_status=$?
hash_after=$(file_hash) || fallback_failed "codesign could not read the signature of pid ${pid} after validating it"
if [ "${validity_status}" -ne 0 ]; then
    case "${validity}" in
        *"does not match what is running"*)
            finish unreadable "${EX_UNREADABLE}" "the file at the process's path is not what is running, so what is running is unknown without csops"
            ;;
        *)
            finish unreadable "${EX_UNREADABLE}" "codesign could not validate pid ${pid} against its file"
            ;;
    esac
fi
if [ "${hash_before}" != "${hash_after}" ]; then
    finish unreadable "${EX_UNREADABLE}" "the file behind pid ${pid} changed while it was being read"
fi
report "codesign -v:" "the code on disk matched what was running"
report "running:" "${hash_after} (the file's)"
report "expected:" "${expected}"
confirm_same_instance
if [ "${hash_after}" = "${expected}" ]; then
    finish file-only "${EX_FILE_ONLY}" "the file matches the record and the process agreed with it, but the running image is not proven; this is not a verification"
fi
finish mismatch "${EX_MISMATCH}" "the file behind the running helper is not the recorded build, and the process agreed with that file"
