#include "standalone_worker.h"

#include <cstring>
#include <utility>

namespace NAMRig {

StandaloneWorker::StandaloneWorker() : schedule_{this, scheduleWork} {}

bool StandaloneWorker::start(LV2_Handle instance,
                              const LV2_Worker_Interface& callbacks) {
  if (thread_.joinable() || !instance || !callbacks.work || !callbacks.work_response)
    return false;
  instance_ = instance;
  interface_ = callbacks;
  stopping_ = false;
  thread_ = std::thread([this] { workerLoop(); });
  return true;
}

void StandaloneWorker::stop() noexcept {
  if (!thread_.joinable()) return;
  for (;;) {
    std::deque<Message> local;
    {
      std::unique_lock<std::mutex> lock(workerMutex_);
      workerCV_.wait(lock, [this] { return work_.empty() && !working_; });
      // The worker is idle, and no external producer may race shutdown.
      std::lock_guard<std::mutex> responseLock(responseMutex_);
      if (responses_.empty()) {
        stopping_ = true;
        break;
      }
      local.swap(responses_);
    }
    for (const auto& response : local)
      interface_.work_response(instance_, static_cast<uint32_t>(response.size()),
                               response.data());
  }
  workerCV_.notify_one();
  thread_.join();
  instance_ = nullptr;
}

LV2_Worker_Status StandaloneWorker::scheduleWork(LV2_Worker_Schedule_Handle handle,
                                                uint32_t size, const void* data) {
  if (!data || !size) return LV2_WORKER_ERR_UNKNOWN;
  auto* worker = static_cast<StandaloneWorker*>(handle);
  Message item(size);
  std::memcpy(item.data(), data, size);
  {
    std::lock_guard<std::mutex> lock(worker->workerMutex_);
    worker->work_.push_back(std::move(item));
  }
  // Shutdown also waits on this CV while responses can schedule more work.
  worker->workerCV_.notify_all();
  return LV2_WORKER_SUCCESS;
}

LV2_Worker_Status StandaloneWorker::respondWork(LV2_Worker_Respond_Handle handle,
                                               uint32_t size, const void* data) {
  auto* worker = static_cast<StandaloneWorker*>(handle);
  Message response(size);
  if (size) std::memcpy(response.data(), data, size);
  std::lock_guard<std::mutex> lock(worker->responseMutex_);
  worker->responses_.push_back(std::move(response));
  return LV2_WORKER_SUCCESS;
}

void StandaloneWorker::workerLoop() {
  for (;;) {
    Message item;
    {
      std::unique_lock<std::mutex> lock(workerMutex_);
      workerCV_.wait(lock, [this] { return stopping_ || !work_.empty(); });
      if (stopping_ && work_.empty()) return;
      item = std::move(work_.front());
      work_.pop_front();
      working_ = true;
    }
    interface_.work(instance_, respondWork, this,
                    static_cast<uint32_t>(item.size()), item.data());
    {
      std::lock_guard<std::mutex> lock(workerMutex_);
      working_ = false;
    }
    workerCV_.notify_all();
  }
}

void StandaloneWorker::applyResponses() noexcept {
  if (!responseMutex_.try_lock()) return;
  std::deque<Message> local;
  local.swap(responses_);
  responseMutex_.unlock();
  for (const auto& response : local)
    interface_.work_response(instance_, static_cast<uint32_t>(response.size()),
                             response.data());
}

}  // namespace NAMRig
