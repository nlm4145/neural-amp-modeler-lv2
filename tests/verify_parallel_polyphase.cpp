// macOS offline verification of the PolyphaseWorker executor on real NAM models.
// Usage: verify_parallel_polyphase [--benchmark]
// For deterministic partial-publication coverage, compile this file AND
// cabinet_worker.cpp with NAMRIG_VERIFY_POLYPHASE_POLICY_FAILURE and
// thread_policy_set=verifyPolyphasePolicySet (see the suggested CMake target).

#include "polyphase_worker.h"

#include <NeuralAudio/CompositeModel.h>
#include <NeuralAudio/NeuralModel.h>
#include <NeuralAudio/PolyphaseModel.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <filesystem>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

#if !defined(__APPLE__)
#error This harness requires the macOS CabinetWorker implementation
#endif
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>

#ifndef NAM_REPO_DIR
#error Define NAM_REPO_DIR to the repository root
#endif

#ifdef NAMRIG_VERIFY_POLYPHASE_POLICY_FAILURE
#include <dlfcn.h>

namespace {
std::atomic<unsigned> policyFailureCountdown{0};
std::atomic<unsigned> injectedPolicyFailures{0};
}  // namespace

extern "C" kern_return_t verifyPolyphasePolicySet(
    thread_act_t thread, thread_policy_flavor_t flavor, thread_policy_t policy,
    mach_msg_type_number_t count) {
  using PolicySet = kern_return_t (*)(thread_act_t, thread_policy_flavor_t,
                                    thread_policy_t, mach_msg_type_number_t);
  static const auto original =
      reinterpret_cast<PolicySet>(dlsym(RTLD_DEFAULT, "thread_policy_set"));
  if (!original) std::terminate();
  // Armed only after startup, on the single caller's submission path.
  const unsigned remaining = policyFailureCountdown.load();
  if (remaining != 0 && policyFailureCountdown.fetch_sub(1) == 1) {
    injectedPolicyFailures.fetch_add(1);
    return KERN_FAILURE;
  }
  return original(thread, flavor, policy, count);
}
#endif

namespace {

using NAMRig::PolyphaseWorker;
using NeuralAudio::NeuralModel;
using NeuralAudio::NeuralModelLoader;
using NeuralAudio::PolyphaseModel;
using ProcessRange = void (*)(void*, size_t, size_t) noexcept;
using Clock = std::chrono::steady_clock;

constexpr int kModelRate = 48000;
constexpr size_t kMaxBlock = 4096;
constexpr size_t kMaxPhases = 64;
constexpr double kOfflinePeriod = 0.02;
constexpr float kGuard = -12345.0f;
constexpr std::array<size_t, 17> kBlocks = {
    0, 1, 7, 64, 513, 3, 1000, 2, 4096, 255, 31, 65, 1, 509, 1024, 2049, 37};

void require(bool ok, const std::string& message) {
  if (!ok) throw std::runtime_error(message);
}

uint32_t bits(float value) noexcept {
  uint32_t result;
  std::memcpy(&result, &value, sizeof result);
  return result;
}

uint64_t phaseHash(size_t phase) noexcept {
  uint64_t hash = UINT64_C(0x9e3779b97f4a7c15) ^ phase;
  for (unsigned i = 0; i < 256; ++i)
    hash = (hash ^ (hash >> 13)) * UINT64_C(0xbf58476d1ce4e5b9) + i;
  return hash;
}

struct RangeObservation {
  struct Range {
    size_t begin = 0, end = 0;
    thread_t thread = MACH_PORT_NULL;
  };
  size_t phases;
  thread_t caller = pthread_mach_thread_np(pthread_self());
  std::array<std::atomic<unsigned>, kMaxPhases> visits{};
  std::array<std::atomic<uint64_t>, kMaxPhases> hashes{};
  std::array<Range, kMaxPhases> ranges{};
  std::atomic<unsigned> calls{0}, active{0}, peak{0}, invalid{0};

