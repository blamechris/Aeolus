#!/bin/bash
# Prints the code-signing identifier the helper's client requirement allow-lists for fanctl.
#
# It is read out of the declaration the requirement is built from,
# `AeolusClientIdentifier.commandLine` in ClientRequirementText.swift, so a CI step that
# checks the built binary against it compares against what the helper actually pins rather
# than a second literal that could drift from it.
#
# Fails closed: if the declaration is not on exactly one line in the form
#
#     static let commandLine = "<identifier>"
#
# nothing is printed to stdout and the exit status is 1. A reformatted declaration
# (`static let commandLine: String = ...`) therefore breaks the CI steps that call this
# rather than quietly making them assert against nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="${root}/Sources/AeolusXPC/ClientAuthorisation/ClientRequirementText.swift"

identifier=$(sed -n 's/^    static let commandLine = "\(.*\)"$/\1/p' "${source_file}")

if [ -z "${identifier}" ] || [ "$(printf '%s\n' "${identifier}" | wc -l)" -ne 1 ]; then
    echo "error: could not read AeolusClientIdentifier.commandLine from ${source_file}" >&2
    exit 1
fi

printf '%s\n' "${identifier}"
