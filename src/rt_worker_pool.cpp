#include "rt_worker_pool.h"

#include "nam_rig_plugin.h"

#if defined(__APPLE__)

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <mach/mach.h>
#include <mach/semaphore.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>
#include <thread>
#include <vector>

namespace NAMRig {
namespace {

// Fixed-capacity process-wide pool. The host audio callback performs only
// bounded atomic operations, plain stores, and semaphore_signal: no locks,
// allocation, or condition variables.
class SharedRtPool final : public RealtimeJobDispatcher {
 public:
  SharedRtPool() {
    if (semaphore_create(mach_task_self(), &wake_, SYNC_POLICY_FIFO, 0) !=
        KERN_SUCCESS)
      return;

    size_t bytes = sizeof(uint32_t);
    uint32_t performanceCores = 0;
    if (sysctlbyname("hw.perflevel0.physicalcpu", &performanceCores, &bytes,
                     nullptr, 0) != 0 || performanceCores == 0)
      performanceCores = std::max(2u, std::thread::hardware_concurrency());
    const uint32_t count = std::max(1u, std::min<uint32_t>(
        static_cast<uint32_t>(kMaxPhaseCount - 1), performanceCores - 1));
    workers_.reserve(count);
    for (uint32_t i = 0; i < count; ++i)
      workers_.emplace_back([this] { workerLoop(); });
  }

  ~SharedRtPool() override {
    stopping_.store(true, std::memory_order_release);
    for (size_t i = 0; i < workers_.size(); ++i)
      semaphore_signal(wake_);
    for (auto& worker : workers_)
      if (worker.joinable()) worker.join();
    if (wake_ != SEMAPHORE_NULL)
      semaphore_destroy(mach_task_self(), wake_);
  }

  bool tryPublish(void (*function)(void*), void* context) noexcept override {
    if (!function || wake_ == SEMAPHORE_NULL || workers_.empty()) return false;
    const uint32_t start = cursor_.fetch_add(1, std::memory_order_relaxed);
    for (uint32_t offset = 0; offset < kSlotCount; ++offset) {
      Slot& slot = slots_[(start + offset) % kSlotCount];
      uint32_t expected = kFree;
      if (!slot.state.compare_exchange_strong(expected, kClaimed,
                                               std::memory_order_acquire,
                                               std::memory_order_relaxed))
        continue;
      slot.function = function;
      slot.context = context;
      slot.state.store(kReady, std::memory_order_release);
      semaphore_signal(wake_);
      return true;
    }
    return false;
  }

 private:
  static constexpr uint32_t kSlotCount = 64;
  static constexpr uint32_t kFree = 0;
  static constexpr uint32_t kClaimed = 1;
  static constexpr uint32_t kReady = 2;
  static constexpr uint32_t kRunning = 3;

  struct alignas(64) Slot {
    std::atomic<uint32_t> state{kFree};
    void (*function)(void*) = nullptr;
    void* context = nullptr;
  };

  void workerLoop() noexcept {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    while (!stopping_.load(std::memory_order_acquire)) {
      semaphore_wait(wake_);
      if (stopping_.load(std::memory_order_acquire)) return;
      for (auto& slot : slots_) {
        uint32_t expected = kReady;
        if (!slot.state.compare_exchange_strong(expected, kRunning,
                                                 std::memory_order_acquire,
                                                 std::memory_order_relaxed))
          continue;
        slot.function(slot.context);
        slot.state.store(kFree, std::memory_order_release);
        break;
      }
    }
  }

  std::array<Slot, kSlotCount> slots_{};
  std::atomic<uint32_t> cursor_{0};
  std::atomic<bool> stopping_{false};
  semaphore_t wake_ = SEMAPHORE_NULL;
  std::vector<std::thread> workers_;
};

}  // namespace

RealtimeJobDispatcher* sharedRealtimeJobDispatcher() noexcept {
  static SharedRtPool pool;
  return &pool;
}

}  // namespace NAMRig

#else

namespace NAMRig {

RealtimeJobDispatcher* sharedRealtimeJobDispatcher() noexcept {
  return nullptr;
}

}  // namespace NAMRig

#endif