  explicit RangeObservation(size_t count) : phases(count) {}
};

void observeRange(void* context, size_t begin, size_t end) noexcept {
  auto& observation = *static_cast<RangeObservation*>(context);
  const unsigned slot = observation.calls.fetch_add(1);
  if (slot >= observation.ranges.size() || begin >= end ||
      end > observation.phases) {
    observation.invalid.fetch_add(1);
    return;
  }
  observation.ranges[slot] = {begin, end,
                            pthread_mach_thread_np(pthread_self())};
  const unsigned active = observation.active.fetch_add(1) + 1;
  unsigned peak = observation.peak.load();
  while (peak < active && !observation.peak.compare_exchange_weak(peak, active)) {}
  for (size_t phase = begin; phase < end; ++phase) {
    observation.visits[phase].fetch_add(1);
    observation.hashes[phase].store(phaseHash(phase));
  }
  observation.active.fetch_sub(1);
}

struct RangeStats {
  size_t calls = 0, helpers = 0, maxRange = 0, peak = 0;
};

RangeStats verifyRanges(PolyphaseWorker& worker, size_t phases, size_t samples,
                       bool serial, const std::string& label) {
  RangeObservation observation(phases);
  worker.execute(observeRange, &observation, phases, samples);
  RangeStats stats;
  stats.calls = observation.calls.load();
  stats.peak = observation.peak.load();
  require(observation.invalid.load() == 0 && observation.active.load() == 0,
          label + ": bounded valid ranges, all callbacks finished on return");
  if (phases == 0)
    require(stats.calls == 0 && stats.peak == 0,
            label + ": zero phases invoke no callbacks");
  else
    require(stats.calls >= 1 && stats.calls <= std::min(phases, worker.helperCount() + 1),
            label + ": nonzero phases invoke bounded nonempty ranges");
  std::array<thread_t, 3> threads{};
  for (size_t i = 0; i < stats.calls; ++i) {
    const auto& range = observation.ranges[i];
    stats.maxRange = std::max(stats.maxRange, range.end - range.begin);
    if (range.thread == observation.caller) continue;
    const auto known = std::find(threads.begin(), threads.end(), range.thread);
    if (known == threads.end()) {
      require(stats.helpers < threads.size(), label + ": at most three helpers");
      threads[stats.helpers++] = range.thread;
    }
  }
  require(stats.helpers <= worker.helperCount() && stats.peak <= 4,
          label + ": bounded worker/concurrency observations");
  const bool expectSerial = serial || phases == 0;
  require(expectSerial ? stats.helpers == 0 : stats.helpers > 0,
          label + (expectSerial ? ": no helper execution" : ": actually uses helpers"));
  for (size_t phase = 0; phase < kMaxPhases; ++phase) {
    require(observation.visits[phase].load() == (phase < phases ? 1u : 0u),
            label + ": each phase executes exactly once, including fallback");
    if (phase < phases)
      require(observation.hashes[phase].load() == phaseHash(phase),
              label + ": completed phase result visible to caller");
  }
  return stats;
}

void testExecutor() {
  // Pin the policy independently of the dispatch implementation: short low-
  // phase-count jobs stay serial; True8's 16 phases can use all three helpers.
  require(PolyphaseWorker::helpersFor(3, 16, 15) == 0, "tiny phase blocks serial");
  require(PolyphaseWorker::helpersFor(3, 2, 16) == 0, "short two-phase jobs serial");
  require(PolyphaseWorker::helpersFor(3, 4, 16) == 0, "insufficient grouped work serial");
  require(PolyphaseWorker::helpersFor(3, 8, 16) == 1, "short eight-phase job uses one helper");
  require(PolyphaseWorker::helpersFor(3, 16, 16) == 3, "short sixteen-phase job uses three helpers");
  require(PolyphaseWorker::helpersFor(1, 16, 16) == 1, "respect available helper cap");
  require(PolyphaseWorker::helpersFor(3, 2, 32) == 1, "old long-block policy unchanged");
  static_assert(std::is_base_of<PolyphaseModel::Executor, PolyphaseWorker>::value);
  static_assert(std::is_same<decltype(&PolyphaseWorker::start),
                            bool (PolyphaseWorker::*)(void*, double, size_t)
                                noexcept>::value);
  static_assert(std::is_same<decltype(&PolyphaseWorker::stop),
                            void (PolyphaseWorker::*)() noexcept>::value);
  static_assert(std::is_same<decltype(&PolyphaseWorker::helperCount),
                            size_t (PolyphaseWorker::*)() const noexcept>::value);
  static_assert(std::is_same<decltype(&PolyphaseWorker::setDeadline),
                            void (PolyphaseWorker::*)(uint64_t) noexcept>::value);
  static_assert(std::is_same<decltype(&PolyphaseWorker::execute),
                            void (PolyphaseWorker::*)(ProcessRange, void*, size_t,
                                                      size_t) noexcept>::value);

  PolyphaseWorker worker;
  require(worker.helperCount() == 0, "new pool has no helpers");
  verifyRanges(worker, 16, 1024, true, "stopped pool");
  worker.stop();
  worker.stop();
  size_t maxCalls = 0, maxHelpers = 0, maxRange = 0, maxPeak = 0;
  for (size_t requested : {size_t{1}, size_t{3}, size_t{64}}) {
    const bool started = worker.start(nullptr, kOfflinePeriod, requested);
    // Above the cap, either reject cleanly or clamp; no overflow-sized pool.
    require(started || requested > 3, "offline start with one/three helpers");
    require(worker.helperCount() <= 3 &&
                (!started || worker.helperCount() == std::min<size_t>(requested, 3)),
            "requested helper count bounded to three");
    if (!started) {
      require(worker.helperCount() == 0, "rejected oversized start leaves pool stopped");
      verifyRanges(worker, 16, 1024, true, "rejected oversized pool");
      worker.stop();
      continue;
    }
    for (size_t phases : {size_t{0}, size_t{1}, size_t{2}, size_t{3},
                          size_t{8}, size_t{16}, size_t{64}}) {
      for (size_t samples : {size_t{0}, size_t{15}, size_t{16}, size_t{31}, size_t{32}, size_t{1024}}) {
        const size_t expected = PolyphaseWorker::helpersFor(worker.helperCount(), phases, samples);
        const auto stats = verifyRanges(worker, phases, samples,
                                        expected == 0,
                                        "threshold/range dispatch");
        require(stats.helpers == expected, "workload-aware helper count");
        maxCalls = std::max(maxCalls, stats.calls);
        maxHelpers = std::max(maxHelpers, stats.helpers);
        maxRange = std::max(maxRange, stats.maxRange);
        maxPeak = std::max(maxPeak, stats.peak);
      }
    }
    for (unsigned i = 0; i < 128; ++i) {
      const bool expired = i % 3 == 0;
      worker.setDeadline(expired ? mach_absolute_time() : 0);
      verifyRanges(worker, 16, 64, expired, "immediate resubmit/deadline fallback");
    }
    worker.setDeadline(0);
    worker.stop();
    require(worker.helperCount() == 0, "stop resets helper count");
    verifyRanges(worker, 16, 1024, true, "stop after processing");
  }

  worker.start(nullptr, kOfflinePeriod, 0);
  require(worker.helperCount() == 0, "zero helper request stays serial");
  verifyRanges(worker, 16, 64, true, "zero helper pool");
  worker.stop();

#ifdef NAMRIG_VERIFY_POLYPHASE_POLICY_FAILURE
  mach_timebase_info_data_t timebase{};
  require(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.numer != 0 &&
              timebase.denom != 0,
          "Mach deadline timebase");
  require(worker.start(nullptr, kOfflinePeriod, 3), "start partial-failure pool");
  const uint64_t window = UINT64_C(10000000) * timebase.denom / timebase.numer;
  worker.setDeadline(mach_absolute_time() + window);
  const unsigned failuresBefore = injectedPolicyFailures.load();
  // First range is published, second submit fails before publication. The
  // successful helper must be waited for, never included in serial fallback.
  policyFailureCountdown.store(2);
  verifyRanges(worker, 16, 1024, false, "partial submit failure");
  require(policyFailureCountdown.load() == 0 &&
              injectedPolicyFailures.load() == failuresBefore + 1,
          "second submit policy failure was exercised");
  worker.stop();
  require(worker.start(nullptr, kOfflinePeriod, 3), "restart after submit failure");
  worker.setDeadline(0);
  verifyRanges(worker, 16, 1024, false, "restarted partial-failure pool");
  worker.stop();
#else
  std::printf("NOTE: partial-submit injection disabled in this build\n");
#endif
  require(maxCalls == 4 && maxHelpers == 3, "three-helper pool uses four bounded ranges");
  std::printf("PASS: executor coverage, thresholds, deadlines, stop/restart; "
              "max ranges=%zu helpers=%zu range phases=%zu concurrent=%zu\n",
              maxCalls, maxHelpers, maxRange, maxPeak);
}

std::vector<float> makeSignal(size_t count, double rate) {
  std::vector<float> signal(count);
  uint32_t rng = 0x9e3779b9u;
  for (size_t i = 0; i < count; ++i) {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    const float noise = static_cast<float>(rng >> 8) / 8388608.0f - 1.0f;
    const double t = static_cast<double>(i) / rate;
    float value = 0.3f * static_cast<float>(std::sin(6.283185307179586 * 82.4 * t)) +
                  0.1f * static_cast<float>(std::sin(6.283185307179586 * 1234.5 * t)) +
                  0.05f * noise;
    if ((i / 997) % 2) value *= 3.0f;
    if (i % 4093 == 0) value += 0.2f;
    signal[i] = value;
  }
  return signal;
}

struct LoadedModel {
  // Composite quality changes may consult the loader; keep it alive with model.
  NeuralModelLoader loader;
  std::unique_ptr<NeuralModel> storage;

