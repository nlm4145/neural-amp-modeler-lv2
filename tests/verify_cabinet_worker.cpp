#include "cabinet_worker.h"

#include <array>
#include <cfenv>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <type_traits>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <mach/thread_policy.h>
#include <os/workgroup.h>
#include <pthread.h>

#ifdef NAMRIG_VERIFY_POLICY_FAILURE
// Build both translation units with -DNAMRIG_VERIFY_POLICY_FAILURE
// -Dthread_policy_set=verifyCabinetWorkerPolicySet to trace/inject policy calls.
#include <dlfcn.h>

namespace {
std::atomic<bool> failNextPolicy{false};
std::atomic<unsigned> policyCalls{0};
std::atomic<thread_t> lastPolicyCaller{MACH_PORT_NULL};
std::atomic<thread_t> lastPolicyTarget{MACH_PORT_NULL};
}  // namespace

extern "C" kern_return_t verifyCabinetWorkerPolicySet(
    thread_act_t thread, thread_policy_flavor_t flavor, thread_policy_t policy,
    mach_msg_type_number_t count) {
  using PolicySet = kern_return_t (*)(thread_act_t, thread_policy_flavor_t,
                                    thread_policy_t, mach_msg_type_number_t);
  static const auto original =
      reinterpret_cast<PolicySet>(dlsym(RTLD_DEFAULT, "thread_policy_set"));
  if (!original) std::abort();
  lastPolicyCaller.store(pthread_mach_thread_np(pthread_self()));
  lastPolicyTarget.store(thread);
  policyCalls.fetch_add(1);
  if (failNextPolicy.exchange(false)) return KERN_FAILURE;
  return original(thread, flavor, policy, count);
}
#endif

#ifdef NAMRIG_VERIFY_HANDOFF
// Also compile both files with -DNAMRIG_VERIFY_HANDOFF
// -Dsemaphore_wait_signal=verifyCabinetWorkerWaitSignal for interruption coverage.
#include <dlfcn.h>

namespace {
std::atomic<bool> abortNextHandoff{false};
std::atomic<unsigned> handoffCalls{0};
std::atomic<unsigned> interruptedHandoffs{0};
}  // namespace

extern "C" kern_return_t verifyCabinetWorkerWaitSignal(
    semaphore_t waitSemaphore, semaphore_t signalSemaphore) {
  using WaitSignal = kern_return_t (*)(semaphore_t, semaphore_t);
  static const auto original =
      reinterpret_cast<WaitSignal>(dlsym(RTLD_DEFAULT, "semaphore_wait_signal"));
  if (!original) std::abort();
  handoffCalls.fetch_add(1);
  if (abortNextHandoff.exchange(false)) {
    // Model an interrupted wait after its completion signal, without sleeps
    // or spins. A zero timeout still signals completion exactly once in XNU.
    const mach_timespec_t noWait{0, 0};
    const kern_return_t result =
        semaphore_timedwait_signal(waitSemaphore, signalSemaphore, noWait);
    if (result == KERN_OPERATION_TIMED_OUT) {
      interruptedHandoffs.fetch_add(1);
      return KERN_ABORTED;
    }
    return result;
  }
  return original(waitSemaphore, signalSemaphore);
}
#endif

#pragma STDC FENV_ACCESS ON

namespace {

using NAMRig::CabinetWorker;
constexpr double kPeriod = 128.0 / 48000.0;

void check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}

struct Semaphore {
  semaphore_t value = MACH_PORT_NULL;
  Semaphore() {
    check(semaphore_create(mach_task_self(), &value, SYNC_POLICY_FIFO, 0) ==
              KERN_SUCCESS,
          "test semaphore creation");
  }
  ~Semaphore() { semaphore_destroy(mach_task_self(), value); }
  void signal() noexcept {
    check(semaphore_signal(value) == KERN_SUCCESS, "test semaphore signal");
  }
  void wait() noexcept {
    kern_return_t result;
    do {
      result = semaphore_wait(value);
    } while (result == KERN_ABORTED);
    check(result == KERN_SUCCESS, "test semaphore wait");
  }
};

