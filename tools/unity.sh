#!/usr/bin/env bash
# Batch-mode Unity runner (bash counterpart of tools/unity.ps1).
# Usage: tools/unity.sh path | test [EditMode|PlayMode|All] | refresh | exec <Method> [args...] | open
#        tools/unity.sh install [version] [hub args...]   (Unity Hub CLI; default = ProjectVersion.txt)
#        tools/unity.sh upgrade <version>                 (install + open once so Unity upgrades the project)
#        tools/unity.sh packages add <id>[,<id>...]        (Unity picks the versions for this editor)
# Exit codes: 0 ok, 2 tests failed, 124 timed out, other = Unity/setup error. Logs go to Logs/.
# UNITY_TIMEOUT_MINUTES (default 60, 0 = no limit; needs `timeout`/`gtimeout`) stops a hung batch run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$REPO_ROOT/Logs"
mkdir -p "$LOG_DIR"
FIND_UNITY=(bash "$REPO_ROOT/tools/find-unity.sh")
CMD="${1:-test}"; shift || true
TIMEOUT_MIN="${UNITY_TIMEOUT_MINUTES:-60}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

pv_file="$REPO_ROOT/ProjectSettings/ProjectVersion.txt"
project_version() { sed -n 's/^m_EditorVersion:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$pv_file" | tr -d '\r' | head -n1; }
project_changeset() { sed -n 's/^m_EditorVersionWithRevision:.*(\([0-9a-f]*\)).*/\1/p' "$pv_file" | tr -d '\r' | head -n1; }

# Unity Hub CLI: https://docs.unity3d.com/hub/manual/HubCLI.html  (Windows/macOS need the extra "--")
install_editor() {
  local ver="$1" cs="$2"; shift 2
  if existing="$(UNITY_VERSION="$ver" STRICT=1 "${FIND_UNITY[@]}" 2>/dev/null)"; then echo "Unity $ver is already installed: $existing"; return 0; fi
  local hub; hub="$("${FIND_UNITY[@]}" --hub)" || return 1
  local args=()
  case "$(uname -s)" in Darwin|MINGW*|MSYS*|CYGWIN*) args+=(--) ;; esac
  args+=(--headless install --version "$ver")
  [ -n "$cs" ] && args+=(--changeset "$cs")
  args+=("$@")
  echo "> $hub ${args[*]}"
  echo "Downloading and installing the editor (several GB; this can take a while)..."
  "$hub" "${args[@]}"; local code=$?
  if ! path="$(UNITY_VERSION="$ver" STRICT=1 "${FIND_UNITY[@]}" 2>/dev/null)"; then
    echo "error: Unity Hub exit code $code, and Unity $ver is still not found. Install it from the Hub GUI or https://unity.com/releases/editor/archive" >&2
    return 1
  fi
  echo "Installed: $path"
  echo "Batch mode needs an activated licence on this machine: sign in to Unity Hub once (Personal) or activate a serial."
}

