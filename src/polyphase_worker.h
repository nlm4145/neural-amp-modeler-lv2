#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <NeuralAudio/PolyphaseModel.h>
#include <NeuralAudio/CompositeModel.h>
#include "cabinet_worker.h"

namespace NAMRig {

// One audio callback owns this pool. Start/stop only with audio stopped.
// Reuses the workgroup, deadline, fenv and completion guarantees of CabinetWorker.
class PolyphaseWorker final : public NeuralAudio::PolyphaseModel::Executor {
 public:
  static constexpr size_t kMaxHelpers = 3;

  bool start(void* workgroup, double periodSeconds, size_t helperCount) noexcept {
#if defined(__APPLE__) || defined(_WIN32)
    if (helperCount_ != 0) return false;
    const size_t requested = std::min(helperCount, kMaxHelpers);
    for (; helperCount_ < requested; ++helperCount_)
      if (!workers_[helperCount_].start(workgroup, periodSeconds)) break;
    return helperCount_ != 0;
#else
    return false;
#endif
  }

  void stop() noexcept {
#if defined(__APPLE__) || defined(_WIN32)
    for (auto& worker : workers_) worker.stop();
#endif
    helperCount_ = 0;
    deadline_ = 0;
  }

  size_t helperCount() const noexcept { return helperCount_; }
  void setDeadline(uint64_t deadline) noexcept { deadline_ = deadline; }

  void process(NeuralAudio::NeuralModel* model, float* input, float* output,
               size_t count) noexcept {
    auto* current = model;
    // Packed A2 models select a child graph by quality. Resolve once before
    // dispatch; neither selection nor graph ownership changes during this call.
    while (auto* composite = dynamic_cast<NeuralAudio::CompositeModel*>(current)) {
      current = composite->GetCurrentModel();
      if (!current) break;
    }
    if (auto* poly = dynamic_cast<NeuralAudio::PolyphaseModel*>(current))
      poly->ProcessWithExecutor(input, output, count, this);
    else
      model->Process(input, output, count);
  }

  void execute(void (*process)(void*, size_t, size_t) noexcept, void* context,
               size_t phaseCount, size_t minimumPhaseSamples) noexcept override {
    if (phaseCount == 0) return;
#if defined(__APPLE__) || defined(_WIN32)
    // Kernel wake/wait overhead dominates very short native-rate phase blocks.
    const size_t helpers = phaseCount > 1 && minimumPhaseSamples >= 32
        ? std::min(helperCount_, phaseCount - 1) : 0;
    struct Job {
      void (*process)(void*, size_t, size_t) noexcept;
      void* context;
      size_t begin, end;
      bool published;
    };
    std::array<Job, kMaxHelpers> jobs{};
    for (size_t i = 0; i < helpers; ++i) {
      auto& job = jobs[i];
      job = {process, context, phaseCount * i / (helpers + 1),
             phaseCount * (i + 1) / (helpers + 1), false};
      job.published = workers_[i].submit([](void* context) noexcept {
        auto& job = *static_cast<Job*>(context);
        job.process(job.context, job.begin, job.end);
      }, &job, deadline_);
    }
    process(context, phaseCount * helpers / (helpers + 1), phaseCount);
    for (size_t i = 0; i < helpers; ++i) {
      auto& job = jobs[i];
      // Rejected jobs were never published. Never retry stateful DSP after a
      // successful submit, even if its completion misses the audio deadline.
      if (!job.published) process(context, job.begin, job.end);
    }
    for (size_t i = 0; i < helpers; ++i)
      if (jobs[i].published) workers_[i].wait();
#else
    process(context, 0, phaseCount);
#endif
  }

 private:
#if defined(__APPLE__) || defined(_WIN32)
  std::array<CabinetWorker, kMaxHelpers> workers_;
#endif
  size_t helperCount_ = 0;
  uint64_t deadline_ = 0;
};

}  // namespace NAMRig