struct Gate {
  Semaphore entered;
  Semaphore release;
  Semaphore finished;
  unsigned calls = 0;
};

void gatedJob(void* context) noexcept {
  auto& gate = *static_cast<Gate*>(context);
  gate.entered.signal();
  gate.release.wait();
  ++gate.calls;
  gate.finished.signal();
}

struct Result {
  uint64_t seed = 0;
  uint64_t hash = 0;
  std::array<float, 4> values{};
  std::fenv_t environment{};
  int rounding = 0;
  int exceptions = 0;
  bool realTime = false;
  uint32_t periodTicks = 0;
  uint32_t constraintTicks = 0;
  uint32_t computationTicks = 0;
  unsigned calls = 0;
};

void calculate(void* context) noexcept {
  auto& result = *static_cast<Result*>(context);
  check(std::fegetenv(&result.environment) == 0, "capture job environment");
  result.rounding = std::fegetround();
  result.exceptions = std::fetestexcept(FE_ALL_EXCEPT);
  uint64_t hash = result.seed;
  for (unsigned i = 0; i < 64; ++i)
    hash = (hash ^ (hash >> 13)) * UINT64_C(0x9e3779b97f4a7c15) + i;
  result.hash = hash;
  volatile float one = 1.0f;
  volatile float small = 0x1p-24f;
  volatile float normal = 0x1p-126f;
  volatile float denormal = std::numeric_limits<float>::denorm_min();
  result.values[0] = one + small;
  result.values[1] = -one - small;
  result.values[2] = normal * 0.5f;
  result.values[3] = denormal * 2.0f;
  // Deliberately contaminate worker state; the next submit must restore it.
  check(std::fesetenv(FE_DFL_ENV) == 0, "reset job environment");
}

bool sameEnvironment(const std::fenv_t& a, const std::fenv_t& b) {
#if defined(__arm64__)
  return a.__fpcr == b.__fpcr && a.__fpsr == b.__fpsr;
#elif defined(__x86_64__)
  return a.__control == b.__control && a.__status == b.__status &&
         a.__mxcsr == b.__mxcsr;
#else
#error Unsupported macOS architecture
#endif
}

void inspectScheduling(void* context) noexcept {
  auto& result = *static_cast<Result*>(context);
  thread_time_constraint_policy_data_t policy{};
  mach_msg_type_number_t count = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
  boolean_t getDefault = FALSE;
  const kern_return_t status = thread_policy_get(
      pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
      reinterpret_cast<thread_policy_t>(&policy), &count, &getDefault);
  result.realTime = status == KERN_SUCCESS && !getDefault && policy.period > 0 &&
                    policy.computation > 0 &&
                    policy.computation <= policy.constraint &&
                    policy.constraint <= policy.period;
  result.periodTicks = policy.period;
  result.constraintTicks = policy.constraint;
  result.computationTicks = policy.computation;
  ++result.calls;
}

void increment(void* context) noexcept {
  ++*static_cast<unsigned*>(context);
}

}  // namespace

