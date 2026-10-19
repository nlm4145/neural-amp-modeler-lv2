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

  // Short blocks can still contain substantial work when many independent
  // phases are grouped per thread. Keep tiny phase blocks serial, and require
  // at least 64 native-rate samples per range below the old 32-sample cutoff.
  static size_t helpersFor(size_t available, size_t phases, size_t samples) noexcept {
    if (phases < 2 || samples < 16) return 0;
    const size_t limit = std::min({available, kMaxHelpers, phases - 1});
    if (samples >= 32) return limit;
    const size_t phasesPerRange = (64 + samples - 1) / samples;
    const size_t ranges = phases / phasesPerRange;
    return ranges > 1 ? std::min(limit, ranges - 1) : 0;
  }

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
    const size_t helpers = helpersFor(helperCount_, phaseCount, minimumPhaseSamples);
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
      // The deadline only gates admission here. Several stages submit per
      // callback with shrinking deadlines; a fixed helper constraint avoids a
      // thread_policy_set kernel call on every submission.
      job.published = workers_[i].submitFixedConstraint([](void* context) noexcept {
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
