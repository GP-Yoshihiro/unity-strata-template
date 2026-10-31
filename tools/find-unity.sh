#!/usr/bin/env bash
# Resolve the Unity Editor executable for this project (macOS / Linux / Git Bash on Windows).
# Same resolution order as tools/find-unity.ps1:
#   $1 arg > $UNITY_EDITOR_PATH > .unity-path.local > installed editor matching ProjectVersion.txt
#   > same major.minor / newest (warning, unless STRICT=1) > Unity on PATH
# Usage: tools/find-unity.sh [path]      tools/find-unity.sh --list
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$(uname -s)" in
  Darwin) OS=mac ;;
  MINGW*|MSYS*|CYGWIN*) OS=win ;;
  *) OS=linux ;;
esac

exe_rel_paths() {
  case "$OS" in
    win) echo "Editor/Unity.exe"; echo "Unity.exe" ;;
    mac) echo "Unity.app/Contents/MacOS/Unity"; echo "Contents/MacOS/Unity" ;;
    *) echo "Editor/Unity"; echo "Unity" ;;
  esac
}

to_unix() { if [ "$OS" = win ] && command -v cygpath >/dev/null; then cygpath -u "$1"; else echo "$1"; fi; }

resolve_candidate() {
  local p="$1"
  [ -z "$p" ] && return 1
  p="${p%\"}"; p="${p#\"}"; p="${p/#\~/$HOME}"; p="$(to_unix "$p")"
  case "$p" in /*) ;; *) p="$REPO_ROOT/$p" ;; esac
  if [ -d "$p" ]; then
    local rel
    while read -r rel; do [ -f "$p/$rel" ] && { echo "$p/$rel"; return 0; }; done < <(exe_rel_paths)
    return 1
  fi
  [ -f "$p" ] && { echo "$p"; return 0; }
  return 1
}

hub_config_dir() {
  case "$OS" in
    win) to_unix "$APPDATA/UnityHub" ;;
    mac) echo "$HOME/Library/Application Support/UnityHub" ;;
    *) echo "$HOME/.config/UnityHub" ;;
  esac
}

editor_roots() {
  local sep=":"; [ "$OS" = win ] && sep=";"
  if [ -n "${UNITY_EDITORS_DIR:-}" ]; then
    local IFS="$sep"; for r in $UNITY_EDITORS_DIR; do to_unix "$r"; done
  fi
  echo "$(dirname "$REPO_ROOT")/UnityEditors"
  echo "$REPO_ROOT/.unity-editors"
  case "$OS" in
    win) to_unix "${PROGRAMFILES:-C:/Program Files}/Unity/Hub/Editor" ;;
    mac) echo "/Applications/Unity/Hub/Editor" ;;
    *) echo "$HOME/Unity/Hub/Editor" ;;
  esac
  local sec; sec="$(hub_config_dir)/secondaryInstallPath.json"
  if [ -f "$sec" ]; then
    local v; v="$(sed -e 's/^"//' -e 's/"$//' -e 's/\\\\/\//g' "$sec" | tr -d '\r\n')"
    [ -n "$v" ] && to_unix "$v"
  fi
}

# Prints "<sortkey> <version> <path>" for every installed editor
installed_editors() {
  local root dir rel ver
  while read -r root; do
    [ -d "$root" ] || continue
    for dir in "$root"/*/; do
      [ -d "$dir" ] || continue
      ver="$(basename "$dir")"
      while read -r rel; do
        if [ -f "$dir$rel" ]; then
          printf '%s %s %s\n' "$(version_key "$ver")" "$ver" "$dir$rel"; break
        fi
      done < <(exe_rel_paths)
    done
  done < <(editor_roots | awk '!seen[$0]++')
}

version_key() {
  # 6000.2.11f1 -> 006000.0002.0011f0001
  echo "$1" | awk -F'[.]' '{
    match($3, /^[0-9]+/); patch=substr($3, 1, RLENGTH); rest=substr($3, RLENGTH+1);
    match(rest, /^[a-z]+/); typ=substr(rest, 1, RLENGTH); bld=substr(rest, RLENGTH+1); if (bld=="") bld=0;
    printf "%06d.%04d.%04d%s%04d", $1, $2, patch, typ, bld }'
}

project_version() {
  local f="$REPO_ROOT/ProjectSettings/ProjectVersion.txt"
  [ -f "$f" ] && sed -n 's/^m_EditorVersion:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f" | tr -d '\r' | head -n1
}

WANT="$(project_version || true)"

if [ "${1:-}" = "--list" ]; then
  echo "Project version: $WANT"
  installed_editors | sort -r | awk '{ $1=""; print substr($0,2) }'
  exit 0
fi

# 1-3: explicit locations
LOCAL_FILE="$REPO_ROOT/.unity-path.local"
LOCAL_VAL=""
[ -f "$LOCAL_FILE" ] && LOCAL_VAL="$(grep -v '^#' "$LOCAL_FILE" | grep -v '^[[:space:]]*$' | head -n1 | tr -d '\r' || true)"
for src in "arg:${1:-}" "UNITY_EDITOR_PATH:${UNITY_EDITOR_PATH:-}" ".unity-path.local:$LOCAL_VAL"; do
  name="${src%%:*}"; val="${src#*:}"
  [ -z "$val" ] && continue
  if resolve_candidate "$val"; then exit 0; fi
  echo "warning: $name is set but no Unity executable was found at '$val'" >&2
done

# 4-5: installed editors (newest first)
EDITORS="$(installed_editors | sort -r)"
if [ -n "$WANT" ]; then
  hit="$(echo "$EDITORS" | awk -v w="$WANT" '$2==w { $1=""; $2=""; sub(/^  /, ""); print; exit }')"
  [ -n "$hit" ] && { echo "$hit"; exit 0; }
fi
if [ "${STRICT:-0}" != "1" ] && [ -n "$EDITORS" ]; then
  mm="$(echo "$WANT" | cut -d. -f1-2)"
  pick="$(echo "$EDITORS" | awk -v mm="$mm." 'mm!="." && index($2, mm)==1 { print; exit }')"
  [ -z "$pick" ] && pick="$(echo "$EDITORS" | head -n1)"
  echo "warning: Unity $WANT not installed; falling back to $(echo "$pick" | awk '{print $2}'). Install $WANT via Unity Hub to avoid an upgrade." >&2
  echo "$pick" | awk '{ $1=""; $2=""; sub(/^  /, ""); print }'
  exit 0
fi

# 6: PATH
for n in Unity Unity.exe; do command -v "$n" >/dev/null 2>&1 && { command -v "$n"; exit 0; }; done

echo "error: Unity Editor $WANT not found. Install it with Unity Hub, or set UNITY_EDITOR_PATH / create .unity-path.local (see README)." >&2
exit 1