int main() {
  static_assert(std::is_same<decltype(&CabinetWorker::start),
                             bool (CabinetWorker::*)(void*, double) noexcept>::value);
  static_assert(std::is_same<decltype(&CabinetWorker::submit),
                             bool (CabinetWorker::*)(void (*)(void*) noexcept,
                                                    void*, uint64_t) noexcept>::value);
  static_assert(!std::is_copy_constructible<CabinetWorker>::value);
  static_assert(!std::is_copy_assignable<CabinetWorker>::value);
  static_assert(noexcept(CabinetWorker().start(nullptr, kPeriod)));
  static_assert(noexcept(CabinetWorker().stop()));
  static_assert(noexcept(CabinetWorker().submit(increment, nullptr)));
  static_assert(noexcept(CabinetWorker().wait()));

  std::fenv_t originalEnvironment;
  check(std::fegetenv(&originalEnvironment) == 0, "capture original environment");
  CabinetWorker worker;
  unsigned calls = 0;
  check(!worker.submit(increment, &calls), "stopped worker rejects submission");
  worker.wait();
  worker.stop();
  const double invalidPeriods[] = {
      0.0, -kPeriod, std::numeric_limits<double>::quiet_NaN(),
      std::numeric_limits<double>::infinity(),
      std::numeric_limits<double>::denorm_min(),
      std::numeric_limits<double>::max()};
  for (double period : invalidPeriods) {
    check(!worker.start(nullptr, period), "invalid period rejected");
    check(!worker.submit(increment, &calls), "failed start stays serial");
    worker.wait();
    worker.stop();
  }

  mach_timebase_info_data_t timebase{};
  check(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0,
        "query Mach timebase");
  // One tick is representable, but below Mach's minimum computation budget.
  const double tooShort = 1.5e-9 * timebase.numer / timebase.denom;
  check(!worker.start(nullptr, tooShort), "scheduler setup fails closed");
  check(!worker.submit(increment, &calls), "failed scheduler setup stays serial");
  worker.wait();
  worker.stop();

  {
    CabinetWorker deadlineWorker;
    check(deadlineWorker.start(nullptr, 0.02), "start deadline worker");
    unsigned deadlineCalls = 0;
    check(!deadlineWorker.submit(increment, &deadlineCalls, mach_absolute_time()),
          "expired deadline rejected before publication");
    const uint64_t tinyWindow = UINT64_C(50000) * timebase.denom / timebase.numer;
    check(!deadlineWorker.submit(increment, &deadlineCalls,
                                 mach_absolute_time() + tinyWindow),
          "less than 100us remaining rejected before publication");
    deadlineWorker.wait();
    check(deadlineCalls == 0, "rejected deadline jobs never execute");

    Result originalPolicy;
    check(deadlineWorker.submit(inspectScheduling, &originalPolicy),
          "inspect original deadline worker policy");
    deadlineWorker.wait();
    Result deadlinePolicy;
    const uint64_t futureWindow = UINT64_C(10000000) * timebase.denom / timebase.numer;
#ifdef NAMRIG_VERIFY_POLICY_FAILURE
    const unsigned beforeDeadline = policyCalls.load();
#endif
    check(deadlineWorker.submit(inspectScheduling, &deadlinePolicy,
                               mach_absolute_time() + futureWindow),
          "future deadline accepted");
#ifdef NAMRIG_VERIFY_POLICY_FAILURE
    check(policyCalls.load() == beforeDeadline + 1 &&
              lastPolicyCaller.load() == pthread_mach_thread_np(pthread_self()) &&
              lastPolicyTarget.load() != lastPolicyCaller.load(),
          "submit sets helper policy on caller before returning");
#endif
    deadlineWorker.wait();
    check(deadlinePolicy.calls == 1 && deadlinePolicy.realTime,
          "future deadline job executes exactly once");
#ifdef NAMRIG_VERIFY_POLICY_FAILURE
    check(policyCalls.load() == beforeDeadline + 1,
          "worker does not update policy after waking");
#endif
    check(deadlinePolicy.periodTicks == originalPolicy.periodTicks &&
              deadlinePolicy.constraintTicks < originalPolicy.constraintTicks &&
              deadlinePolicy.constraintTicks <= futureWindow &&
              deadlinePolicy.computationTicks <= deadlinePolicy.constraintTicks / 2 &&
              deadlinePolicy.computationTicks <= originalPolicy.computationTicks,
          "deadline tightens constraint and computation without changing period");

    Result restoredPolicy;
    check(deadlineWorker.submit(inspectScheduling, &restoredPolicy),
          "zero deadline restores original scheduling budget");
    deadlineWorker.wait();
    check(restoredPolicy.realTime &&
              restoredPolicy.constraintTicks == originalPolicy.constraintTicks &&
              restoredPolicy.computationTicks == originalPolicy.computationTicks,
          "original policy restored after deadline job");
#ifdef NAMRIG_VERIFY_POLICY_FAILURE
    check(policyCalls.load() == beforeDeadline + 2,
          "default submission restores policy exactly once");
#endif
    check(deadlineWorker.submit(increment, &deadlineCalls,
                               std::numeric_limits<uint64_t>::max()),
          "distant deadline accepted without uint32 overflow");
    deadlineWorker.wait();
    check(deadlineCalls == 1, "distant deadline executes exactly once");
#ifdef NAMRIG_VERIFY_POLICY_FAILURE
    check(policyCalls.load() == beforeDeadline + 2,
          "unchanged constraint skips redundant kernel call");
#endif
    constexpr unsigned kImmediateJobs = 4096;
#ifdef NAMRIG_VERIFY_HANDOFF
    const unsigned beforeHandoffs = handoffCalls.load();
    const unsigned beforeInterruptions = interruptedHandoffs.load();
    abortNextHandoff.store(true);
#endif
    for (unsigned i = 0; i < kImmediateJobs; ++i) {
      Result immediatePolicy;
      const uint64_t window = futureWindow / (i % 2 + 1);
      const uint64_t deadline = i % 3 == 0 ? 0 : mach_absolute_time() + window;
      check(deadlineWorker.submit(inspectScheduling, &immediatePolicy, deadline),
            "immediate resubmission with varying scheduling constraint");
      deadlineWorker.wait();
      check(immediatePolicy.calls == 1 && immediatePolicy.realTime &&
                immediatePolicy.periodTicks == originalPolicy.periodTicks,
            "immediate handoff completes exactly one job under original period");
      if (deadline == 0) {
        check(immediatePolicy.constraintTicks == originalPolicy.constraintTicks,
              "immediate default submission restores full constraint");
      } else {
        check(immediatePolicy.constraintTicks <= window &&
                  immediatePolicy.constraintTicks < originalPolicy.constraintTicks,
              "immediate deadline submission observes tightened constraint");
      }
    }
#ifdef NAMRIG_VERIFY_HANDOFF
    check(!abortNextHandoff.load() &&
              interruptedHandoffs.load() == beforeInterruptions + 1,
          "handoff interruption exercised after signaling completion");
    check(handoffCalls.load() == beforeHandoffs + kImmediateJobs,
          "interrupted handoff retries wake wait without duplicating completion");
#endif
    deadlineWorker.stop();
    std::printf("PASS: expired/short deadline rejection, tighter scheduling, default restore\n");
    std::printf("PASS: %u immediate resubmissions with varying scheduling constraints\n",
                kImmediateJobs);
  }

#ifdef NAMRIG_VERIFY_POLICY_FAILURE
  {
    CabinetWorker policyFailureWorker;
    check(policyFailureWorker.start(nullptr, 0.02), "start policy failure worker");
    unsigned unpublishedCalls = 0;
    const uint64_t futureWindow = UINT64_C(10000000) * timebase.denom / timebase.numer;
    failNextPolicy.store(true);
    check(!policyFailureWorker.submit(increment, &unpublishedCalls,
                                     mach_absolute_time() + futureWindow),
          "policy failure rejects before publication");
    check(!failNextPolicy.load(), "policy failure was injected");
    check(!policyFailureWorker.submit(increment, &unpublishedCalls),
          "policy failure rejects subsequent submissions");
    policyFailureWorker.wait();
    policyFailureWorker.stop();
    check(unpublishedCalls == 0, "policy failure never executes rejected job");
    check(policyFailureWorker.start(nullptr, kPeriod), "restart after policy failure");
    check(policyFailureWorker.submit(increment, &unpublishedCalls),
          "accept job after policy failure cleanup");
    policyFailureWorker.wait();
    policyFailureWorker.stop();
    check(unpublishedCalls == 1, "restarted worker completes exactly one job");
    std::printf("PASS: pre-publication caller-side policy update and failure injection\n");
  }
#endif

  os_workgroup_t group = os_workgroup_parallel_create("cabinet-worker-test", nullptr);
  check(group != nullptr, "create test workgroup");
  os_workgroup_cancel(group);
  check(!worker.start(static_cast<void*>(group), kPeriod),
        "cancelled workgroup join fails closed");
  check(!worker.submit(increment, &calls), "failed join stays serial");
  worker.stop();
  os_release(group);

  check(worker.start(nullptr, kPeriod), "start offline worker");
  check(!worker.start(nullptr, kPeriod), "double start rejected");
  check(!worker.submit(nullptr, &calls), "null callback rejected");
  Result scheduling;
  check(worker.submit(inspectScheduling, &scheduling), "submit scheduler check");
  worker.wait();
  check(scheduling.realTime, "time-constraint policy installed");
  {
    Gate gate;
    check(worker.submit(gatedJob, &gate), "submit gated job");
    gate.entered.wait();
    check(!worker.submit(increment, &calls), "running job rejects second submit");
    gate.release.signal();
    gate.finished.wait();
    check(!worker.submit(increment, &calls), "pending completion rejects submit");
    worker.wait();
    worker.wait();
    check(gate.calls == 1 && calls == 0, "rejected jobs never run");
  }

  constexpr unsigned kJobs = 12000;
  const int roundingModes[] = {FE_TONEAREST, FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO};
  for (unsigned i = 0; i < kJobs; ++i) {
    const std::fenv_t* base = FE_DFL_ENV;
    if ((i / 4) % 2 != 0) {
#if defined(__arm64__)
      base = FE_DFL_DISABLE_DENORMS_ENV;
#elif defined(__x86_64__)
      base = FE_DFL_DISABLE_SSE_DENORMS_ENV;
#endif
    }
    check(std::fesetenv(base) == 0, "set denormal mode");
    check(std::fesetround(roundingModes[i % 4]) == 0, "set rounding mode");
    check(std::feraiseexcept(FE_DIVBYZERO) == 0, "set exception flag");
    std::fenv_t submittedEnvironment;
    check(std::fegetenv(&submittedEnvironment) == 0, "capture submitted environment");
    Result serial;
    serial.seed = i + 1;
    calculate(&serial);
    check(std::fesetenv(&submittedEnvironment) == 0, "restore serial input state");
    Result parallel;
    parallel.seed = serial.seed;
    check(worker.submit(calculate, &parallel), "submit sustained job");
    // Change the caller's state before completion; the job must use the snapshot.
    check(std::fesetenv(FE_DFL_ENV) == 0, "change caller environment after submit");
    worker.wait();
    std::fenv_t afterWait;
    check(std::fegetenv(&afterWait) == 0, "capture caller state after wait");
    std::fenv_t defaultEnvironment;
    check(std::fesetenv(FE_DFL_ENV) == 0 &&
              std::fegetenv(&defaultEnvironment) == 0,
          "capture default state");
    check(sameEnvironment(afterWait, defaultEnvironment), "wait preserves caller fenv");
    check(parallel.hash == serial.hash, "sustained job result visibility");
    check(std::memcmp(parallel.values.data(), serial.values.data(),
                      sizeof(serial.values)) == 0,
          "bit-identical float results, including denormals");
    check(parallel.rounding == serial.rounding &&
              parallel.exceptions == serial.exceptions &&
              sameEnvironment(parallel.environment, serial.environment),
          "complete per-job floating-point environment matches");
  }
  worker.stop();
  check(!worker.submit(increment, &calls), "stopped worker returns serial fallback");
  std::printf("PASS: %u sustained jobs, all rounding/denormal modes, pending rejection\n",
              kJobs);

  for (unsigned i = 0; i < 100; ++i) {
    check(worker.start(nullptr, kPeriod), "restart worker");
    if (i % 2 == 0) {
      check(worker.submit(increment, &calls), "submit before stop");
      worker.stop();
      check(calls == i / 2 + 1, "stop drains published job");
    } else {
      worker.stop();  // Must wake an idle thread without timing assumptions.
    }
    worker.stop();
  }
  {
    CabinetWorker scoped;
    check(scoped.start(nullptr, kPeriod), "start destructor test");
    check(scoped.submit(increment, &calls), "submit before destructor");
  }
  check(calls == 51, "destructor drains and joins");

  group = os_workgroup_parallel_create("cabinet-worker-retain-test", nullptr);
  check(group != nullptr, "create live test workgroup");
  check(worker.start(static_cast<void*>(group), kPeriod), "join live workgroup");
  os_release(group);  // Only the worker's retained reference remains.
  check(worker.submit(increment, &calls), "submit in retained workgroup");
  worker.wait();
  worker.stop();
  check(calls == 52, "retained workgroup job completes");

  unsigned rejectedCalls = 0;
  group = os_workgroup_parallel_create("cabinet-worker-idle-cancel", nullptr);
  check(group != nullptr, "create idle cancellation workgroup");
  check(worker.start(static_cast<void*>(group), kPeriod),
        "start before idle cancellation");
  os_workgroup_cancel(group);
  check(!worker.submit(increment, &rejectedCalls),
        "idle cancellation rejects submission before publication");
  check(!worker.submit(increment, &rejectedCalls), "stopping worker rejects submission");
  worker.wait();
  os_release(group);
  worker.stop();

  for (unsigned mode = 0; mode < 3; ++mode) {
    group = os_workgroup_parallel_create("cabinet-worker-pending-cancel", nullptr);
    check(group != nullptr, "create pending cancellation workgroup");
    check(worker.start(static_cast<void*>(group), kPeriod),
          "start before pending cancellation");
    Gate gate;
    check(worker.submit(gatedJob, &gate), "publish job before cancellation");
    gate.entered.wait();
    os_workgroup_cancel(group);
    if (mode == 0)
      check(!worker.submit(increment, &rejectedCalls),
            "cancellation rejects submission while a job is pending");
    os_release(group);
    gate.release.signal();
    if (mode == 2) {
      worker.stop();
    } else {
      // Mode 1 makes no further submit: cancellation must be detected by the
      // worker itself, without losing the accepted job's completion signal.
      worker.wait();
      check(!worker.submit(increment, &rejectedCalls),
            "cancelled worker rejects submission after pending completion");
      worker.wait();
      worker.stop();
    }
    check(gate.calls == 1, "cancellation preserves exactly one pending completion");
    worker.stop();
  }
  check(rejectedCalls == 0, "post-start cancellation never executes rejected jobs");
  unsigned acceptedCalls = 0;
  for (unsigned i = 0; i < 64; ++i) {
    group = os_workgroup_parallel_create("cabinet-worker-republish-cancel", nullptr);
    check(group != nullptr, "create republish cancellation workgroup");
    check(worker.start(static_cast<void*>(group), kPeriod),
          "start before republish cancellation");
    check(worker.submit(increment, &acceptedCalls), "submit before immediate republish");
    worker.wait();
    check(worker.submit(increment, &acceptedCalls), "immediately republish accepted job");
    os_workgroup_cancel(group);
    check(!worker.submit(increment, &rejectedCalls),
          "cancellation after republish rejects new work");
    worker.stop();
    os_release(group);
    check(acceptedCalls == 2 * (i + 1) && rejectedCalls == 0,
          "stop preserves republished job even if not yet dispatched");
  }
  check(worker.start(nullptr, kPeriod), "restart after cancellation cleanup");
  worker.stop();
  std::printf("PASS: post-start cancellation, idle wakeup, pending completion and shutdown\n");

  check(std::fesetenv(&originalEnvironment) == 0, "restore original environment");
  std::printf("PASS: scheduler/workgroup handshake, 100 restarts, idle/pending shutdown, destructor\n");
  return 0;
}
