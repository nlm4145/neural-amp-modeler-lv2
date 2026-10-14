#include "standalone_worker.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <type_traits>

namespace {

void check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::abort();
  }
}

struct Event {
  std::mutex mutex;
  std::condition_variable cv;
  bool signaled = false;

  void signal() {
    std::lock_guard<std::mutex> lock(mutex);
    signaled = true;
    cv.notify_all();
  }

  bool waitFor(std::chrono::seconds timeout = std::chrono::seconds(3)) {
    std::unique_lock<std::mutex> lock(mutex);
    return cv.wait_for(lock, timeout, [this] { return signaled; });
  }

  void wait() { check(waitFor(), "event timeout"); }
};

}  // namespace

namespace NAMRig {

// Deterministic contention/idle synchronization without a production test API.
struct StandaloneWorkerTestAccess {
  static std::mutex& responseMutex(StandaloneWorker& worker) {
    return worker.responseMutex_;
  }

  static void waitIdle(StandaloneWorker& worker) {
    std::unique_lock<std::mutex> lock(worker.workerMutex_);
    check(worker.workerCV_.wait_for(lock, std::chrono::seconds(3), [&] {
      return worker.work_.empty() && !worker.working_;
    }), "worker idle timeout");
  }

  static bool joined(StandaloneWorker& worker) { return !worker.thread_.joinable(); }
};

}  // namespace NAMRig

namespace {

using NAMRig::StandaloneWorker;
using NAMRig::StandaloneWorkerTestAccess;

enum class Kind : uint32_t { Echo, Load, Free };

struct Message {
  Kind kind;
  uint32_t sequence;
  std::array<uint8_t, 5> bytes;
  int* owned;
};

struct FakePlugin {
  StandaloneWorker& worker;
  LV2_Worker_Schedule* schedule;
  std::thread::id audioThread = std::this_thread::get_id();
  std::thread::id responseThread = audioThread;
  std::thread::id workThread;
  std::atomic<bool> alive{true};
  std::vector<Message> dispatched;
  std::vector<Message> delivered;
  unsigned allocations = 0;
  unsigned frees = 0;
  int* pending = nullptr;
  bool adoptResponses = false;
  bool snapshotFollowup = false;
  bool shutdownFollowup = false;
  Event* workEntered = nullptr;
  Event* workRelease = nullptr;

  explicit FakePlugin(StandaloneWorker& queue)
      : worker(queue), schedule(queue.scheduleFeature()) {}

  ~FakePlugin() {
    check(StandaloneWorkerTestAccess::joined(worker), "join before instance destruction");
    check(allocations == frees + (pending ? 1u : 0u), "pointer-owning responses reclaimed or adopted");
    delete pending;
    alive = false;
  }

  void enqueue(Message message) {
    check(schedule->schedule_work(schedule->handle, sizeof(message), &message) ==
              LV2_WORKER_SUCCESS, "schedule success");
    // Neither the scheduling nor responding stack buffer may be retained.
    auto* bytes = reinterpret_cast<volatile unsigned char*>(&message);
    for (size_t i = 0; i < sizeof(message); ++i) bytes[i] = 0xA5;
  }

  static LV2_Worker_Status work(LV2_Handle instance,
                               LV2_Worker_Respond_Function respond,
                               LV2_Worker_Respond_Handle handle,
                               uint32_t size, const void* data) {
    auto& plugin = *static_cast<FakePlugin*>(instance);
    check(plugin.alive, "live instance during work");
    check(size == sizeof(Message), "work byte size");
    check(std::this_thread::get_id() != plugin.audioThread, "work/free never on audio thread");
    if (plugin.workThread == std::thread::id{})
      plugin.workThread = std::this_thread::get_id();
    check(plugin.workThread == std::this_thread::get_id(), "single worker dispatch thread");
    Message message;
    std::memcpy(&message, data, size);
    plugin.dispatched.push_back(message);
    if (plugin.workEntered && message.sequence == 1) {
      plugin.workEntered->signal();
      plugin.workRelease->wait();
    }
    if (message.kind == Kind::Free) {
      check(message.owned && *message.owned == static_cast<int>(message.sequence),
            "free owns original loaded object");
      delete message.owned;
      ++plugin.frees;
    } else {
      if (message.kind == Kind::Load) {
        message.owned = new int(static_cast<int>(message.sequence));
        ++plugin.allocations;
      }
      check(respond(handle, sizeof(message), &message) == LV2_WORKER_SUCCESS,
            "respond success");
      auto* bytes = reinterpret_cast<volatile unsigned char*>(&message);
      for (size_t i = 0; i < sizeof(message); ++i) bytes[i] = 0x5A;
    }
    return LV2_WORKER_SUCCESS;
  }

