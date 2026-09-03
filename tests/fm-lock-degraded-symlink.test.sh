#!/usr/bin/env bash
# Behavior tests for the lock primitives on a host where "ln -s" reports success
# while publishing a directory copy instead of a symlink, and for the bounded
# acquire that keeps one unpublishable lock from silencing a whole home.
#
# The degradation is injected with a PATH shim rather than an environment
# variable, so these cases exercise the same code path on every host instead of
# only where MSYS happens to behave this way.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-degraded-symlink)
REAL_LN=$(command -v ln)

# make_case <name> [degraded]: a state dir, plus a fakebin whose "ln -s" copies
# the directory instead of linking it when <degraded> is non-empty.
make_case() {
  local name=$1 degraded=${2:-} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin"
  if [ -n "$degraded" ]; then
    cat > "$dir/fakebin/ln" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then
  shift
  cp -R -- "\$1" "\$2"
  exit \$?
fi
exec "$REAL_LN" "\$@"
SH
    chmod +x "$dir/fakebin/ln"
  fi
  printf '%s\n' "$dir"
}

# in_case <dir> <script>: run <script> with the case's state dir and fakebin,
# with the production lock library sourced.
in_case() {
  local dir=$1 script=$2
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
    bash -c '. "$1"; shift; eval "$1"' _ "$LIB" "$script"
}

test_degraded_ln_still_publishes_a_usable_lock() {
  local dir out
  dir=$(make_case degraded-publish degraded)
  out=$(in_case "$dir" '
    lock="$FM_STATE_OVERRIDE/.watch.lock"
    fm_lock_try_acquire "$lock" || { echo "ACQUIRE_FAILED"; exit 0; }
    printf "%s\n" "$FM_LOCK_SYMLINK_MODE"
    # The holder must be able to publish the rest of the lock record; an
    # unconfirmable lock is what left every arm cycle reporting no identity.
    printf "identity\n" > "$lock/pid-identity" || echo "IDENTITY_UNWRITABLE"
    fm_lock_release "$lock"
    [ -e "$lock" ] && echo "RELEASE_LEAKED"
    exit 0') || fail "degraded acquire case failed to run"

  case "$out" in
    *ACQUIRE_FAILED*) fail "a degraded ln left the lock unacquirable" ;;
    *IDENTITY_UNWRITABLE*) fail "the holder could not publish its lock record" ;;
    *RELEASE_LEAKED*) fail "release left the lock behind" ;;
  esac
  case "$out" in
    *degraded*) : ;;
    *) fail "the degradation was not detected: $out" ;;
  esac
  assert_absent "$dir/state/.watch.lock" "the released lock was not removed"
  assert_absent "$dir/state/.watch.lock.steal" "a steal artifact was left behind"

  pass "a degraded ln -s still publishes a usable, releasable lock"
}

test_degraded_ln_leaves_no_steal_chain() {
  local dir chain
  dir=$(make_case degraded-no-chain degraded)
  # Ten sequential attempts: each used to append one ".steal" level, because
  # nothing could ever publish or reclaim the artifact it left behind.
  in_case "$dir" '
    lock="$FM_STATE_OVERRIDE/.chain.lock"
    i=0
    while [ "$i" -lt 10 ]; do
      fm_lock_try_acquire "$lock" && fm_lock_release "$lock"
      i=$((i + 1))
    done
    exit 0' >/dev/null 2>&1 || fail "repeated degraded acquire failed to run"

  chain=$(find "$dir/state" -maxdepth 1 -name '.chain.lock*steal*' 2>/dev/null | wc -l)
  [ "$chain" -eq 0 ] || fail "repeated acquires left $chain steal artifacts"

  pass "repeated acquires on a degraded host build no .steal chain"
}

test_bare_directory_with_dead_owner_is_reclaimed() {
  local dir dead out
  dir=$(make_case reclaim-dead degraded)
  # A pid that is certainly dead: a child that has already exited.
  dead=$(bash -c 'echo $$')
  mkdir -p "$dir/state/.acq.lock"
  printf '%s\n' "$dead" > "$dir/state/.acq.lock/pid"
  # Older than the mid-acquire grace, so the record is genuinely abandoned
  # rather than a lock being published right now.
  sleep 3

  out=$(in_case "$dir" '
    lock="$FM_STATE_OVERRIDE/.acq.lock"
    fm_lock_acquire_wait "$lock" 20 || { echo "NOT_RECLAIMED"; exit 0; }
    printf "recovered=%s\n" "$FM_LOCK_RECOVERED_PID"
    fm_lock_release "$lock"
    exit 0') || fail "dead-owner reclaim case failed to run"

  case "$out" in
    *NOT_RECLAIMED*) fail "a bare-directory lock with a dead owner was not reclaimed" ;;
  esac
  case "$out" in
    *"recovered=$dead"*) : ;;
    *) fail "the reclaim did not report the dead owner it replaced: $out" ;;
  esac

  pass "a bare-directory lock whose owner is provably dead is reclaimed"
}

