#!/usr/bin/env bash
# Per-machine setup after cloning or downloading as ZIP (macOS / Linux / Git Bash). Safe to re-run.
# See tools/setup.ps1. Usage: tools/setup.sh [--branch <name>] [--remote <url>]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BRANCH=""; REMOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "== git"
git --version
git lfs version || { echo "git-lfs is not installed: https://git-lfs.com" >&2; exit 1; }
USER_NAME="$(git config user.name || true)"
[ -n "$USER_NAME" ] || { echo "git user.name is not set -- task claims and history need it: git config --global user.name \"<name>\"" >&2; exit 1; }

# A "Download ZIP" copy has no .git: turn it into a repository and work on a new branch
if [ ! -e "$REPO_ROOT/.git" ]; then   # .git is a folder in clones and a file in worktrees
  echo "No git repository here (ZIP download): initialising one"
  git init -q -b main
  git add -A
  git commit -q -m "Import unity-strata-template (ZIP download)"
  [ -n "$BRANCH" ] || BRANCH="local/$(printf '%s' "$USER_NAME" | tr -cd 'A-Za-z0-9_-' | tr 'A-Z' 'a-z')"
  [ -z "$REMOTE" ] || { git remote add origin "$REMOTE"; echo "origin -> $REMOTE"; }
fi
if [ -n "$BRANCH" ]; then
  git switch -q "$BRANCH" 2>/dev/null || git switch -q -c "$BRANCH"
  echo "Working branch: $BRANCH"
fi

git lfs install --local >/dev/null
[ -z "$(git remote)" ] || git lfs pull
# Shared team hooks (meta check, attribution trailers, no direct push to main); they chain to LFS.
git config --local core.hooksPath .githooks
git config --local lfs.locksverify true
echo "Team hooks enabled (.githooks)"

echo "== private run history"
HIST_REPO="$(sed -n 's/.*"historyRepo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' team.config.json 2>/dev/null | head -n1)"
HIST_DIR="$REPO_ROOT/$(sed -n 's/.*"historyDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' team.config.json 2>/dev/null | head -n1)"
[ "$HIST_DIR" != "$REPO_ROOT/" ] || HIST_DIR="$REPO_ROOT/.history"
if [ -n "$HIST_REPO" ] && [ ! -d "$HIST_DIR/.git" ] && [ ! -d "$HIST_DIR/runs" ]; then
  git clone -q "$HIST_REPO" "$HIST_DIR" 2>/dev/null || echo "warning: history repo $HIST_REPO not reachable; run records stay local" >&2
fi
mkdir -p "$HIST_DIR/runs"
chmod 700 "$HIST_DIR"
command -v attrib >/dev/null 2>&1 && attrib +h "$(cygpath -w "$HIST_DIR" 2>/dev/null || echo "$HIST_DIR")" >/dev/null 2>&1 || true
echo "History folder: $HIST_DIR (hidden, ignored by git)"

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

PS_EXE=""
if command -v pwsh >/dev/null 2>&1; then PS_EXE="pwsh"
elif command -v powershell >/dev/null 2>&1; then PS_EXE="powershell"; fi

echo "== context index"
if [ -n "$PS_EXE" ]; then "$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File tools/strata-index.ps1
else echo "warning: PowerShell (pwsh) not found; install it to rebuild the context index" >&2; fi

echo "== strata (local model server)"
if [ -n "$PS_EXE" ] && "$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File tools/strata.ps1 version; then
  echo "Next: pwsh tools/strata.ps1 plan, then pwsh tools/strata.ps1 up"
else
  echo "warning: Strata Terminal not installed (optional, for local-model runs). Install:" >&2
  echo "  curl -fsSL https://github.com/Niko1221/Strata/releases/latest/download/install.sh -o install.sh && sh install.sh" >&2
fi

echo
echo "Setup complete. Try: tools/unity.sh test EditMode"
