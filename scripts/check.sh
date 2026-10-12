#!/bin/zsh
# Checks MousePilot after every change:
#   1. self-tests (Tests/SelfTests.swift): hit testing on synthetic window layouts,
#      routing, config parsing, scroll steps, tab arithmetic, Apple Event values, gestures;
#      overlay test (Tests/OverlayTest.swift): a scripted gesture's trail and title panels
#      appear where they belong and go away (a green stroke shows for half a second)
#   2. script tests: build.sh / mousepilotctl syntax, mousepilotctl config edits
#   3. CPU and memory: a debuggable copy of build/MousePilot.app (same signing identity, no
#      Hardened Runtime, malloc stack logging) briefly replaces the running app and gets
#      3 × 20,000 zero-delta scrolls (nothing scrolls, no tab changes): idle CPU (only while
#      nobody uses the keyboard and mouse — leave the Mac alone for that minute), CPU per
#      scroll, memory growth between rounds (these need a browser window on screen, which
#      turns the copy's scroll tap on); then scripted gestures that the app draws
#      itself (a green line in the middle of the main display for a few seconds, no action,
#      the cursor is not moved): `leaks` (none from MousePilot's own code, no growth),
#      event-tap timeouts; then, restarted without malloc stack logging, the physical
#      footprint before and after gestures, the CPU per right-drag event and per press on
#      the event tap thread (synthetic events through the real handler, no action runs)
#      and the instructions to draw a gesture (its time depends on the cores macOS picks). Finally the installed app is started again.
#
#   scripts/check.sh            everything (builds first; may ask for the signing keychain)
#   scripts/check.sh --quick    1 and 2 only
set -u
ROOT=${0:a:h:h}
APP=/Applications/MousePilot.app
LOG=~/Library/Logs/mousepilot.log
SIGNING_KC=~/Library/Keychains/tabwheel-signing.keychain-db
TMP=$(mktemp -d)
replaced=0   # the installed app is quit while a test copy runs
reported=0
failed=0
results=()
pass() { results+=("PASS  $1"); }
fail() { results+=("FAIL  $1"); failed=1; }
report() { reported=1; print; printf '%s\n' "${results[@]}"; print; (( failed )) && echo "check: FAILED" || echo "check: all passed"; }
mine() { pgrep -U $UID -x mousepilot; }   # this user's MousePilot processes
# Interrupted (Ctrl-C) or stopped by an error, the installed app comes back, the test copy
# goes and the results so far are shown; a second Ctrl-C cannot break that.
cleanup() {
  local rc=$?
  trap '' INT TERM HUP
  (( replaced )) && restore
  if (( ! reported )); then fail "the check stopped early (exit $rc)"; report; fi
  rm -rf $TMP
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

# Builds a test binary; on failure shows the compiler's errors.
build_test() {   # name, define, test file, output
  local err
  if ! err=$(swiftc -D $2 -target $(uname -m)-apple-macos13 $ROOT/Sources/MousePilot/*.swift $3 -o $4 2>&1); then
    print -r -- "$err" | grep -E 'error:'
    fail "$1: did not compile ($(print -r -- "$err" | grep -m1 -E 'error:'))"
    return 1
  fi
}

# 1. self-tests
if build_test self-tests SELFTEST $ROOT/Tests/SelfTests.swift $TMP/selftest; then
  if out=$($TMP/selftest 2>&1); then pass "self-tests: $(print -r -- $out | tail -1)"
  else print -r -- "$out" | grep FAIL; fail "self-tests: $(print -r -- $out | tail -1)"; fi
fi

# 1b. the gesture trail and title reach the screen
if build_test "overlay test" OVERLAYTEST $ROOT/Tests/OverlayTest.swift $TMP/overlaytest; then
  if out=$($TMP/overlaytest 2>&1); then pass "$(print -r -- $out | tail -1)"
  else print -r -- "$out" | grep FAIL; fail "$(print -r -- $out | tail -1)"; fi
fi

# 2. scripts
zsh -n $ROOT/scripts/build.sh && zsh -n $ROOT/scripts/mousepilotctl && pass "scripts: syntax" || fail "scripts: syntax"
H=$TMP/home; mkdir -p $H
ctl() { HOME=$H CFFIXED_USER_HOME=$H zsh $ROOT/scripts/mousepilotctl "$@" 2>&1 }   # the app's own home too
ctl add whale 30 50 >/dev/null; ctl add safari >/dev/null; ctl remove brave >/dev/null
conf=$(grep -v '^#' $H/.config/mousepilot/browsers 2>/dev/null)
if [[ $conf == *"com.naver.Whale 30 50"* && $conf == *"com.apple.Safari 50 88"* && $conf != *"com.brave.Browser"* ]]; then
  pass "mousepilotctl: add / remove / Safari default band"
else
  fail "mousepilotctl: config edits gave: ${conf//$'\n'/, }"
fi
[[ $(ctl add chrome x) == *"숫자"* && $(ctl add chrome 50 40) == *"커야"* ]] && pass "mousepilotctl: rejects bad bands" \
  || fail "mousepilotctl: bad bands accepted"

if [[ ${1:-} == --quick ]]; then report; exit $failed; fi

# 3. CPU and memory on a debuggable copy
$ROOT/scripts/build.sh >/dev/null 2>&1 || { fail "build failed"; report; exit 1; }
# The command line works before the app's own start-up (it once read globals not set yet).
CH=$TMP/clihome; mkdir -p $CH
if HOME=$CH CFFIXED_USER_HOME=$CH $ROOT/build/MousePilot.app/Contents/MacOS/mousepilot --write-default-config 2>/dev/null \
   && [[ -s $CH/.config/mousepilot/browsers ]]; then pass "--write-default-config writes the default browser list"
else fail "--write-default-config did not write the default browser list"; fi
swiftc -O $ROOT/Tests/post.swift -o $TMP/post 2>/dev/null && swiftc -O $ROOT/Tests/tapstate.swift -o $TMP/tapstate 2>/dev/null \
  && swiftc -O $ROOT/Tests/rusage.swift -o $TMP/rusage 2>/dev/null \
  || { fail "test helpers did not build"; report; exit 1; }
ditto $ROOT/build/MousePilot.app $TMP/MousePilot.app
cat > $TMP/debug.entitlements <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
P
codesign -f -s "TabWheel Developer" --keychain $SIGNING_KC -i com.pms.mousepilot --entitlements $TMP/debug.entitlements \
  --timestamp=none $TMP/MousePilot.app >/dev/null 2>&1 || { fail "could not sign the test copy (signing keychain locked?)"; report; exit 1; }

quit_mousepilot() {
  mine >/dev/null || return 0
  osascript -e 'with timeout of 5 seconds' -e 'tell application id "com.pms.mousepilot" to quit' -e 'end timeout' >/dev/null 2>&1
  for i in {1..25}; do mine >/dev/null || return 0; sleep 0.2; done
  return 1
}
restore() {
  trap '' INT TERM HUP   # once started, it runs to the end (its callers report and exit next)
  if ! quit_mousepilot; then   # a test copy that does not quit is stopped (never the installed app)
    for p in $(mine); do [[ $(ps -o comm= -p $p) == $APP/Contents/MacOS/mousepilot ]] || kill $p; done
    sleep 1
  fi
  open $APP; replaced=0; sleep 3
  local p=$(mine | head -1)
  if [[ -n $p && $(ps -o comm= -p $p) == $APP/Contents/MacOS/mousepilot && $($TMP/tapstate) == "taps 3 enabled"* ]]; then
    pass "installed app running again ($($TMP/tapstate))"
  else fail "installed app not running properly after the check ($($TMP/tapstate 2>&1))"; fi
}
replaced=1
quit_mousepilot || { replaced=0; fail "the running MousePilot did not quit"; report; exit 1; }
lines=$(wc -l < $LOG 2>/dev/null || echo 0)
# -debug NO: measure the production configuration even if debug logging is on; gestures, their
# trail and title on whatever the user's settings say (argument domain, this process only).
SETTINGS=(-debug NO -gestureDemo YES -paused '<false/>' -mouseGestures '<true/>' -gestureStroke '<true/>' -gestureTitle '<true/>')
open -n $TMP/MousePilot.app --env MallocStackLogging=1 --args $SETTINGS
# true once the test copy logs that its taps are installed (within 10 s)
taps_installed() {
  local i; for i in {1..40}; do tail -n +$((lines + 1)) $LOG 2>/dev/null | grep -q "event tap installed" && return 0; sleep 0.25; done
  return 1
}
installed=0; taps_installed && installed=1
P=$(mine | head -1)
if [[ -z $P || $(ps -o comm= -p $P) == $APP/* ]]; then fail "test copy did not start"; restore; report; exit 1; fi
(( installed )) || { fail "test copy's event taps not installed (Accessibility permission?)"; restore; report; exit 1; }
cpu() { ps -o time= -p $P | awk -F'[:.]' '{print ($1*60+$2)*1000+$3*10}'; }
rss() { ps -o rss= -p $P | tr -d ' '; }
# A test copy that crashed must not read as zero CPU and memory.
alive() { kill -0 $P 2>/dev/null && return; fail "test copy (pid $P) died during $1 (crash? see ~/Library/Logs/DiagnosticReports)"; restore; report; exit 1; }
tcount() { tail -n +$((lines + 1)) $LOG 2>/dev/null | grep -c "timed out"; }
excused=0
# leaks suspends the copy while it reads it, so a tap timeout logged meanwhile is leaks', not
# MousePilot's. Sets $1 to the leak count (empty without a reading), $2 to the stack frames in
# MousePilot's own code.
leakcount() {
  local t0=$(tcount) out
  out=$(leaks $P 2>/dev/null)
  sleep 1; (( excused += $(tcount) - t0 ))
  typeset -g $1="$(print -r -- $out | sed -nE 's/.*: ([0-9]+) leaks? for.*/\1/p')"
  [[ -n ${2:-} && -n ${(P)1} ]] && typeset -g $2="$(print -r -- $out | awk '/^STACK OF/{s=1} s && /[0-9]+ +mousepilot +0x/{n++} END{print n+0}')"   # only with a reading
  return 0
}

# Idle CPU over 5 s windows in which nobody touched the keyboard or mouse (HIDIdleTime): using
# the Mac makes the browsers' windows move and change, which MousePilot rightly follows. Up to
# twelve windows to find four quiet ones; the median of those is judged.
hid_idle() { ioreg -c IOHIDSystem 2>/dev/null | awk '/"HIDIdleTime"/ {print int($NF / 1000000); exit}'; }   # ms since the last input
sleep 3; typeset -a idle busy
for i in {1..12}; do
  c0=$(cpu); sleep 5; c1=$(cpu)
  if (( $(hid_idle) >= 5000 )); then idle+=($((c1 - c0))); else busy+=($((c1 - c0))); fi
  (( ${#idle} == 4 )) && break
done
if (( ${#idle} >= 2 )); then
  n=${#idle}; idle=(${(on)idle})
  if (( n % 2 )); then median=${idle[$(( (n + 1) / 2 ))]}; else median=$(( (idle[n / 2] + idle[n / 2 + 1]) / 2 )); fi
  (( median <= 25 )) && pass "idle CPU: median $median ms per 5 s while the Mac was not in use (${idle[*]}; skipped ${#busy} busy windows)" \
    || fail "idle CPU: median $median ms per 5 s while the Mac was not in use (${idle[*]})"
else
  results+=("INFO  idle CPU not judged: the Mac was in use the whole minute (${busy[*]} ms per 5 s); run the check again and leave it alone")
fi
alive "the idle minute"
typeset -a per mem
# The scrolls reach the test copy only while its scroll tap is on (a browser window on
# screen); judged only if it was on before and after the rounds.
taps0=$($TMP/tapstate)
for round in 1 2 3; do
  c0=$(cpu); $TMP/post 20000 auto >/dev/null; sleep 1; c1=$(cpu)
  per+=($(( (c1 - c0) * 1000 / 20000 ))); mem+=($(rss))
  (( round == 1 )) && leakcount leaks1
done
leakcount leaks3
alive "the scroll rounds"
taps1=$($TMP/tapstate)
if [[ ${#per} != 3 || ${#mem} != 3 || $leaks1$leaks3 != <-> || -z $leaks1 || -z $leaks3 ]]; then
  fail "scroll rounds gave no reading (CPU ${per[*]:-none}, memory ${mem[*]:-none} KB, leaks ${leaks1:-?} ${leaks3:-?})"
elif [[ $taps0 == *"scroll 1"* && $taps1 == *"scroll 1"* ]]; then
  (( per[3] <= 200 )) && pass "CPU per scroll: ${per[1]} / ${per[2]} / ${per[3]} µs" || fail "CPU per scroll: ${per[*]} µs"
  (( mem[3] - mem[2] <= 1024 )) && pass "memory: ${mem[1]} → ${mem[2]} → ${mem[3]} KB (no growth)" \
    || fail "memory grows: ${mem[1]} → ${mem[2]} → ${mem[3]} KB"
  (( leaks3 <= leaks1 )) && pass "leaks: $leaks1 after round 1, $leaks3 after round 3 (system frameworks, no growth)" \
    || fail "leaks grow: $leaks1 → $leaks3"
else
  results+=("INFO  scroll cost, memory and leaks across scrolls not measured: the test copy's scroll tap was off"
            "      ($taps0 → $taps1); show a Brave, Chrome, Safari or Whale window on this Space and run again")
fi
# Gestures: each SIGUSR1 makes the app draw three scripted gestures (no action, the cursor
# stays where it is) — twice here for leaks, twice more below for memory and drawing time.
demo() {
  local before=$(grep -c "gesture demo done" $LOG 2>/dev/null)
  kill -USR1 $P
  for i in {1..60}; do
    (( $(grep -c "gesture demo done" $LOG 2>/dev/null) > before )) && { sleep 1; return 0; }
    sleep 0.25
  done
  return 1
}
leaksA= leaksB= own=
if demo && leakcount leaksA && demo; then
  leakcount leaksB own
  if [[ -z $leaksA || -z $leaksB ]]; then fail "leaks gave no reading after the gestures"
  elif (( leaksB <= leaksA )); then pass "leaks: $leaksA after the first gestures, $leaksB after the second (no growth)"
  else fail "leaks grow with gestures: $leaksA → $leaksB"; fi
else
  fail "the gesture demo did not run"
fi
alive "the gesture demos"
timeouts=$(( $(tcount) - excused ))
[[ $own == <-> ]] && (( own == 0 )) && pass "leaks from MousePilot's own code: 0" || fail "leaks from MousePilot's own code: ${own:+$own frames}${own:-no reading}"
(( timeouts == 0 )) && pass "event tap timeouts: 0" || fail "event tap timeouts: $timeouts"
(( excused > 0 )) && results+=("INFO  $excused tap timeouts while leaks had the test copy suspended (keyboard or mouse in use; not counted)")

# Memory as Activity Monitor counts it (physical footprint), without malloc stack logging.
quit_mousepilot || { fail "the test copy did not quit"; restore; report; exit 1; }
lines=$(wc -l < $LOG 2>/dev/null || echo 0)
open -n $TMP/MousePilot.app --args $SETTINGS
taps_installed || fail "test copy's event taps not installed on restart"
P=$(mine | head -1)
fp() { vmmap --summary $P 2>/dev/null | awk '/^Physical footprint:/ {
  v = $3; u = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
  printf "%d\n", (u == "G" ? n * 1048576 : u == "M" ? n * 1024 : u == "K" ? n : n / 1024) }'; }
# The drawing is judged by the instructions it runs: its CPU time depends on whether macOS
# put the app on performance or efficiency cores (about twice as long there), not on MousePilot.
if [[ -n $P ]] && sleep 5 && f0=$(fp) && demo && f1=$(fp) && r0=($($TMP/rusage $P)) && demo && r1=($($TMP/rusage $P)) \
   && f2=$(fp); then
  (( f1 - f0 <= 4096 && f2 - f1 <= 512 )) \
    && pass "footprint: $f0 KB at start → $f1 after the first gestures → $f2 after the second (no growth)" \
    || fail "footprint: $f0 → $f1 → $f2 KB"
  done_line=$(tail -n +$((lines + 1)) $LOG | grep "gesture demo done" | tail -1)
  d=($(print -r -- $done_line | sed -n 's/.*drawing took \([0-9]*\) ms in \([0-9]*\) redraws.*/\1 \2/p'))
  h=($(print -r -- $done_line | sed -n 's/.*; \([0-9]*\) drag events took \([0-9.]*\) us each, a right-button press \([0-9]*\) us.*/\1 \2 \3/p'))
  instr=$(( (r1[3] - r0[3]) / 3 / 1000000 ))   # millions per gesture, all threads
  pcore=$(( r1[1] > r0[1] ? (r1[2] - r0[2]) * 100 / (r1[1] - r0[1]) : 0 ))
  # With a browser window in front the demo's events also go through the handler (~2,000
  # drags): about 106M instructions a gesture then, 71M for the drawing alone (2026-10-12).
  limit=$(( ${#h} == 3 ? 150 : 100 ))
  (( ${#d} == 2 && d[2] > 0 && instr > 0 && instr <= limit )) \
    && pass "drawing a gesture: ${instr}M instructions$( (( ${#h} == 3 )) && print ' with its events') ($(( d[1] / 3 )) ms of main-thread CPU, ${pcore}% on performance cores; $(( d[2] / 3 )) redraws)" \
    || fail "drawing a gesture: ${instr}M instructions, ${d[*]:-no measurement} (ms for 3 gestures, redraws; limit ${limit}M)"
  if (( ${#h} == 3 )); then
    (( h[2] <= 30 && h[3] <= 5000 )) \
      && pass "gesture handling: ${h[2]} µs per drag event on the event tap thread, ${h[3]} µs per right-button press" \
      || fail "gesture handling: ${h[2]} µs per drag event, ${h[3]} µs per right-button press"
  else
    results+=("INFO  gesture handling not timed: no Brave/Chrome/Safari window in front to start a gesture over")
  fi
else
  fail "footprint run did not work"
fi
foot=$(top -l 1 -pid $P -stats mem 2>/dev/null | tail -1 | tr -d ' ')
results+=("INFO  memory at the end, as Activity Monitor shows it: $foot")
restore
report
exit $failed
