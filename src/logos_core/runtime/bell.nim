## A wake-up signal with a deadline, for the Runtime thread's loop [IMPL].
##
## The lock and condition variable are allocated with their C sizes: Nim's
## `sizeof` of the imported `pthread_mutex_t` and `pthread_cond_t` is 8 on
## macOS, where C says 64 and 48.
##
## `std/locks` has no timed wait, and the Runtime thread must wake both for a
## new message and for the next startup or drain deadline. A bell remembers one
## ring until the waiter takes it, so a ring between the waiter's last check
## and its wait is not lost. It lives in malloc'd memory, so it never moves and
## holds no garbage-collected value: any thread may ring it under either memory
## manager.

{.push raises: [].}

import std/[monotimes, times]
import results
when defined(windows):
  type
    CriticalSection {.importc: "CRITICAL_SECTION", header: "<windows.h>".} = object
    ConditionVariable {.importc: "CONDITION_VARIABLE", header: "<windows.h>".} = object

  proc initializeCriticalSection(
    cs: ptr CriticalSection
  ) {.importc: "InitializeCriticalSection", header: "<windows.h>".}

  proc enterCriticalSection(
    cs: ptr CriticalSection
  ) {.importc: "EnterCriticalSection", header: "<windows.h>".}

  proc leaveCriticalSection(
    cs: ptr CriticalSection
  ) {.importc: "LeaveCriticalSection", header: "<windows.h>".}

  proc initializeConditionVariable(
    cv: ptr ConditionVariable
  ) {.importc: "InitializeConditionVariable", header: "<windows.h>".}

  proc sleepConditionVariableCS(
    cv: ptr ConditionVariable, cs: ptr CriticalSection, ms: uint32
  ): int32 {.importc: "SleepConditionVariableCS", header: "<windows.h>".}

  proc wakeAllConditionVariable(
    cv: ptr ConditionVariable
  ) {.importc: "WakeAllConditionVariable", header: "<windows.h>".}

  {.
    emit: """
#include <windows.h>
static size_t lcn_bell_lock_size(void) { return sizeof(CRITICAL_SECTION); }
static size_t lcn_bell_cond_size(void) { return sizeof(CONDITION_VARIABLE); }
"""
  .}

  type
    LockT = CriticalSection
    CondT = ConditionVariable

else:
  import std/posix

  {.
    emit: """
#include <pthread.h>
static size_t lcn_bell_lock_size(void) { return sizeof(pthread_mutex_t); }
static size_t lcn_bell_cond_size(void) { return sizeof(pthread_cond_t); }
"""
  .}

  type
    LockT = Pthread_mutex
    CondT = Pthread_cond

proc lockSize(): csize_t {.importc: "lcn_bell_lock_size", nodecl.}
proc condSize(): csize_t {.importc: "lcn_bell_cond_size", nodecl.}

type BellObj = object
  lock: ptr LockT
  cond: ptr CondT
  rung: bool

type Bell* = ptr BellObj

proc cMalloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc cAlloc(n: csize_t): pointer =
  result = cMalloc(n)
  doAssert result != nil, "out of memory"
  zeroMem(result, int(n))

proc newBell*(): Bell =
  result = cast[Bell](cAlloc(csize_t(sizeof(BellObj))))
  result.lock = cast[ptr LockT](cAlloc(lockSize()))
  result.cond = cast[ptr CondT](cAlloc(condSize()))
  when defined(windows):
    initializeCriticalSection(result.lock)
    initializeConditionVariable(result.cond)
  else:
    doAssert pthread_mutex_init(result.lock, nil) == 0
    doAssert pthread_cond_init(result.cond, nil) == 0

proc freeBell*(b: Bell) =
  ## Only once no thread can ring or wait on `b` any more.
  when not defined(windows):
    discard pthread_cond_destroy(b.cond)
    discard pthread_mutex_destroy(b.lock)
  cFree(b.cond)
  cFree(b.lock)
  cFree(b)

template locked(b: Bell, body: untyped) =
  when defined(windows):
    enterCriticalSection(b.lock)
  else:
    discard pthread_mutex_lock(b.lock)
  body
  when defined(windows):
    leaveCriticalSection(b.lock)
  else:
    discard pthread_mutex_unlock(b.lock)

proc ring*(b: Bell) =
  b.locked:
    b.rung = true
    when defined(windows):
      wakeAllConditionVariable(b.cond)
    else:
      discard pthread_cond_broadcast(b.cond)

proc waitSlice(b: Bell, ms: int64) =
  ## One wait of at most `ms` milliseconds; the lock is held.
  when defined(windows):
    discard sleepConditionVariableCS(b.cond, b.lock, uint32(ms))
  else:
    # [IMPL] An absolute CLOCK_REALTIME time, which every POSIX target accepts;
    # a clock step only ends this slice early or late, because the caller
    # measures the deadline on the monotonic clock.
    var now: Timespec
    discard clock_gettime(CLOCK_REALTIME, now)
    var sec = int64(now.tv_sec) + ms div 1000
    var nsec = int64(now.tv_nsec) + (ms mod 1000) * 1_000_000
    if nsec >= 1_000_000_000:
      inc sec
      nsec -= 1_000_000_000
    var at: Timespec
    at.tv_sec = posix.Time(sec)
    at.tv_nsec = typeof(at.tv_nsec)(nsec)
    discard pthread_cond_timedwait(b.cond, b.lock, addr at)

proc wait*(b: Bell, deadline = Opt.none(MonoTime)) =
  ## Returns once `b` has been rung since the previous return, or once
  ## `deadline` has passed. With no deadline it waits for a ring only.
  b.locked:
    while not b.rung:
      if deadline.isNone:
        when defined(windows):
          discard sleepConditionVariableCS(b.cond, b.lock, 0xFFFF_FFFF'u32)
        else:
          discard pthread_cond_wait(b.cond, b.lock)
      else:
        let left = (deadline.get - getMonoTime()).inMilliseconds
        if left <= 0:
          break
        # Slices of at most a minute keep the conversion in range everywhere.
        b.waitSlice(min(left + 1, 60_000))
    b.rung = false
