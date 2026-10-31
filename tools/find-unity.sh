#!/usr/bin/env bash
# Resolve the Unity Editor executable for this project (macOS / Linux / Git Bash on Windows).
# Same resolution order as tools/find-unity.ps1:
#   $1 arg > $UNITY_EDITOR_PATH > .unity-path.local > installed editor matching ProjectVersion.txt
#   > newer patch of the same major.minor (warning, unless STRICT=1) > Unity on PATH
# Older editors and other major/minor versions are never picked silently (that would up/downgrade the
# project for the whole team): use tools/unity.sh install / upgrade <version>.
# UNITY_VERSION=<v> looks for that version instead of ProjectVersion.txt (used by unity.sh upgrade).
# Usage: tools/find-unity.sh [path]      tools/find-unity.sh --list      tools/find-unity.sh --hub
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
  [ -n "${UNITY_VERSION:-}" ] && { echo "$UNITY_VERSION"; return; }
  local f="$REPO_ROOT/ProjectSettings/ProjectVersion.txt"
  [ -f "$f" ] && sed -n 's/^m_EditorVersion:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f" | tr -d '\r' | head -n1
}

find_hub() {
  [ -n "${UNITY_HUB_PATH:-}" ] && [ -f "$UNITY_HUB_PATH" ] && { echo "$UNITY_HUB_PATH"; return 0; }
  local c
  case "$OS" in
    win) for c in "$(to_unix "${PROGRAMFILES:-C:/Program Files}/Unity Hub/Unity Hub.exe")" "$(to_unix "${LOCALAPPDATA:-}/Programs/Unity Hub/Unity Hub.exe")"; do [ -f "$c" ] && { echo "$c"; return 0; }; done ;;
    mac) for c in "/Applications/Unity Hub.app/Contents/MacOS/Unity Hub" "$HOME/Applications/Unity Hub.app/Contents/MacOS/Unity Hub"; do [ -f "$c" ] && { echo "$c"; return 0; }; done ;;
    *) for c in /usr/bin/unityhub /opt/unityhub/unityhub "$HOME/Applications/Unity Hub.AppImage" "$HOME/Applications/UnityHub.AppImage"; do [ -f "$c" ] && { echo "$c"; return 0; }; done ;;
  esac
  command -v unityhub 2>/dev/null && return 0
  echo "error: Unity Hub not found. Install it from https://unity.com/download (or set UNITY_HUB_PATH)." >&2
  return 1
}

if [ "${1:-}" = "--hub" ]; then find_hub; exit $?; fi

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
  [ -n "${UNITY_VERSION:-}" ] && [ "$name" != arg ] && continue   # an explicit version beats the usual editor
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
  if [ -n "$WANT" ]; then
    # only a newer patch of the same major.minor; the list is newest first, so the last hit is the closest
    mm="$(echo "$WANT" | cut -d. -f1-2)"
    pick="$(echo "$EDITORS" | awk -v mm="$mm." -v wk="$(version_key "$WANT")" 'index($2, mm)==1 && $1 > wk { p=$0 } END { if (p) print p }')"
  else
    pick="$(echo "$EDITORS" | head -n1)"
  fi
  if [ -n "$pick" ]; then
    echo "warning: Unity $WANT not installed; using $(echo "$pick" | awk '{print $2}') (same major.minor). Install $WANT (tools/unity.sh install) to stay on the team's version." >&2
    echo "$pick" | awk '{ $1=""; $2=""; sub(/^  /, ""); print }'
    exit 0
  fi
  echo "error: Unity $WANT is not installed (found: $(echo "$EDITORS" | awk '{print $2}' | tr '\n' ' ')). Install it: tools/unity.sh install  -- or move the project on purpose: tools/unity.sh upgrade <version>" >&2
  exit 1
fi

# 6: PATH (not for an explicit UNITY_VERSION: the editor on PATH may be any version)
if [ -z "${UNITY_VERSION:-}" ]; then
  for n in Unity Unity.exe; do command -v "$n" >/dev/null 2>&1 && { command -v "$n"; exit 0; }; done
fi

echo "error: Unity Editor $WANT not found. Install it with Unity Hub, or set UNITY_EDITOR_PATH / create .unity-path.local (see README)." >&2
exit 1
