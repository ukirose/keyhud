#!/bin/bash
# The build/test/run loop, as one command.
#
# Chaining these by hand went wrong three times in one session: a pipe into `head` sent
# SIGPIPE to the build and left a stale binary behind, a render was taken from a process
# older than the build that was supposed to have produced it, and a preview was captured
# against the wrong app. Every one of those cost a wrong conclusion, not just time. The
# freshness check below is the point of this script.
set -uo pipefail
cd "$(dirname "$0")"

APP_BIN="KeyHUD.app/Contents/MacOS/KeyHUD"
PROC='KeyHUD.app/Contents/MacOS/KeyHUD'

die() { echo "✗ $*" >&2; exit 1; }

build() {
  echo "▸ building"
  ./build.sh > /tmp/keyhud-build.log 2>&1 \
    || { tail -20 /tmp/keyhud-build.log; die "build failed"; }
  grep -E '^built' /tmp/keyhud-build.log || die "build produced no app"
}

test_all() {
  echo "▸ testing"
  # The tests must not read or write the real store. `DataDir.url` falls back to
  # ~/Developer/keyhud/data, and five suites call KeyboardLayout.load() — which *writes* a
  # default layout when the file is missing. On any machine but this one that meant tests
  # scribbling into a home directory and then failing because the fallback board has no Fn
  # layer. A throwaway directory, seeded with the real layout, gives them the same inputs
  # and none of the reach.
  local sandbox; sandbox=$(mktemp -d)
  cp "$DATA/keyboard.json" "$sandbox/" 2>/dev/null
  KEYHUD_DATA_DIR="$sandbox" swift test 2>&1 | tee /tmp/keyhud-test.log | grep -E "error:" || true
  rm -rf "$sandbox"
  local line
  line=$(grep -E "Executed [0-9]+ tests" /tmp/keyhud-test.log | tail -1)
  echo "  $line"
  grep -q "with 0 failures" <<<"$line" || die "tests failed — see /tmp/keyhud-test.log"
}

restart() {
  echo "▸ restarting"
  # The binary has to be newer than the source, not merely newer than nothing.
  #
  # The check below proves the *process* came from the binary and says not one word about
  # where the binary came from — so `restart` on its own happily launched an app built
  # before the edit under test, printed a line confirming everything was in order, and a
  # fix verified against it measured the old code. It reported "binary 01:31:45" for a
  # change made at 02:14, which is the whole story, in the output, unremarked.
  local newest
  newest=$(find Sources -name '*.swift' -newer "$APP_BIN" 2>/dev/null | head -3)
  [ -z "$newest" ] || die "$APP_BIN is older than$(printf ' %s' $newest) — run ./dev.sh build"
  # Quit, do not kill. The learning store's save is debounced two seconds and a
  # SIGTERM never reaches applicationWillTerminate, so `pkill` dropped whatever was
  # pending — on every restart, of which this session alone has had dozens.
  osascript -e 'tell application "KeyHUD" to quit' 2>/dev/null
  for _ in $(seq 1 20); do pgrep -f "$PROC" >/dev/null || break; sleep 0.2; done
  pgrep -f "$PROC" >/dev/null && { echo "  (did not quit; killing)"; pkill -f "$PROC"; sleep 1; }
  open ./KeyHUD.app || die "could not launch"
  sleep 2
  local pid; pid=$(pgrep -f "$PROC" | head -1)
  [ -n "$pid" ] || die "app is not running"
  # The whole reason this script exists: prove the process on screen came from the
  # binary just built, rather than assuming it.
  local built started
  built=$(stat -f %m "$APP_BIN")
  started=$(ps -o lstart= -p "$pid" | xargs -I{} date -j -f "%a %b %d %T %Y" "{}" +%s 2>/dev/null)
  [ -n "$started" ] && [ "$started" -ge "$built" ] \
    || die "running process predates the build — the render would be stale"
  echo "  pid $pid, binary $(date -r "$built" +%H:%M:%S), started $(date -r "$started" +%H:%M:%S)"
}

# Where the running app keeps its data. It used to be this checkout's own `data/`, so
# `render` wrote its control files next to the source while the app read them from
# somewhere else entirely and produced nothing. One definition, here.
DATA="${KEYHUD_DATA_DIR:-$HOME/Library/Application Support/KeyHUD}"

render() {
  # Pinned so two captures of different builds are comparable: whether the text-editing
  # layer applies otherwise depends on what happens to have keyboard focus at that instant.
  echo "${KEYHUD_TEXT_LAYER:-1}" > "$DATA/preview-text-layer.txt"
  # Removed on the way out. It is read only by the offscreen render, but a file left in
  # the data directory is a file the next run finds.
  trap 'rm -f "$DATA/preview-text-layer.txt"' RETURN
  local target="${1:-}"
  [ -n "$target" ] && echo "$target" > "$DATA/preview-target.txt" || rm -f "$DATA/preview-target.txt"
  rm -f "$DATA"/preview-*.png
  kill -USR1 "$(pgrep -f "$PROC" | head -1)" || die "no process to signal"
  for _ in $(seq 1 15); do [ -f "$DATA/preview-list.png" ] && break; sleep 1; done
  [ -f "$DATA/preview-list.png" ] || die "no preview produced"
  mkdir -p docs
  cp "$DATA/preview-list.png" "$DATA/preview-keymap.png" docs/ 2>/dev/null
  echo "  docs/preview-list.png  docs/preview-keymap.png"
}

corpus() {
  kill -USR2 "$(pgrep -f "$PROC" | head -1)" || die "no process to signal"
  for _ in $(seq 1 20); do
    [ Tests/KeyHUDCoreTests/Fixtures/ax-corpus.json -nt /tmp/keyhud-build.log ] && break
    sleep 1
  done
  python3 -c "
import json; d=json.load(open('Tests/KeyHUDCoreTests/Fixtures/ax-corpus.json'))
print(f'  {len(d)} apps, {sum(len(v) for v in d.values())} shortcuts')"
}

lint() {
  echo "▸ linting"
  python3 tools/lint.py || die "lint failed"
}

case "${1:-all}" in
  build)   build ;;
  lint)    lint ;;
  test)    test_all ;;
  restart) restart ;;
  render)  render "${2:-}" ;;
  corpus)  corpus ;;
  all)     build; lint; test_all; restart; render "${2:-}" ;;
  *) echo "usage: ./dev.sh [all|build|lint|test|restart|render <app>|corpus]"; exit 2 ;;
esac