  PolyphaseModel* currentPolyphase() const noexcept {
    NeuralModel* current = storage.get();
    while (current) {
      if (auto* polyphase = dynamic_cast<PolyphaseModel*>(current)) return polyphase;
      auto* composite = dynamic_cast<NeuralAudio::CompositeModel*>(current);
      if (!composite) return nullptr;
      current = composite->GetCurrentModel();
    }
    return nullptr;
  }

  LoadedModel(const std::string& path, int factor, int scratch) {
    loader.SetExternalSampleRate(kModelRate * factor);
    loader.SetDefaultMaxAudioBufferSize(scratch);
    loader.SetDefaultQualityScaleFactor(1.0f);
    loader.SetCompositeModelLoadMode(NeuralAudio::LoadAll);
    loader.SetPolyphaseOversampling(true);
    storage.reset(loader.CreateFromFile(path, true));
    require(storage != nullptr, path + ": load real model");
    storage->SetMaxAudioBufferSize(scratch);
    storage->SetQualityScaleFactor(1.0f);
    auto* model = currentPolyphase();
    require(model && model->GetNumPhases() == static_cast<size_t>(factor),
            path + ": load a real polyphase model, factor " + std::to_string(factor));
  }
};

struct TracingExecutor : PolyphaseModel::Executor {
  struct Job {
    ProcessRange process;
    void* context;
    thread_t caller = pthread_mach_thread_np(pthread_self());
    std::atomic<size_t> helperRanges{0};
  };
  PolyphaseWorker& worker;
  size_t calls = 0, helperRanges = 0, shortCalls = 0, eligibleCalls = 0;
  bool invalidThreading = false;

