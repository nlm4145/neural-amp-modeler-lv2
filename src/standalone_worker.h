#pragma once

#include <lv2/worker/worker.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

namespace NAMRig {

// Owns the byte queues, not the plugin or objects referenced by messages.
// The stable schedule feature is available before Plugin::initialize; requests
// queued during initialization require a subsequent successful start to drain.
class StandaloneWorker {
 public:
  StandaloneWorker();
  ~StandaloneWorker() { stop(); }
  StandaloneWorker(const StandaloneWorker&) = delete;
  StandaloneWorker& operator=(const StandaloneWorker&) = delete;

  LV2_Worker_Schedule* scheduleFeature() noexcept { return &schedule_; }

  // Non-audio lifecycle calls must not overlap each other or applyResponses.
  // applyResponses is valid only between a successful start and stop.
  // The instance must remain alive until stop returns. Copies the callbacks;
  // end_run, if needed, remains the audio host's responsibility.
  bool start(LV2_Handle instance, const LV2_Worker_Interface& callbacks);

  // Call only after audio and external scheduling have stopped. Drains work
  // and delivers remaining responses here, while the worker is still available
  // for response-scheduled loads/frees, then joins. Callbacks must eventually
  // stop scheduling more work. Idempotent; start may be called again afterward.
  void stop() noexcept;

  // Audio caller only: try_lock, swap one snapshot, unlock, then callbacks.
  // Retains the old queues' allocation and scheduling-mutex behavior.
  void applyResponses() noexcept;

 private:
  friend struct StandaloneWorkerTestAccess;
  using Message = std::vector<uint8_t>;

  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                       uint32_t size, const void* data);
  static LV2_Worker_Status respondWork(LV2_Worker_Respond_Handle handle,
                                      uint32_t size, const void* data);
  void workerLoop();

  LV2_Worker_Schedule schedule_;
  LV2_Handle instance_ = nullptr;
  LV2_Worker_Interface interface_{};
  std::thread thread_;
  std::mutex workerMutex_;
  std::condition_variable workerCV_;
  std::deque<Message> work_;
  bool stopping_ = false;
  bool working_ = false;
  std::mutex responseMutex_;
  std::deque<Message> responses_;
};

}  // namespace NAMRig
