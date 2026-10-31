#!/usr/bin/env bash
# Per-machine setup after cloning (macOS / Linux / Git Bash). Safe to re-run. See tools/setup.ps1.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "== git"
git --version
git lfs version || { echo "git-lfs is not installed: https://git-lfs.com" >&2; exit 1; }
git lfs install --local >/dev/null
git lfs pull

echo "== Unity"
tools/find-unity.sh --list
UNITY="$(tools/find-unity.sh)"
echo "Using: $UNITY"
EDITOR_DIR="$(dirname "$UNITY")"
YAML_MERGE=""
for c in "$EDITOR_DIR/Data/Tools/UnityYAMLMerge.exe" "$EDITOR_DIR/Data/Tools/UnityYAMLMerge" "$EDITOR_DIR/../Resources/Tools/UnityYAMLMerge"; do
  [ -f "$c" ] && { YAML_MERGE="$c"; break; }
done
if [ -n "$YAML_MERGE" ]; then
  command -v cygpath >/dev/null 2>&1 && YAML_MERGE="$(cygpath -m "$YAML_MERGE")"
  git config --local merge.unityyamlmerge.name "Unity SmartMerge"
  git config --local merge.unityyamlmerge.driver "'$YAML_MERGE' merge -p %O %B %A %A"
  git config --local merge.unityyamlmerge.recursive binary
  echo "UnityYAMLMerge registered: $YAML_MERGE"
else
  echo "warning: UnityYAMLMerge not found" >&2
fi

echo "== agent skills"
mkdir -p .claude/skills
cp -R .agents/skills/. .claude/skills/
echo "Synced .agents/skills -> .claude/skills"

echo "== strata"
if command -v pwsh >/dev/null 2>&1; then pwsh -NoProfile -File tools/strata-index.ps1
elif command -v powershell >/dev/null 2>&1; then powershell -NoProfile -ExecutionPolicy Bypass -File tools/strata-index.ps1
else echo "warning: PowerShell (pwsh) not found; install it to rebuild the Strata index" >&2; fi

echo
echo "Setup complete. Try: tools/unity.sh test EditMode"