  explicit TracingExecutor(PolyphaseWorker& pool) : worker(pool) {}

  static void process(void* context, size_t begin, size_t end) noexcept {
    auto& job = *static_cast<Job*>(context);
    if (pthread_mach_thread_np(pthread_self()) != job.caller)
      job.helperRanges.fetch_add(1);
    job.process(job.context, begin, end);
  }

  void execute(ProcessRange callback, void* context, size_t phases,
               size_t minimumSamples) noexcept override {
    Job job{callback, context};
    const bool eligible = PolyphaseWorker::helpersFor(3, phases, minimumSamples) != 0;
    ++calls;
    if (eligible) ++eligibleCalls;
    else ++shortCalls;
    worker.execute(process, &job, phases, minimumSamples);
    const size_t observed = job.helperRanges.load();
    helperRanges += observed;
    if (!eligible && observed != 0) invalidThreading = true;
  }
};

void compareExact(const float* actual, const float* serial, size_t count,
                  const std::string& label) {
  for (size_t i = 0; i < count; ++i) {
    if (!std::isfinite(actual[i]) || !std::isfinite(serial[i]) ||
        bits(actual[i]) != bits(serial[i])) {
      char detail[192];
      std::snprintf(detail, sizeof detail,
                    ": sample %zu serial=%.9g [0x%08x] actual=%.9g [0x%08x]",
                    i, serial[i], bits(serial[i]), actual[i], bits(actual[i]));
      require(false, label + detail);
    }
  }
}

struct ModelComparison {
  LoadedModel serial, parallel;
  std::vector<float> serialInput, parallelInput, serialOutput, parallelOutput;
  double energy = 0.0;

  ModelComparison(const std::string& path, int factor, int scratch)
      : serial(path, factor, scratch), parallel(path, factor, scratch),
        serialInput(kMaxBlock + 2), parallelInput(kMaxBlock + 2),
        serialOutput(kMaxBlock + 2), parallelOutput(kMaxBlock + 2) {}

