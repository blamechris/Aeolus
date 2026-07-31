#!/bin/sh
# Regenerates the shell completion scripts committed under Resources/completions/.
#
# swift-argument-parser derives these from fanctl's own command tree
# (--generate-completion-script), so they only need regenerating when a subcommand,
# option, or flag actually changes — not on every build, which is why they are
# committed rather than generated at build or install time. Run this after any change
# to Sources/fanctl/*.swift that adds, removes, or renames a subcommand, option, or
# flag, and commit the result alongside that change.
#
# Usage: scripts/generate-completions.sh

set -eu

cd "$(dirname "$0")/.."

swift build --product fanctl >/dev/null

for shell in bash zsh fish; do
    out="Resources/completions/fanctl.${shell}"
    .build/debug/fanctl --generate-completion-script "${shell}" > "${out}"
    echo "wrote ${out}"
done
