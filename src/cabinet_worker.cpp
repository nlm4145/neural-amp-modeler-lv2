#include "cabinet_worker.h"

#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <mach/thread_policy.h>
#include <os/workgroup.h>
#include <pthread.h>

namespace NAMRig {
namespace {

kern_return_t waitSemaphore(semaphore_t semaphore) noexcept {
  kern_return_t result;
  do {
    result = semaphore_wait(semaphore);
  } while (result == KERN_ABORTED);
  return result;
}

void signalSemaphore(semaphore_t semaphore) noexcept {
  // With live, privately owned semaphores this cannot fail. Never report a
  // published job as rejected or let its caller reuse an unfinished context.
  if (semaphore_signal(semaphore) != KERN_SUCCESS) std::terminate();
}

}  // namespace

bool CabinetWorker::start(void* workgroup, double periodSeconds) noexcept {
  if (started_ || thread_.joinable()) return false;
  if (!std::isfinite(periodSeconds) || periodSeconds <= 0.0) return false;

  mach_timebase_info_data_t timebase{};
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0 ||
      timebase.denom == 0)
    return false;
  const long double ticks = static_cast<long double>(periodSeconds) * 1.0e9L *
                            timebase.denom / timebase.numer;
  if (!std::isfinite(ticks) || ticks < 1.0L ||
      ticks > std::numeric_limits<uint32_t>::max())
    return false;
  const uint32_t periodTicks = static_cast<uint32_t>(ticks);
  // Cache the timebase-scaled 100us window, rounded up without FP conversions
  // on the submission path. uint32 timebase fields keep this product in uint64.
  minimumWindowTicks_ = (UINT64_C(100000) * timebase.denom + timebase.numer - 1) /
                        timebase.numer;

  if (semaphore_create(mach_task_self(), &wake_, SYNC_POLICY_FIFO, 0) !=
          KERN_SUCCESS ||
      semaphore_create(mach_task_self(), &completion_, SYNC_POLICY_FIFO, 0) !=
          KERN_SUCCESS) {
    stop();
    return false;
  }
  group_ = workgroup;
  if (group_) os_retain(static_cast<os_workgroup_t>(group_));

  try {
    thread_ = std::thread(&CabinetWorker::run, this, periodTicks);
  } catch (...) {
    stop();
    return false;
  }
  // The completion semaphore doubles as a startup handshake, consumed before
  // submit is enabled. Membership and scheduling failures stay off the RT path.
  if (waitSemaphore(completion_) != KERN_SUCCESS ||
      !setupSucceeded_.load(std::memory_order_acquire)) {
    stop();
    return false;
  }
  helperThread_ = pthread_mach_thread_np(thread_.native_handle());
  if (helperThread_ == MACH_PORT_NULL) {
    stop();
    return false;
  }
  periodTicks_ = periodTicks;
  computationTicks_ = periodTicks > 1 ? periodTicks / 2 : 1;
  policyConstraint_ = periodTicks;
  started_ = true;
  return true;
}

void CabinetWorker::stop() noexcept {
  wait();
  started_ = false;
  if (thread_.joinable()) {
    stopping_.store(true, std::memory_order_release);
    signalSemaphore(wake_);
    thread_.join();
  }
  if (completion_ != MACH_PORT_NULL) {
    semaphore_destroy(mach_task_self(), completion_);
    completion_ = MACH_PORT_NULL;
  }
  if (wake_ != MACH_PORT_NULL) {
    semaphore_destroy(mach_task_self(), wake_);
    wake_ = MACH_PORT_NULL;
  }
  if (group_) {
    os_release(static_cast<os_workgroup_t>(group_));
    group_ = nullptr;
  }
  process_ = nullptr;
  context_ = nullptr;
  helperThread_ = MACH_PORT_NULL;
  periodTicks_ = 0;
  computationTicks_ = 0;
  policyConstraint_ = 0;
  minimumWindowTicks_ = 0;
  state_.store(JobState::Idle, std::memory_order_relaxed);
  setupSucceeded_.store(false, std::memory_order_relaxed);
  stopping_.store(false, std::memory_order_relaxed);
}

