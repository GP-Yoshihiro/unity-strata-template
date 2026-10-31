#!/usr/bin/env bash
# Verify Unity .meta files in the git index (what would be committed):
#   - every tracked file and folder under Assets/ has a tracked .meta
#   - every tracked .meta belongs to a tracked file or folder
# Used by .githooks/pre-commit and CI. Exit 1 with a list of problems.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

files="$(git ls-files -- Assets | sort)"
[ -z "$files" ] && exit 0

metas="$(printf '%s\n' "$files" | grep '\.meta$' || true)"
assets="$(printf '%s\n' "$files" | grep -v '\.meta$' || true)"
# every folder that contains a tracked asset (Assets itself has no .meta)
dirs="$(printf '%s\n' "$assets" | awk -F/ '{ p=$1; for (i=2; i<NF; i++) { p=p"/"$i; print p } }' | sort -u)"

problems=0
expected="$(printf '%s\n%s\n' "$assets" "$dirs" | grep -v '^$' | sed 's/$/.meta/' | sort -u)"
missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$metas"))"
orphans="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$metas"))"

if [ -n "$missing" ]; then
  echo "Missing .meta (open Unity or run tools/unity.* refresh, then stage the generated .meta):"
  printf '  %s\n' $missing
  problems=1
fi
if [ -n "$orphans" ]; then
  echo "Orphan .meta (its asset was deleted/moved outside Unity; use Game.Editor.BatchEntry.MoveAsset/DeleteAsset):"
  printf '  %s\n' $orphans
  problems=1
fi
exit $problems