test_bare_directory_without_pid_is_reclaimed() {
  local dir out
  dir=$(make_case reclaim-nopid degraded)
  mkdir -p "$dir/state/.nopid.lock"
  sleep 3

  out=$(in_case "$dir" '
    lock="$FM_STATE_OVERRIDE/.nopid.lock"
    fm_lock_acquire_wait "$lock" 20 || { echo "NOT_RECLAIMED"; exit 0; }
    fm_lock_release "$lock"
    exit 0') || fail "pid-less reclaim case failed to run"

  case "$out" in
    *NOT_RECLAIMED*) fail "a bare-directory lock carrying no pid file was not reclaimed" ;;
  esac

  pass "a bare-directory lock carrying no pid file is reclaimed"
}

test_live_owner_is_never_reclaimed() {
  local dir live out
  dir=$(make_case live-owner degraded)
  sleep 30 &
  live=$!
  mkdir -p "$dir/state/.busy.lock"
  printf '%s\n' "$live" > "$dir/state/.busy.lock/pid"
  sleep 3

  out=$(in_case "$dir" '
    lock="$FM_STATE_OVERRIDE/.busy.lock"
    if fm_lock_acquire_wait "$lock" 2; then echo "STOLE_LIVE_LOCK"; else echo "refused"; fi
    printf "reason=%s\n" "$FM_LOCK_WAIT_FAIL_REASON"
    exit 0' 2>/dev/null) || fail "live-owner case failed to run"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  case "$out" in
    *STOLE_LIVE_LOCK*) fail "a lock held by a live owner was reclaimed" ;;
  esac
  case "$out" in
    *"reason=held by live pid $live"*) : ;;
    *) fail "the refusal did not name the live holder: $out" ;;
  esac
  assert_present "$dir/state/.busy.lock" "the live owner's lock was removed"

  pass "a lock held by a live owner is refused, never reclaimed"
}

test_acquire_wait_is_bounded_and_reports_the_path() {
  local dir live started elapsed status err
  dir=$(make_case bounded-wait degraded)
  sleep 60 &
  live=$!
  mkdir -p "$dir/state/.wedged.lock"
  printf '%s\n' "$live" > "$dir/state/.wedged.lock/pid"
  sleep 3

  err="$dir/wait.err"
  started=$(date +%s)
  status=0
  in_case "$dir" '
    fm_lock_acquire_wait "$FM_STATE_OVERRIDE/.wedged.lock" 2' 2> "$err" || status=$?
  elapsed=$(( $(date +%s) - started ))
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  [ "$status" -ne 0 ] || fail "the bounded wait returned as though it had acquired"
  # The ceiling is two seconds; anything near the old unbounded spin fails here.
  [ "$elapsed" -lt 30 ] || fail "the wait ran ${elapsed}s past its 2s ceiling"
  assert_grep "$dir/state/.wedged.lock" "$err" "the refusal did not name the lock path"
  assert_grep "held by live pid $live" "$err" "the refusal did not name the reason"

  pass "the blocking acquire is bounded and names the path and reason on refusal"
}

test_or_die_refuses_to_enter_the_critical_section() {
  local dir live out status
  dir=$(make_case or-die degraded)
  sleep 60 &
  live=$!
  mkdir -p "$dir/state/.wedged.lock"
  printf '%s\n' "$live" > "$dir/state/.wedged.lock/pid"
  sleep 3

  status=0
  out=$(in_case "$dir" '
    fm_lock_acquire_wait "$FM_STATE_OVERRIDE/.wedged.lock" 2 >/dev/null 2>&1 || true
    FM_LOCK_ACQUIRE_WAIT_MAX=2 fm_lock_acquire_wait_or_die "$FM_STATE_OVERRIDE/.wedged.lock"
    echo "ENTERED_UNLOCKED"' 2>/dev/null) || status=$?
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  [ "$status" -ne 0 ] || fail "the fail-closed acquire did not stop the caller"
  case "$out" in
    *ENTERED_UNLOCKED*) fail "the caller continued into its critical section without the lock" ;;
  esac

  pass "the fail-closed acquire stops the caller instead of continuing unlocked"
}