bool CabinetWorker::submit(void (*process)(void*) noexcept,
                           void* context, uint64_t deadlineTicks) noexcept {
  if (!started_ || stopping_.load(std::memory_order_acquire)) return false;
  const auto group = static_cast<os_workgroup_t>(group_);
  if (group && os_workgroup_testcancel(group)) {
    stopping_.store(true, std::memory_order_release);
    signalSemaphore(wake_);
    return false;
  }
  if (!process || state_.load(std::memory_order_acquire) != JobState::Idle)
    return false;
  std::fenv_t environment;
  if (std::fegetenv(&environment) != 0) return false;
  uint32_t constraint = periodTicks_;
  if (deadlineTicks != 0) {
    const uint64_t now = mach_absolute_time();
    if (deadlineTicks <= now || deadlineTicks - now < minimumWindowTicks_)
      return false;
    constraint = static_cast<uint32_t>(
        std::min<uint64_t>(periodTicks_, deadlineTicks - now));
    if (constraint < minimumWindowTicks_) return false;
  }
  if (constraint != policyConstraint_) {
    thread_time_constraint_policy_data_t policy{};
    policy.period = periodTicks_;
    policy.computation = std::max<uint32_t>(
        1, std::min(computationTicks_, constraint / 2));
    policy.constraint = constraint;
    policy.preemptible = TRUE;
    // XNU assigns the scheduling deadline on semaphore unblock using the
    // target's current constraint, so install it before publication/wakeup.
    if (thread_policy_set(helperThread_, THREAD_TIME_CONSTRAINT_POLICY,
                          reinterpret_cast<thread_policy_t>(&policy),
                          THREAD_TIME_CONSTRAINT_POLICY_COUNT) != KERN_SUCCESS) {
      stopping_.store(true, std::memory_order_release);
      signalSemaphore(wake_);
      return false;
    }
    policyConstraint_ = constraint;
  }

  process_ = process;
  context_ = context;
  environment_ = environment;
  state_.store(JobState::Published, std::memory_order_release);
  signalSemaphore(wake_);
  return true;
}

void CabinetWorker::wait() noexcept {
  if (state_.load(std::memory_order_acquire) == JobState::Idle) return;
  if (waitSemaphore(completion_) != KERN_SUCCESS ||
      state_.load(std::memory_order_acquire) != JobState::Complete)
    std::terminate();
  state_.store(JobState::Idle, std::memory_order_release);
}

void CabinetWorker::run(uint32_t periodTicks) noexcept {
  // Startup installs the original budget; submit adjusts it on this thread's
  // Mach port before publishing/waking each job with a different constraint.
  const uint32_t computationTicks = periodTicks > 1 ? periodTicks / 2 : 1;
  thread_time_constraint_policy_data_t policy{};
  policy.period = periodTicks;
  policy.computation = computationTicks;
  policy.constraint = periodTicks;
  policy.preemptible = TRUE;
  bool ready = thread_policy_set(
                   pthread_mach_thread_np(pthread_self()),
                   THREAD_TIME_CONSTRAINT_POLICY,
                   reinterpret_cast<thread_policy_t>(&policy),
                   THREAD_TIME_CONSTRAINT_POLICY_COUNT) == KERN_SUCCESS;
  os_workgroup_join_token_s token{};
  const auto group = static_cast<os_workgroup_t>(group_);
  bool joined = false;
  if (ready && group) {
    joined = os_workgroup_join(group, &token) == 0;
    ready = joined;
  }
  std::fenv_t initialEnvironment;
  if (ready)
    ready = std::fegetenv(&initialEnvironment) == 0 &&
            std::fesetenv(&initialEnvironment) == 0;
  setupSucceeded_.store(ready, std::memory_order_release);
  signalSemaphore(completion_);

  if (ready) {
    if (waitSemaphore(wake_) != KERN_SUCCESS) std::terminate();
    for (;;) {
      // Cancellation can wake us with an already published job. Complete it
      // before honoring shutdown so wait never loses its completion signal.
      if (state_.load(std::memory_order_acquire) != JobState::Published) {
        if (stopping_.load(std::memory_order_acquire)) break;
        std::terminate();
      }
      // Restore every job's complete environment, including rounding, exception
      // flags, and the architecture's denormal controls, not just startup state.
      if (std::fesetenv(&environment_) != 0) std::terminate();
      process_(context_);
      // Decide cancellation before publishing completion: a waiter can submit
      // again immediately, so it must see stopping before the worker can exit.
      if (group && os_workgroup_testcancel(group))
        stopping_.store(true, std::memory_order_release);
      const bool stopping = stopping_.load(std::memory_order_acquire);
      state_.store(JobState::Complete, std::memory_order_release);
      if (stopping) {
        signalSemaphore(completion_);
        break;
      }
      // XNU registers the wake wait before signaling completion. Immediate
      // resubmission then unblocks that wait with the newly installed policy,
      // even if the helper has not physically switched off its CPU yet.
      kern_return_t result = semaphore_wait_signal(wake_, completion_);
      // Completion was already signaled, including on an interrupted wait.
      // Retrying wait_signal would duplicate it; only retry the wake wait.
      if (result == KERN_ABORTED) result = waitSemaphore(wake_);
      if (result != KERN_SUCCESS) std::terminate();
    }
  }
  if (joined) os_workgroup_leave(group, &token);
}

}  // namespace NAMRig
