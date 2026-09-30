#pragma once

#include <atomic>
#include <cfenv>
#include <cstdint>
#include <thread>

#include <mach/mach_types.h>

namespace NAMRig {

// macOS 11+. start/stop are non-real-time and must not overlap submit/wait.
// Stop CoreAudio callbacks, then stop this worker before changing or disposing
// the audio workgroup/device. A null group is for offline harnesses only.
// One caller owns submit/wait; a successful submit must be followed by wait
// before reusing the context or submitting again. stop also drains a pending
// job. Callbacks must be bounded, real-time safe, and must not call this worker.
class CabinetWorker {
 public:
  CabinetWorker() = default;
  ~CabinetWorker() { stop(); }
  CabinetWorker(const CabinetWorker&) = delete;
  CabinetWorker& operator=(const CabinetWorker&) = delete;

  // Requires a stopped worker. Failure leaves it stopped (or an already
  // started worker unchanged); no processing thread is created on the RT path.
  // Pass an os_workgroup_t as void* (under ARC: (__bridge void*)group).
  // The pure C++ implementation retains it until stop; ownership is not transferred.
  bool start(void* workgroup, double periodSeconds) noexcept;
  void stop() noexcept;

  // False means nothing was published: the caller may process serially.
  // Workgroup cancellation rejects new jobs and stops the worker; any job
  // already published still completes. Call stop before attempting a restart.
  // deadlineTicks is an absolute mach_absolute_time deadline; zero uses the
  // original period. Expired or <100us windows are rejected before publication.
  // Worker scheduling is best effort, not proof that deadlines cannot be missed;
  // a late-dispatched job still completes. Policy failure rejects the unpublished
  // job and subsequent submissions until stop/restart.
  // submit/wait allocate nothing, take no locks, and use lock-free atomics,
  // workgroup/clock queries, and Mach semaphores. When the constraint changes,
  // submit makes a thread_policy_set kernel call before waking the helper.
  // This experimental scheduling overhead may be high; no heap/mutex is used.
  // Normal completion uses Darwin's wait-before-signal handoff to register the
  // next wake wait before notifying the caller. Interrupted waits retry only
  // the wake wait; startup/interruption still have best-effort scheduling.
  // Once published, wait has no timeout or serial fallback.
  bool submit(void (*process)(void*) noexcept, void* context,
              uint64_t deadlineTicks = 0) noexcept;
  void wait() noexcept;

 private:
  enum class JobState : uint8_t { Idle, Published, Complete };
  static_assert(std::atomic<JobState>::is_always_lock_free,
                "The job state must be lock-free");
  static_assert(std::atomic<bool>::is_always_lock_free,
                "The control flags must be lock-free");

  void run(uint32_t periodTicks) noexcept;

  std::thread thread_;
  semaphore_t wake_ = MACH_PORT_NULL;
  semaphore_t completion_ = MACH_PORT_NULL;
  void* group_ = nullptr;
  bool started_ = false;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> setupSucceeded_{false};
  std::atomic<JobState> state_{JobState::Idle};
  void (*process_)(void*) noexcept = nullptr;
  void* context_ = nullptr;
  // Scheduling cache is owned by start/submit/stop, never the worker loop.
  thread_t helperThread_ = MACH_PORT_NULL;  // Borrowed from the live pthread.
  uint32_t periodTicks_ = 0;
  uint32_t computationTicks_ = 0;
  uint32_t policyConstraint_ = 0;
  uint64_t minimumWindowTicks_ = 0;
  std::fenv_t environment_{};
};

}  // namespace NAMRig