test_steal_recursion_is_capped() {
  local dir out
  dir=$(make_case steal-cap degraded)
  # A steal artifact whose owner is alive cannot be reclaimed, so the acquire
  # has to refuse. It must refuse at the cap rather than appending another
  # ".steal" level per attempt.
  sleep 30 &
  live=$!
  mkdir -p "$dir/state/.capped.lock" "$dir/state/.capped.lock.steal"
  printf '999999\n' > "$dir/state/.capped.lock/pid"
  printf '%s\n' "$live" > "$dir/state/.capped.lock.steal/pid"
  sleep 3

  out=$(in_case "$dir" '
    i=0
    while [ "$i" -lt 5 ]; do
      fm_lock_try_acquire "$FM_STATE_OVERRIDE/.capped.lock" && echo UNEXPECTED_WIN
      i=$((i + 1))
    done
    exit 0' 2>/dev/null) || fail "capped steal case failed to run"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  case "$out" in
    *UNEXPECTED_WIN*) fail "the acquire took a lock whose steal is held by a live owner" ;;
  esac
  assert_absent "$dir/state/.capped.lock.steal.steal" \
    "the acquire nested a second steal level past the cap"

  pass "steal recovery refuses at its depth cap instead of growing a chain"
}

test_single_winner_under_concurrency_on_a_degraded_host() {
  local dir winners violations
  dir=$(make_case degraded-mutex degraded)
  # Every racer spins on a start file before touching the lock, so they reach
  # publication together instead of being serialised by process startup.
  #
  # The property asserted is mutual EXCLUSION, not a winner count. A racer whose
  # startup outlasts the hold acquires legitimately after the release, so "how
  # many ever acquired" is a function of host speed; "did two hold it at once"
  # is not. Each holder marks the lock occupied and records a violation if it
  # was already marked.
  in_case "$dir" '
    lock="$FM_STATE_OVERRIDE/.race.lock"
    wins="$FM_STATE_OVERRIDE/wins"
    bad="$FM_STATE_OVERRIDE/violations"
    occupied="$FM_STATE_OVERRIDE/occupied"
    start="$FM_STATE_OVERRIDE/start"
    : > "$wins"
    : > "$bad"
    i=0
    while [ "$i" -lt 8 ]; do
      (
        while [ ! -e "$start" ]; do :; done
        if fm_lock_try_acquire "$lock"; then
          [ -e "$occupied" ] && echo overlap >> "$bad"
          : > "$occupied"
          echo win >> "$wins"
          sleep 0.3
          rm -f "$occupied"
          fm_lock_release "$lock"
        fi
      ) &
      i=$((i + 1))
    done
    : > "$start"
    wait
    exit 0' >/dev/null 2>&1 || fail "degraded concurrency case failed to run"

  # grep -c prints 0 and exits 1 on no match, so a `|| echo 0` fallback would
  # append a second count; count the lines instead.
  violations=$(awk '/overlap/ { c++ } END { print c + 0 }' "$dir/state/violations")
  winners=$(awk '/win/ { c++ } END { print c + 0 }' "$dir/state/wins")
  [ "$violations" -eq 0 ] || fail "$violations racers held the lock at the same time"
  [ "$winners" -ge 1 ] || fail "no racer ever acquired the contended lock"
  assert_absent "$dir/state/.race.lock" "the last holder leaked its lock"
  assert_absent "$dir/state/.race.lock.steal" "a steal artifact outlived the race"

  pass "contended racers never hold a degraded-host lock at the same time"
}

test_native_host_still_publishes_a_symlink() {
  local dir out
  dir=$(make_case native)
  out=$(in_case "$dir" '
    lock="$FM_STATE_OVERRIDE/.native.lock"
    fm_lock_try_acquire "$lock" || { echo "ACQUIRE_FAILED"; exit 0; }
    printf "%s\n" "$FM_LOCK_SYMLINK_MODE"
    [ -L "$lock" ] || echo "NOT_A_SYMLINK"
    fm_lock_release "$lock"
    [ -e "$lock" ] && echo "RELEASE_LEAKED"
    exit 0') || fail "native case failed to run"

  case "$out" in
    *ACQUIRE_FAILED*) fail "the ordinary symlink path stopped acquiring" ;;
    *NOT_A_SYMLINK*) fail "a symlink-capable host stopped publishing a symlink" ;;
    *RELEASE_LEAKED*) fail "release left the lock behind on the symlink path" ;;
    *native*) : ;;
    *) fail "a symlink-capable host was misreported as degraded: $out" ;;
  esac
  # The probe must not leave anything in the state directory it probed.
  [ "$(find "$dir/state" -maxdepth 1 -name '.fm-symprobe*' | wc -l)" -eq 0 ] \
    || fail "the symlink probe left residue behind"

  pass "a symlink-capable host is unchanged and the probe leaves no residue"
}

test_degraded_ln_still_publishes_a_usable_lock
test_degraded_ln_leaves_no_steal_chain
test_bare_directory_with_dead_owner_is_reclaimed
test_bare_directory_without_pid_is_reclaimed
test_live_owner_is_never_reclaimed
test_acquire_wait_is_bounded_and_reports_the_path
test_or_die_refuses_to_enter_the_critical_section
test_steal_recursion_is_capped
test_single_winner_under_concurrency_on_a_degraded_host
test_native_host_still_publishes_a_symlink
