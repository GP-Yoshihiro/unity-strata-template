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
ZIP_IMPORT=0
if [ ! -e "$REPO_ROOT/.git" ]; then   # .git is a folder in clones and a file in worktrees
  echo "No git repository here (ZIP download): initialising one"
  ZIP_IMPORT=1
  git init -q
  git symbolic-ref HEAD refs/heads/main   # same as `git init -b main`, but works on git < 2.28
  # LFS filters must be active BEFORE the first `git add`, or binaries are committed as plain blobs
  git lfs install --local --skip-repo >/dev/null   # filters only: .githooks already chain the LFS hooks
  git add -A
  git commit -q -m "Import unity-strata-template (ZIP download)"
  [ -n "$BRANCH" ] || BRANCH="local/$(printf '%s' "$USER_NAME" | tr -cd 'A-Za-z0-9_-' | tr 'A-Z' 'a-z')"
  [ -z "$REMOTE" ] || { git remote add origin "$REMOTE"; echo "origin -> $REMOTE"; }
fi
if [ -n "$BRANCH" ]; then
  git switch -q "$BRANCH" 2>/dev/null || git switch -q -c "$BRANCH"
  echo "Working branch: $BRANCH"
fi

git lfs install --local --skip-repo >/dev/null   # filters only: .githooks already chain the LFS hooks
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
# Run through bash: a ZIP extracted on some tools loses the executable bit
bash tools/find-unity.sh --list
YAML_MERGE=""
if UNITY="$(bash tools/find-unity.sh)"; then
  echo "Using: $UNITY"
  EDITOR_DIR="$(dirname "$UNITY")"
  for c in "$EDITOR_DIR/Data/Tools/UnityYAMLMerge.exe" "$EDITOR_DIR/Data/Tools/UnityYAMLMerge" "$EDITOR_DIR/../Resources/Tools/UnityYAMLMerge"; do
    [ -f "$c" ] && { YAML_MERGE="$c"; break; }
  done
else
  # Keep going: hooks, history, skills and the index do not need Unity. Install it, then re-run setup.
  echo "warning: Unity $(sed -n 's/^m_EditorVersion:[[:space:]]*//p' ProjectSettings/ProjectVersion.txt | tr -d '\r') is not installed. Install it with: tools/unity.sh install  (then re-run tools/setup.sh)" >&2
fi
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

echo "== new-project check"
ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
owner_of() { printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*\)/.*#\1#p'; }
if [ -n "$HIST_REPO" ] && [ -n "$ORIGIN" ] && [ "$(owner_of "$HIST_REPO")" != "$(owner_of "$ORIGIN")" ]; then
  echo "warning: team.config.json historyRepo ($HIST_REPO) belongs to a different owner than origin ($ORIGIN)." >&2
  echo "         For a new project: create your own PRIVATE history repo, then edit team.config.json and .github/CODEOWNERS." >&2
fi
if [ "$ZIP_IMPORT" = 1 ] && [ -n "$REMOTE" ]; then
  echo "First push of a new repository (the pre-push hook blocks main otherwise):"
  echo "  ALLOW_MAIN_PUSH=1 git push -u origin main && git push -u origin $BRANCH"
fi

echo
echo "Setup complete. Try: tools/unity.sh test EditMode"
