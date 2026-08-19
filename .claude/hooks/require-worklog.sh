#!/usr/bin/env bash
# PreToolUse guard for Bash, project scope (Propeller only).
# Blocks `git commit` when the commit changes something but carries no WORKLOG.md
# entry. Exit 2 blocks the tool call and returns stderr to Claude as the reason.
#
# Why a guard and not a reminder: the CLAUDE.md rule "document the work" is
# already written down, and it was still missed four commits in a row (see the
# 2026-08-19 WORKLOG entry). A commit is the one moment where the check is both
# cheap and unambiguous.
#
# Fails open by design: anything unexpected (no jq, not a repo, git error) exits 0.
# A broken guard must not wedge every Bash call.
set -uo pipefail

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
[[ -z "$cmd" ]] && exit 0

# `git commit`, including inside a chain like `git add -A && git commit -m x`.
# Only git's own pre-command flags may sit between the two words; listing them
# explicitly keeps `git log --grep commit` from reading as a commit.
gflag='(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--git-dir[=[:space:]][^[:space:]]+|--work-tree[=[:space:]][^[:space:]]+|--no-pager|--paginate|-P)'
is_commit="(^|[;&|(\`[:space:]])git([[:space:]]+${gflag})*[[:space:]]+commit([[:space:]]|$)"
[[ "$cmd" =~ $is_commit ]] || exit 0

# --amend reworks a commit whose entry was already judged; --dry-run writes nothing.
[[ "$cmd" =~ (^|[[:space:]])--amend([[:space:]]|$) ]] && exit 0
[[ "$cmd" =~ (^|[[:space:]])--dry-run([[:space:]]|$) ]] && exit 0

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
[[ -n "$cwd" && -d "$cwd" ]] && cd "$cwd" 2>/dev/null
# `git -C dir commit` commits in dir, so that is the repo to inspect.
if [[ "$cmd" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
  target="${BASH_REMATCH[1]//\"/}"
  [[ -d "$target" ]] && cd "$target" 2>/dev/null
fi
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -z "$root" ]] && exit 0

log_file="WORKLOG.md"

changed="$(git diff --cached --name-only 2>/dev/null)" || exit 0
# `commit -a` / `-am` sweeps up tracked changes that were never staged.
if [[ "$cmd" =~ (^|[[:space:]])(--all([[:space:]]|=|$)|-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)) ]]; then
  changed="$changed
$(git diff --name-only 2>/dev/null)"
fi
changed="$(printf '%s\n' "$changed" | grep -v '^[[:space:]]*$' | sort -u)"

# Nothing to commit: git will say so itself, no need to pile on.
[[ -z "$changed" ]] && exit 0

# The entry is in this commit.
printf '%s\n' "$changed" | grep -qx "$log_file" && exit 0

# Today's entry is already committed. CLAUDE.md asks for commit-sized steps but
# one entry per piece of work, so later steps the same day must not be blocked.
# Keyed on the entry date, not on "the previous commit touched the file" — that
# would hand a free pass to the first commit of the next piece of work.
today="$(date +%F)"
if git show "HEAD:$log_file" 2>/dev/null | grep -q "^##[[:space:]]*${today}"; then
  exit 0
fi

echo "Blocked: this commit changes files but adds no $log_file entry, and no \
entry dated $today is committed yet. CLAUDE.md requires one entry per piece of work: \
what changed and which files, why, how it was verified (exact command and real \
output, or \"not verified\"), what is left undone. Append it at the top of \
$root/$log_file, stage that file, and commit again. If what is left undone is \
someone's future work rather than a property of what shipped, add a line to \
$root/TAILS.md as well — that is the list that gets re-read. If this commit genuinely \
documents nothing new — a pure revert, or a fixup you would normally --amend — \
say so and ask me, do not work around the guard." >&2
exit 2