  void block(const float* input, size_t count, bool inPlace,
             PolyphaseModel::Executor* executor, bool useSerialEntry,
             const std::string& label) {
    require(count <= kMaxBlock, "test block fits guarded storage");
    for (auto* buffer : {&serialInput, &parallelInput, &serialOutput, &parallelOutput}) {
      (*buffer)[0] = kGuard;
      (*buffer)[count + 1] = kGuard;
    }
    std::copy_n(input, count, serialInput.data() + 1);
    std::copy_n(input, count, parallelInput.data() + 1);
    std::fill_n(serialOutput.data() + 1, count, std::numeric_limits<float>::quiet_NaN());
    std::fill_n(parallelOutput.data() + 1, count, std::numeric_limits<float>::quiet_NaN());
    float* reference = (inPlace ? serialInput : serialOutput).data() + 1;
    float* actual = (inPlace ? parallelInput : parallelOutput).data() + 1;
    serial.storage->Process(serialInput.data() + 1, reference, count);
    if (useSerialEntry)
      parallel.storage->Process(parallelInput.data() + 1, actual, count);
    else {
      auto* model = parallel.currentPolyphase();
      require(model != nullptr, label + ": active model is polyphase");
      model->ProcessWithExecutor(parallelInput.data() + 1, actual, count, executor);
    }
    compareExact(actual, reference, count, label);
    for (auto* buffer : {&serialInput, &parallelInput, &serialOutput, &parallelOutput})
      require((*buffer)[0] == kGuard && (*buffer)[count + 1] == kGuard,
              label + ": input/output boundary guards intact");
    for (size_t i = 0; i < count; ++i) energy += static_cast<double>(actual[i]) * actual[i];
  }
};

void testModel(const std::string& path, int factor, int scratch, bool a2) {
  ModelComparison comparison(path, factor, scratch);
  const auto signal = makeSignal(14009, kModelRate * factor);
  const std::string label = std::filesystem::path(path).filename().string() +
                            " F=" + std::to_string(factor) +
                            " scratch=" + std::to_string(scratch);
  require(!a2 || comparison.serial.storage->HasQualityScaling(),
          label + ": A2 fixture supports quality switching");
  PolyphaseWorker worker;
  TracingExecutor trace(worker);
  for (size_t helpers : {size_t{1}, size_t{3}}) {
    require(worker.start(nullptr, kOfflinePeriod, helpers), label + ": offline worker start");
    worker.setDeadline(0);
    for (bool inPlace : {false, true}) {
      const size_t helpersBefore = trace.helperRanges;
      for (size_t position = 0, block = 0; position < signal.size(); ++block) {
        const size_t count = std::min(kBlocks[block % kBlocks.size()], signal.size() - position);
        comparison.block(signal.data() + position, count, inPlace, &trace, false,
                         label + (inPlace ? " in-place" : " separate in/out") +
                             " helpers=" + std::to_string(helpers) +
                             " block=" + std::to_string(block));
        position += count;
      }
      require(scratch == 37 ? trace.helperRanges == helpersBefore
                            : trace.helperRanges > helpersBefore,
              label + ": scratch37 stays serial; scratch1024 actually threads");
    }
    worker.stop();
  }

  require(worker.start(nullptr, kOfflinePeriod, 3), label + ": start lifecycle pool");
  constexpr std::array<float, 4> qualities = {1.0f, 0.5f, 0.75f, 1.0f};
  std::array<size_t, 4> qualityHelperRanges{};
  for (size_t block = 0; block < 32; ++block) {
    if (block % 8 == 0) {
      const float quality = qualities[block / 8];
      require(comparison.serial.storage->IsQualityChangeRealtimeSafe(quality) &&
                  comparison.parallel.storage->IsQualityChangeRealtimeSafe(quality),
              label + ": all quality tiers prewarmed");
      comparison.serial.storage->SetQualityScaleFactor(quality);
      comparison.parallel.storage->SetQualityScaleFactor(quality);
      auto* serialPhase = comparison.serial.currentPolyphase();
      auto* parallelPhase = comparison.parallel.currentPolyphase();
      require(serialPhase && parallelPhase &&
                  serialPhase->GetNumPhases() == static_cast<size_t>(factor) &&
                  parallelPhase->GetNumPhases() == static_cast<size_t>(factor),
              label + ": quality change selects polyphase children with expected phases");
      if (a2)
        require(comparison.serial.storage->GetQualityScaleFactor() == quality &&
                    comparison.parallel.storage->GetQualityScaleFactor() == quality,
                label + ": quality change applied to both models");
    }
    if (block == 8 || block == 20) worker.stop();
    if (block == 12 || block == 24)
      require(worker.start(nullptr, kOfflinePeriod, block == 12 ? 1 : 3),
              label + ": restart without resetting model phase histories");
    const bool expired = block % 4 == 3;
    worker.setDeadline(expired ? mach_absolute_time() : 0);
    const size_t helpersBefore = trace.helperRanges;
    const size_t count = block % 4 >= 2 ? 1021 + block % 3
                                       : kBlocks[block % kBlocks.size()];
    comparison.block(signal.data() + (block * 131) % (signal.size() - kMaxBlock),
                     count, block % 2 == 0, block % 4 == 1 ? nullptr : &trace,
                     block % 4 == 0, label + " lifecycle block=" + std::to_string(block));
    qualityHelperRanges[block / 8] += trace.helperRanges - helpersBefore;
    if (expired || worker.helperCount() == 0)
      require(trace.helperRanges == helpersBefore,
              label + ": expired/stopped processing executes only on caller");
  }
  worker.stop();
  require(!trace.invalidThreading && comparison.energy > 1.0e-6,
          label + ": threshold respected and non-silent finite output");
  require(trace.calls > 0 && trace.shortCalls > 0, label + ": short executor calls covered");
  if (scratch == 37)
    require(trace.eligibleCalls == 0 && trace.helperRanges == 0,
            label + ": all internally chunked scratch37 work is below threshold");
  else
    for (size_t ranges : qualityHelperRanges)
      require(ranges > 0, label + ": every quality epoch includes threaded model processing");
  std::printf("PASS: %s, bit-exact 1/3 helpers, in/out, irregular chunks, quality, "
              "serial/null-executor switching, stop/restart, expired deadlines "
              "(executor calls=%zu helper ranges=%zu)\n",
              label.c_str(), trace.calls, trace.helperRanges);
}

uint64_t checksum(uint64_t hash, const float* output, size_t count) noexcept {
  for (size_t i = 0; i < count; ++i)
    hash = (hash ^ bits(output[i])) * UINT64_C(1099511628211);
  return hash;
}

void benchmark(const std::array<std::string, 2>& paths, Clock::time_point harnessStart) {
  constexpr int kFactor = 16;
  constexpr int kSessionRate = 96000;
  constexpr size_t kSessionFactor = 8;
  constexpr size_t kWarmup = 24, kMeasurements = 128;
  // A time slice per configuration limits work on slower/debug builds. No
  // performance threshold is asserted: overruns are observations, not failures.
  const auto deadline = harnessStart + std::chrono::seconds(50);
  size_t configurationsLeft = paths.size() * 4;
  std::printf("== Benchmark: model=48kHz domain=768kHz (model factor16), "
              "session=96kHz factor8; wall time per complete Process, us\n");
  for (const auto& path : paths) {
    std::array<std::unique_ptr<LoadedModel>, 3> models;
    for (auto& model : models) model = std::make_unique<LoadedModel>(path, kFactor, 2048);
    for (size_t block : {size_t{32}, size_t{64}, size_t{128}, size_t{256}}) {
      const size_t domainFrames = block * kSessionFactor;
      const double budgetUs = 1.0e6 * static_cast<double>(block) / kSessionRate;
      const auto signal = makeSignal((kWarmup + kMeasurements) * domainFrames,
                                     kModelRate * kFactor);
      std::array<std::vector<float>, 3> inputs, outputs;
      std::array<std::vector<double>, 3> times;
      std::array<uint64_t, 3> hashes;
      hashes.fill(UINT64_C(14695981039346656037));
      std::array<size_t, 3> overruns{};
      for (size_t mode = 0; mode < models.size(); ++mode) {
        inputs[mode].resize(domainFrames);
        outputs[mode].resize(domainFrames);
        times[mode].reserve(kMeasurements);
      }
      PolyphaseWorker oneHelper, threeHelpers;
      const double period = static_cast<double>(block) / kSessionRate;
      require(oneHelper.start(nullptr, period, 1) && threeHelpers.start(nullptr, period, 3),
              "benchmark offline worker start");
      oneHelper.setDeadline(0);
      threeHelpers.setDeadline(0);
      const auto now = Clock::now();
      const auto remaining = deadline > now ? deadline - now : Clock::duration::zero();
      const auto caseDeadline = now + remaining / static_cast<int64_t>(configurationsLeft--);
      double energy = 0.0;
      for (size_t iteration = 0; iteration < kWarmup + kMeasurements; ++iteration) {
        if (iteration >= kWarmup + 8 && Clock::now() >= caseDeadline) break;
        // Rotate timing order so serial is not always the first, coldest run.
        for (size_t order = 0; order < models.size(); ++order) {
          const size_t mode = (iteration + order) % models.size();
          std::copy_n(signal.data() + iteration * domainFrames, domainFrames, inputs[mode].data());
          std::fill(outputs[mode].begin(), outputs[mode].end(),
                    std::numeric_limits<float>::quiet_NaN());
          const auto begin = Clock::now();
          if (mode == 0)
            models[mode]->storage->Process(inputs[mode].data(), outputs[mode].data(), domainFrames);
          else
            models[mode]->currentPolyphase()->ProcessWithExecutor(
                inputs[mode].data(), outputs[mode].data(), domainFrames,
                mode == 1 ? &oneHelper : &threeHelpers);
          const double elapsed = std::chrono::duration<double, std::micro>(Clock::now() - begin).count();
          if (iteration >= kWarmup) {
            times[mode].push_back(elapsed);
            if (elapsed > budgetUs) ++overruns[mode];
            hashes[mode] = checksum(hashes[mode], outputs[mode].data(), domainFrames);
          }
        }
        compareExact(outputs[1].data(), outputs[0].data(), domainFrames, "benchmark one helper");
        compareExact(outputs[2].data(), outputs[0].data(), domainFrames, "benchmark three helpers");
        for (float value : outputs[0]) energy += static_cast<double>(value) * value;
      }
      oneHelper.stop();
      threeHelpers.stop();
      require(energy > 1.0e-6 && hashes[0] == hashes[1] && hashes[0] == hashes[2],
              "benchmark non-silent, bit-exact output and matching checksums");
      for (size_t mode = 0; mode < models.size(); ++mode) {
        auto& sorted = times[mode];
        require(!sorted.empty(), "benchmark collected timing samples");
        std::sort(sorted.begin(), sorted.end());
        const size_t middle = sorted.size() / 2;
        const double median = sorted.size() % 2 ? sorted[middle]
                                               : (sorted[middle - 1] + sorted[middle]) * 0.5;
        const size_t p95 = static_cast<size_t>(std::ceil(sorted.size() * 0.95)) - 1;
        const size_t helpers = mode == 0 ? 0 : mode == 1 ? 1 : 3;
        std::printf("BENCH %s block=%zu domain_frames=%zu helpers=%zu n=%zu "
                    "median=%.1f p95=%.1f max=%.1f budget=%.1f overruns=%zu/%zu "
                    "checksum=%016llx equality=exact\n",
                    std::filesystem::path(path).filename().string().c_str(), block,
                    domainFrames, helpers, sorted.size(),
                    median, sorted[p95], sorted.back(), budgetUs, overruns[mode],
                    sorted.size(), static_cast<unsigned long long>(hashes[mode]));
      }
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  const auto start = Clock::now();
  try {
    const bool runBenchmark = argc == 2 && std::strcmp(argv[1], "--benchmark") == 0;
    require(argc == 1 || runBenchmark, "usage: verify_parallel_polyphase [--benchmark]");
    const std::string directory = std::string(NAM_REPO_DIR) + "/deps/NeuralAudio/Utils/Models/";
    const std::array<std::string, 2> paths = {
        directory + "BossWN-standard.nam", directory + "BossWN-a2.nam"};
    for (const auto& path : paths) {
      std::error_code error;
      require(std::filesystem::is_regular_file(path, error) && !error,
              "missing required fixture: " + path);
    }
    testExecutor();
    for (size_t fixture = 0; fixture < paths.size(); ++fixture)
      for (int factor : {2, 3, 8, 16})
        for (int scratch : {37, 1024})
          testModel(paths[fixture], factor, scratch, fixture == 1);
    if (runBenchmark) benchmark(paths, start);
    std::printf("ALL PASSED (%.2fs)\n", std::chrono::duration<double>(Clock::now() - start).count());
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    return 1;
  } catch (...) {
    std::fprintf(stderr, "FAIL: unexpected exception\n");
    return 1;
  }
}
