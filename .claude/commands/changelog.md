# /changelog

Generate release notes from what actually merged: collect the merged PRs and commits since the last release, group them into meaningful sections, and write them to the project's changelog (or a draft release body). Turns "what changed since the last version?" into a formatted, linked summary instead of a hand-scrolled git log.

Use this standalone to draft notes, or let `/release` invoke it as its notes step. For shipping the version itself, use `/release`.

## Arguments

- `$ARGUMENTS` — configuration. Space-separated tokens:
  - `--from=REF` — start of the range (default: the previous release tag, e.g. `git describe --tags --abbrev=0`).
  - `--to=REF` — end of the range (default: `HEAD`).
  - `--version=X` — the version label to head the new section with (default: `Unreleased`).
  - `--output=DEST` — where to write: the changelog file (default), `release` to draft a GitHub release body, or `-` for stdout only.

Examples:
```
/changelog                          # notes since the last tag, into the changelog file
/changelog --version=1.4.0
/changelog --from=v1.2.0 --to=v1.3.0 --output=-
/changelog --output=release         # draft a GitHub release body
```

## Instructions

### 1. Resolve the range

Determine `FROM..TO`:

```bash
# Previous release tag, or the repo's root commit on a first release (no tags yet).
FROM=${from:-$(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD | tail -1)}
TO=${to:-HEAD}
```

When `FROM` falls back to the root commit (first release, no prior tag), say so in the output. State the resolved range before collecting.

### 2. Collect what changed in the range

Prefer **merged PRs** (richer titles, labels, author, and a link) and fall back to commit subjects where a change landed without a PR.

```bash
# Merged PRs whose merge commit is in range (gh + git):
git log --merges --first-parent ${FROM}..${TO} --pretty='%s'   # "Merge pull request #N ..."
# Or, for squash-merge repos, PRs by merge date:
gh pr list --state merged --base <release branch> --json number,title,labels,mergedAt,url \
  --search "merged:>=$(git log -1 --format=%cs ${FROM})"
# Direct commits not from a PR:
git log ${FROM}..${TO} --no-merges --pretty='%s (%h)'
```

Aeolus squash-merges pull requests into `main`, so one merged PR is one changelog-worthy unit. Enumerate what shipped with `gh pr list --state merged --base main --json number,title,labels,mergedAt` filtered by date, rather than walking raw commits.

Every release is tagged, so the previous-tag default is reliable.

### 3. Categorize into sections

Group entries into the changelog's sections. Derive the category from each change's conventional-commit type or PR label.

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/): **Added / Changed / Deprecated / Removed / Fixed / Security**. Aeolus does not use conventional-commit prefixes, so derive the section from the PR's labels and its title:

- `enhancement` → Added, or Changed when it alters existing behaviour
- `bug` → Fixed
- `safety-critical` → Fixed or Security, and **always** called out explicitly however small
- `area:catalog` → Added, phrased in terms of the Macs it newly labels

Two things get their own note regardless of size: a change to the **XPC protocol version** (a stale `fanctl` against a newer helper must fail loudly, and users need to know when that boundary moved), and any change to a **hardware support claim** in `docs/HARDWARE-MATRIX.md`.

- Omit purely internal noise (merge commits themselves, version-bump commits, `chore` that ships nothing user-facing) unless the project's convention says otherwise.
- Each entry: a one-line description in past tense, the PR/issue link (`(#123)`), and scope where it sharpens meaning.
- Note **breaking changes** prominently (a `!` in the type or a `BREAKING CHANGE:` footer) — call them out at the top of the section.

### 4. Render the new section

```markdown
## [<version>] - <date>

### Added
- Short description (#123)

### Fixed
- Short description (#130)
```

Use `--version` for the heading (default `Unreleased`). Use today's date (`YYYY-MM-DD`) — take it from the environment, do not invent one.

### 5. Write to the destination

- **Changelog file (default):** prepend the new section directly under the top header / `Unreleased` marker, preserving the rest of the file. Create the file with a standard header if it does not exist.
- **`--output=release`:** emit the section as a GitHub release body (e.g. for `gh release create`/`gh release edit`) rather than editing a file.
- **`--output=-`:** print to stdout only; write nothing.

`CHANGELOG.md` at the repository root, in Keep a Changelog format with an `## [Unreleased]` section at the top and SemVer version headings below it. Write there by default.

### 6. Report

State the resolved range, the version/section written, the destination, and counts per category. If invoked by `/release`, return the rendered section so the release step can use it.

## Notes

- **Don't invent history.** Every entry must trace to a real merged PR or commit in range. If a change has no PR and an unclear commit subject, list it under its best-guess category and flag it rather than fabricating a description.
- **Idempotent on the file.** Re-running for the same version should replace that version's section, not append a duplicate.
- **No attribution.** No AI/agent mentions in the changelog, commits, or release body — the entries describe the work, not who wrote them.

<!-- skill-templates: changelog 3254376 2026-07-25 -->