  static LV2_Worker_Status response(LV2_Handle instance, uint32_t size,
                                   const void* data) {
    auto& plugin = *static_cast<FakePlugin*>(instance);
    check(plugin.alive, "live instance during response");
    check(std::this_thread::get_id() == plugin.responseThread, "response on caller thread");
    check(std::this_thread::get_id() != plugin.workThread, "response not on worker thread");
    check(size == sizeof(Message), "response byte size");
    Message message;
    std::memcpy(&message, data, size);
    plugin.delivered.push_back(message);
    if (message.kind == Kind::Load) {
      if (plugin.adoptResponses) {
        if (plugin.pending)
          plugin.enqueue({Kind::Free, static_cast<uint32_t>(*plugin.pending), {}, plugin.pending});
        plugin.pending = message.owned;
      } else {
        message.kind = Kind::Free;
        plugin.enqueue(message);
      }
      if (plugin.shutdownFollowup && message.sequence == 1)
        plugin.enqueue({Kind::Load, 3, {9, 8, 7, 6, 5}, nullptr});
    }
    if (plugin.snapshotFollowup && message.sequence == 1) {
      plugin.enqueue({Kind::Echo, 3, {9, 8, 7, 6, 5}, nullptr});
      // If applyResponses still held its mutex, respond would deadlock here.
      StandaloneWorkerTestAccess::waitIdle(plugin.worker);
    }
    return LV2_WORKER_SUCCESS;
  }