case "$CMD" in
  install)
    ver="$(project_version)"; cs="$(project_changeset)"
    if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then [ "$1" = "$ver" ] || cs=""; ver="$1"; shift; fi
    install_editor "$ver" "$cs" "$@"; exit $? ;;
  upgrade)
    [ $# -ge 1 ] || { echo "usage: unity.sh upgrade <version>  (run it on a claimed task branch whose paths include ProjectSettings/ and Packages/)" >&2; exit 1; }
    ver="$1"; shift; from="$(project_version)"
    install_editor "$ver" "" "$@" || exit 1
    UNITY="$(UNITY_VERSION="$ver" STRICT=1 "${FIND_UNITY[@]}")" || exit 1
    PROJECT="$REPO_ROOT"; command -v cygpath >/dev/null 2>&1 && PROJECT="$(cygpath -w "$REPO_ROOT")"
    echo "Opening the project once with $ver (was $from) so Unity upgrades ProjectSettings/ and Packages/ ..."
    if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT_MIN" -gt 0 ]; then
      "$TIMEOUT_BIN" --kill-after=60 "${TIMEOUT_MIN}m" "$UNITY" -projectPath "$PROJECT" -batchmode -nographics -quit -logFile "$LOG_DIR/UnityUpgrade.log"
    else
      "$UNITY" -projectPath "$PROJECT" -batchmode -nographics -quit -logFile "$LOG_DIR/UnityUpgrade.log"
    fi
    code=$?; now="$(project_version)"
    echo "Exit code $code; ProjectVersion.txt now says $now (log: Logs/UnityUpgrade.log)"
    [ "$code" -eq 0 ] && [ "$now" = "$ver" ] || exit 1
    echo "Next: tools/unity.sh test All, review 'git diff ProjectSettings Packages', commit and open a PR. Teammates run tools/unity.sh install after it merges."
    exit 0 ;;
esac

UNITY="$("${FIND_UNITY[@]}")" || exit 1

[ -f "$REPO_ROOT/Temp/UnityLockfile" ] && echo "warning: Temp/UnityLockfile exists; the project may already be open in an Editor." >&2

PROJECT="$REPO_ROOT"
command -v cygpath >/dev/null 2>&1 && PROJECT="$(cygpath -w "$REPO_ROOT")"
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

run_unity() {
  echo "> $UNITY -projectPath $PROJECT $*"
  if [ -n "$TIMEOUT_BIN" ] && [ "$TIMEOUT_MIN" -gt 0 ]; then
    "$TIMEOUT_BIN" --kill-after=60 "${TIMEOUT_MIN}m" "$UNITY" -projectPath "$PROJECT" "$@"
  else
    "$UNITY" -projectPath "$PROJECT" "$@"
  fi
}

summary() {
  local xml="$1"
  [ -f "$xml" ] || { echo "warning: no result file $xml" >&2; return; }
  grep -o '<test-run [^>]*>' "$xml" | head -n1 | grep -oE '(result|total|passed|failed|skipped)="[^"]*"' | tr '\n' ' '; echo
  grep -oE '<test-case [^>]*result="Failed"[^>]*>' "$xml" | grep -oE 'fullname="[^"]*"' | sed 's/^/  FAILED /'
}

case "$CMD" in
  path) echo "$UNITY" ;;
  test)
    case "${1:-EditMode}" in All) PLATFORMS="EditMode PlayMode" ;; *) PLATFORMS="${1:-EditMode}" ;; esac
    worst=0
    for pl in $PLATFORMS; do
      lower="$(echo "$pl" | tr '[:upper:]' '[:lower:]')"
      xml="$LOG_DIR/$lower-results.xml"; rm -f "$xml"
      run_unity -batchmode -nographics -runTests -testPlatform "$pl" -testResults "$(winpath "$xml")" -logFile "$(winpath "$LOG_DIR/UnityTest-$pl.log")"
      code=$?
      # No result file means Unity never ran the tests (licence, compile or start-up problem): not a pass
      [ "$code" -eq 0 ] && [ ! -f "$xml" ] && code=1
      summary "$xml"
      echo "$pl exit code $code (log: Logs/UnityTest-$pl.log)"
      [ "$code" -gt "$worst" ] && worst=$code
    done
    exit "$worst" ;;
  refresh)
    run_unity -batchmode -nographics -quit -executeMethod Game.Editor.BatchEntry.Refresh -logFile "$(winpath "$LOG_DIR/UnityRefresh.log")" ;;
  exec)
    [ $# -ge 1 ] || { echo "usage: unity.sh exec <Namespace.Class.Method> [args...]" >&2; exit 1; }
    method="$1"; shift
    run_unity -batchmode -nographics -quit -executeMethod "$method" -logFile "$(winpath "$LOG_DIR/UnityExec.log")" "$@" ;;
  open)
    "$UNITY" -projectPath "$PROJECT" >/dev/null 2>&1 & ;;
  packages)
    [ "${1:-}" = add ] && [ $# -ge 2 ] || { echo "usage: unity.sh packages add <id>[,<id>...]" >&2; exit 1; }
    shift; ids="$(printf '%s' "$*" | tr ' ' ',' | tr -s ',')"
    # no -quit: the Package Manager request is asynchronous; BatchEntry.AddPackages exits when it completes
    run_unity -batchmode -nographics -executeMethod Game.Editor.BatchEntry.AddPackages -packages "$ids" -logFile "$(winpath "$LOG_DIR/UnityPackages.log")" ;;
  *) echo "unknown command: $CMD" >&2; exit 1 ;;
esac
