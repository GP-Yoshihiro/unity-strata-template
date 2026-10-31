#!/usr/bin/env bash
# Batch-mode Unity runner (bash counterpart of tools/unity.ps1).
# Usage: tools/unity.sh path | test [EditMode|PlayMode|All] | refresh | exec <Method> [args...] | open
# Exit codes: 0 ok, 2 tests failed, other = Unity/setup error. Logs go to Logs/.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$REPO_ROOT/Logs"
mkdir -p "$LOG_DIR"

UNITY="$("$REPO_ROOT/tools/find-unity.sh")" || exit 1
CMD="${1:-test}"; shift || true

[ -f "$REPO_ROOT/Temp/UnityLockfile" ] && echo "warning: Temp/UnityLockfile exists; the project may already be open in an Editor." >&2

PROJECT="$REPO_ROOT"
command -v cygpath >/dev/null 2>&1 && PROJECT="$(cygpath -w "$REPO_ROOT")"
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }

run_unity() {
  echo "> $UNITY -projectPath $PROJECT $*"
  "$UNITY" -projectPath "$PROJECT" "$@"
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
    run_unity >/dev/null 2>&1 & ;;
  *) echo "unknown command: $CMD" >&2; exit 1 ;;
esac