  static LV2_Worker_Interface callbacks() { return {work, response, nullptr}; }
};

void verifyCopiesFIFOAndSnapshot() {
  StandaloneWorker worker;
  FakePlugin plugin(worker);
  auto* feature = worker.scheduleFeature();
  check(feature->handle == &worker && feature->schedule_work, "configured feature before initialize");
  check(feature->schedule_work(feature->handle, 0, "x") == LV2_WORKER_ERR_UNKNOWN,
        "reject empty work as before");
  check(feature->schedule_work(feature->handle, 1, nullptr) == LV2_WORKER_ERR_UNKNOWN,
        "reject null work as before");
  worker.stop();
  const Message first{Kind::Echo, 1, {0, 0xFF, 2, 0, 4}, nullptr};
  const Message second{Kind::Echo, 2, {5, 4, 3, 2, 1}, nullptr};
  plugin.enqueue(first);
  plugin.enqueue(second);
  check(!worker.start(nullptr, FakePlugin::callbacks()), "reject null instance without discarding queue");
  check(!worker.start(&plugin, {nullptr, FakePlugin::response, nullptr}), "reject absent work callback");
  check(!worker.start(&plugin, {FakePlugin::work, nullptr, nullptr}), "reject absent response callback");
  auto callbacks = FakePlugin::callbacks();
  check(worker.start(&plugin, callbacks), "start after initialization");
  callbacks = {}; // The class must not borrow this interface object.
  check(!worker.start(&plugin, FakePlugin::callbacks()), "duplicate start leaves worker intact");
  StandaloneWorkerTestAccess::waitIdle(worker);
  check(plugin.dispatched.size() == 2 && plugin.delivered.empty(), "queued work, deferred responses");
  check(plugin.dispatched[0].sequence == 1 && plugin.dispatched[1].sequence == 2,
        "FIFO work dispatch");
  check(plugin.dispatched[0].bytes == first.bytes && plugin.dispatched[1].bytes == second.bytes,
        "schedule copies exact bytes including zeros");
  plugin.snapshotFollowup = true;
  worker.applyResponses();
  check(plugin.delivered.size() == 2 && plugin.delivered[0].sequence == 1 &&
            plugin.delivered[1].sequence == 2, "FIFO response snapshot excludes new responses");
  check(plugin.delivered[0].bytes == first.bytes && plugin.delivered[1].bytes == second.bytes,
        "respond copies bytes before returning");
  worker.applyResponses();
  check(plugin.delivered.size() == 3 && plugin.delivered[2].sequence == 3,
        "followup response delivered on next audio call");
  worker.stop();
  worker.stop();
  check(feature == worker.scheduleFeature(), "feature stable after stop");
  plugin.workThread = {};
  plugin.enqueue({Kind::Echo, 4, {1, 2, 3, 4, 5}, nullptr});
  check(worker.start(&plugin, FakePlugin::callbacks()), "restart after stop");
  worker.stop();
  check(plugin.dispatched.size() == 4 && plugin.delivered.size() == 4 &&
            plugin.delivered.back().sequence == 4, "restart drains without discarded responses");
}

void verifyNonblockingResponses() {
  StandaloneWorker worker;
  FakePlugin plugin(worker);
  check(worker.start(&plugin, FakePlugin::callbacks()), "contention start");
  plugin.enqueue({Kind::Echo, 1, {1, 2, 3, 4, 5}, nullptr});
  StandaloneWorkerTestAccess::waitIdle(worker);
  Event locked, release, returned;
  std::thread holder([&] {
    std::lock_guard<std::mutex> lock(StandaloneWorkerTestAccess::responseMutex(worker));
    locked.signal();
    release.wait();
  });
  locked.wait();
  std::thread audio([&] {
    worker.applyResponses();
    returned.signal();
  });
  returned.wait(); // Must return while another thread still owns the mutex.
  audio.join();
  check(plugin.delivered.empty(), "contended response snapshot remains queued");
  release.signal();
  holder.join();
  worker.applyResponses();
  check(plugin.delivered.size() == 1, "retry delivers retained response");
  worker.stop();
}

void verifyShutdownOwnershipAndJoin() {
  StandaloneWorker worker;
  FakePlugin plugin(worker);
  Event entered, release, stopping, stopped;
  plugin.workEntered = &entered;
  plugin.workRelease = &release;
  plugin.shutdownFollowup = true;
  plugin.enqueue({Kind::Load, 1, {1, 2, 3, 4, 5}, nullptr});
  plugin.enqueue({Kind::Load, 2, {5, 4, 3, 2, 1}, nullptr});
  check(worker.start(&plugin, FakePlugin::callbacks()), "shutdown start");
  entered.wait();
  std::thread shutdown([&] {
    plugin.responseThread = std::this_thread::get_id();
    stopping.signal();
    worker.stop();
    check(StandaloneWorkerTestAccess::joined(worker), "stop joined worker");
    worker.stop();
    stopped.signal();
  });
  stopping.wait();
  release.signal();
  stopped.wait();
  shutdown.join();
  check(plugin.dispatched.size() == 6, "shutdown drains loads and response-scheduled frees/loads");
  const uint32_t expected[] = {1, 2, 1, 3, 2, 3};
  for (size_t i = 0; i < plugin.dispatched.size(); ++i)
    check(plugin.dispatched[i].sequence == expected[i], "shutdown work stays FIFO");
  check(plugin.delivered.size() == 3 && plugin.delivered[0].sequence == 1 &&
            plugin.delivered[1].sequence == 2 && plugin.delivered[2].sequence == 3,
        "shutdown delivers all pointer-owning responses");
  check(plugin.allocations == 3 && plugin.frees == 3, "free callbacks complete before stop returns");
  worker.stop();
}

void verifyShutdownPendingOwnership() {
  StandaloneWorker worker;
  FakePlugin plugin(worker);
  plugin.adoptResponses = true;
  plugin.enqueue({Kind::Load, 1, {1, 2, 3, 4, 5}, nullptr});
  plugin.enqueue({Kind::Load, 2, {5, 4, 3, 2, 1}, nullptr});
  check(worker.start(&plugin, FakePlugin::callbacks()), "pending ownership start");
  worker.stop();
  check(plugin.allocations == 2 && plugin.frees == 1 && plugin.pending && *plugin.pending == 2,
        "shutdown frees superseded response and retains latest for instance destructor");
  check(plugin.delivered.size() == 2 && plugin.dispatched.size() == 3 &&
            plugin.dispatched.back().kind == Kind::Free,
        "adopted response cleanup drains before join");
}

}  // namespace

int main() {
  static_assert(!std::is_copy_constructible<StandaloneWorker>::value, "stable feature handle");
  static_assert(!std::is_move_constructible<StandaloneWorker>::value, "stable feature handle");
  Event finished;
  std::thread watchdog([&] {
    check(finished.waitFor(std::chrono::seconds(20)), "test watchdog timeout");
  });
  verifyCopiesFIFOAndSnapshot();
  verifyNonblockingResponses();
  verifyShutdownOwnershipAndJoin();
  verifyShutdownPendingOwnership();
  finished.signal();
  watchdog.join();
  std::puts("Standalone worker checks passed");
}
