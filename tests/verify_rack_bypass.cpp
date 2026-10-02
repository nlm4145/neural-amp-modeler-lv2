// Runtime regression against a fresh LV2 plugin, not a recompiled DSP copy.
// Build: clang++ -O2 -std=c++17 -Isrc -Ideps/lv2/include -Ideps/NeuralAudio \
//   -Ideps/NeuralAudio/deps/RTNeural/modules/json tests/verify_rack_bypass.cpp -o <test>
// Usage: <test> <freshly built neural_amp_modeler_rig.so>
#include "nam_rig_plugin.h"
#include "rack_controls.h"

#include <dlfcn.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
using namespace NAMRig;
constexpr size_t kBlock = 128, kAtomBytes = 16384;
using Controls = std::array<float, Plugin::kPortCount>;
static_assert(kRackCount == 9 && kRackControlFirstPort == 71 && Plugin::kPortCount == 83 &&
                  kPowerTubeTypePort == 80 && kPowerTubeCharacterPort == 81 && kMidPushPort == 82,
               "rack integration requires the appended switch ABI");
static_assert(static_cast<size_t>(Rack::Delay) == 0 && static_cast<size_t>(Rack::Reverb) == 1 &&
                  static_cast<size_t>(Rack::Spatial) == 2 && static_cast<size_t>(Rack::Power) == 3 &&
                  static_cast<size_t>(Rack::Sculpt) == 4 && static_cast<size_t>(Rack::Transformer) == 5 &&
                  static_cast<size_t>(Rack::Speaker) == 6 && static_cast<size_t>(Rack::CabConsole) == 7 &&
                  static_cast<size_t>(Rack::PowerTube) == 8,
              "old rack indices must remain append-only");
int failures = 0;
void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}
void require(bool ok, const char* label) {
  if (!ok) throw std::runtime_error(label);
}
constexpr size_t port(Rack rack) { return kRackControlFirstPort + static_cast<size_t>(rack); }

class Identity final : public NeuralAudio::NeuralModel {
 public:
  float GetRecommendedInputDBAdjustment() override { return 0; }
  float GetRecommendedOutputDBAdjustment() override { return 0; }
  void Process(float* input, float* output, size_t count) override {
    if (input != output) std::memcpy(output, input, count * sizeof(float));
  }
};

struct Fixtures {
  std::filesystem::path directory;
  std::array<std::string, 2> paths;
  explicit Fixtures(double rate) {
    std::string pattern = (std::filesystem::temp_directory_path() / "rack-bypass-XXXXXX").string();
    require(mkdtemp(pattern.data()) != nullptr, "create WAV fixture directory");
    directory = pattern;
    for (size_t cab = 0; cab < paths.size(); ++cab) {
      paths[cab] = (directory / (cab ? "cab-b.wav" : "cab-a.wav")).string();
      std::ofstream file(paths[cab], std::ios::binary);
      auto little = [&](uint32_t value, unsigned bytes) {
        for (unsigned i = 0; i < bytes; ++i) file.put(static_cast<char>(value >> (8 * i)));
      };
      constexpr uint32_t frames = 32, channels = 2, dataBytes = frames * channels * 2;
      const uint32_t sampleRate = static_cast<uint32_t>(rate);
      file.write("RIFF", 4); little(36 + dataBytes, 4); file.write("WAVEfmt ", 8);
      little(16, 4); little(1, 2); little(channels, 2); little(sampleRate, 4);
      little(sampleRate * channels * 2, 4); little(channels * 2, 2); little(16, 2);
      file.write("data", 4); little(dataBytes, 4);
      for (uint32_t frame = 0; frame < frames; ++frame) {
        for (unsigned channel = 0; channel < channels; ++channel) {
          const int16_t tap = frame == 0 ? (channel == 0 ? (cab ? 4096 : 16384)
                                                                     : (cab ? 12288 : 8192))
              : frame == 7 + cab * 4 ? (channel == 0 ? 2048 : -1024) : 0;
          little(static_cast<uint16_t>(tap), 2);
        }
      }
      file.close();
      require(static_cast<bool>(file), "write stereo WAV fixture");
    }
  }
  ~Fixtures() {
    std::error_code error;
    std::filesystem::remove_all(directory, error);
  }
};

Controls defaults(int mode) {
  Controls c{};
  c[6] = c[8] = c[9] = 1;
  c[15] = -80;
  c[20] = c[21] = static_cast<float>(mode);
  c[23] = 150;
  c[24] = 3; // Original fixture taps, with no normalization ambiguity.
  c[27] = 20000;
  c[43] = c[44] = 25;
  c[45] = c[46] = 50;
  c[50] = 80; c[51] = 45; c[52] = 40;
  c[55] = c[56] = c[57] = 50; c[58] = 10;
  std::copy(kTransformerControlDefaults.begin(), kTransformerControlDefaults.end(),
            c.begin() + kTransformerControlFirstPort);
  std::copy(kRackControlDefaults.begin(), kRackControlDefaults.end(), c.begin() + kRackControlFirstPort);
  c[kPowerTubeCharacterPort] = kPowerTubeCharacterDefault;
  return c;
}

void nonneutral(Controls& c, Rack rack) {
  switch (rack) {
    case Rack::Delay: c[53] = 65; break;
    case Rack::Reverb: c[54] = 65; break;
    case Rack::Spatial: c[32] = 90; c[33] = 65; break;
    case Rack::Power:
      c[34] = 8; c[35] = 6; c[36] = 70; c[37] = 35; c[38] = 80; c[41] = 65; break;
    case Rack::Sculpt: c[39] = 90; c[40] = 80; break;
    case Rack::Transformer:
      c[30] = OutputTransformer::kUKVintage;
      c[62] = 2; c[63] = 30; c[66] = 5; break;
    case Rack::Speaker:
      c[42] = SpeakerDynamics::kModern412;
      c[43] = c[44] = c[45] = c[46] = 90; break;
    case Rack::CabConsole:
      c[25] = -12; c[26] = 350; c[27] = 2200; c[48] = -9; c[49] = -7; c[59] = 1; break;
    case Rack::PowerTube:
      c[kPowerTubeTypePort] = PowerTube::kEL34;
      c[kPowerTubeCharacterPort] = 100; break;
    case Rack::Count: break;
  }
}

struct Host {
  const LV2_Descriptor* descriptor;
  const LV2_Worker_Interface* worker;
  LV2_Handle instance = nullptr;
  std::vector<std::string> uris;
  std::deque<std::vector<uint8_t>> jobs;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  Controls controls;
  std::array<float, kBlock> input{}, left{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, kAtomBytes> control{}, notify{};
  double rate;
  size_t position = 0;
  unsigned loads = 0;
  bool finite = true;

  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& ids = static_cast<Host*>(handle)->uris;
    const auto found = std::find(ids.begin(), ids.end(), uri);
    if (found != ids.end()) return static_cast<LV2_URID>(found - ids.begin() + 1);
    ids.emplace_back(uri);
    return static_cast<LV2_URID>(ids.size());
  }
  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                       uint32_t size, const void* data) {
    auto& host = *static_cast<Host*>(handle);
    const auto* bytes = static_cast<const uint8_t*>(data);
    host.jobs.emplace_back(bytes, bytes + size);
    if (*static_cast<const LV2WorkType*>(data) == kWorkTypeLoad) ++host.loads;
    return LV2_WORKER_SUCCESS;
  }
  static LV2_Worker_Status respond(LV2_Worker_Respond_Handle handle,
                                  uint32_t size, const void* data) {
    auto& host = *static_cast<Host*>(handle);
    const auto& message = *static_cast<const LV2SwitchModelMsg*>(data);
    require(message.ir && message.irRight && message.path[0], "real worker loaded stereo WAV");
    return host.worker->work_response(host.instance, size, data);
  }
  Host(const LV2_Descriptor* d, double sampleRate, Controls values,
       const Fixtures* fixtures = nullptr, bool legacy = false, bool converterCabs = false)
      : descriptor(d), worker(static_cast<const LV2_Worker_Interface*>(
            d->extension_data(LV2_WORKER__interface))), controls(values), rate(sampleRate) {
    LV2_Feature mapFeature{LV2_URID__map, &map}, workerFeature{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mapFeature, &workerFeature, nullptr};
    instance = d->instantiate(d, rate, "", features);
    require(instance && worker, "instantiate rig with worker interface");
    d->connect_port(instance, 0, control.data());
    d->connect_port(instance, 1, notify.data());
    d->connect_port(instance, 2, input.data());
    d->connect_port(instance, 3, left.data());
    d->connect_port(instance, 31, right.data());
    for (uint32_t p = 4; p < Plugin::kPortCount; ++p)
      if (p != 31) d->connect_port(instance, p, legacy && p >= kRackControlFirstPort ? nullptr : &controls[p]);
    run(true); // Latch rate and initial rack requests before model installation.
    LV2SwitchModelMsg amp{kWorkTypeSwitch, Stage::Amp, static_cast<int>(controls[21]),
                         0, {}, new Identity, nullptr, nullptr, false};
    // A nonempty installed path arms reload detection; an empty path would let
    // an accidental reloadModelsForOversample() schedule nothing and go unnoticed.
    std::strcpy(amp.path, "rack-test-identity.nam");
    require(worker->work_response(instance, sizeof(amp), &amp) == LV2_WORKER_SUCCESS, "install identity amp");
    if (converterCabs) {
      for (Stage stage : {Stage::Cab, Stage::Cab2}) {
        LV2SwitchModelMsg cab{kWorkTypeSwitch, stage, stage == Stage::Cab2 ? 1 : static_cast<int>(controls[21]),
                             0, {}, new Identity, nullptr, nullptr, false};
        require(worker->work_response(instance, sizeof(cab), &cab) == LV2_WORKER_SUCCESS, "install identity cabinet");
      }
    } else if (fixtures) {
      for (size_t i = 0; i < 2; ++i) {
        LV2LoadModelMsg cab{kWorkTypeLoad, i ? Stage::Cab2 : Stage::Cab,
                           i ? 1 : static_cast<int>(controls[21]), 0, {}};
        require(fixtures->paths[i].size() < sizeof(cab.path), "WAV fixture path fits");
        std::strcpy(cab.path, fixtures->paths[i].c_str());
        require(worker->work(instance, respond, this, sizeof(cab), &cab) == LV2_WORKER_SUCCESS, "load WAV cabinet");
      }
    }
    for (int block = 0; block < 32; ++block) run(true);
    loads = 0;
  }
  ~Host() { if (instance) descriptor->cleanup(instance); }
  void run(bool silence = false, float level = 1.0f) {
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    sequence->atom.type = mapUri(this, LV2_ATOM__Sequence);
    sequence->atom.size = sizeof(LV2_Atom_Sequence_Body);
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = kAtomBytes - sizeof(LV2_Atom);
    for (float& x : input) {
      const double t = static_cast<double>(position++) / rate;
      x = silence ? 0 : level * static_cast<float>(.22 * std::sin(6.283185307179586 * 83 * t) +
          .13 * std::sin(6.283185307179586 * 997 * t) + .07 * std::sin(6.283185307179586 * 7331 * t));
    }
    descriptor->run(instance, kBlock);
    for (size_t i = 0; i < kBlock; ++i) finite &= std::isfinite(left[i]) && std::isfinite(right[i]);
    while (!jobs.empty()) {
      auto job = std::move(jobs.front());
      jobs.pop_front();
      require(worker->work(instance, respond, this, static_cast<uint32_t>(job.size()), job.data()) ==
                  LV2_WORKER_SUCCESS, "drain worker outside audio callback");
    }
  }
  double difference(const Host& other) const {
    double result = 0;
    for (size_t i = 0; i < kBlock; ++i)
      result += std::fabs(left[i] - other.left[i]) + std::fabs(right[i] - other.right[i]);
    return result / (2 * kBlock);
  }
  bool unchanged(const Controls& saved) const {
    for (size_t p = 4; p < Plugin::kPortCount; ++p)
      if (p != 11 && p != 17 && p != 18 && p != 29 && p != 31 &&
          !(p >= kRackControlFirstPort && p < kRackControlFirstPort + kRackCount) &&
          controls[p] != saved[p]) return false;
    return true;
  }
};

void verify(const LV2_Descriptor* d) {
  for (int mode : {0, 6}) {
    const double rate = mode == 0 ? 48000 : 96000;
    Fixtures fixtures(rate);
    for (size_t i = 0; i < kRackCount; ++i) {
      const Rack rack = static_cast<Rack>(i);
      Controls neutral = defaults(mode), edited = neutral;
      neutral[47] = edited[47] = 1;
      nonneutral(edited, rack);
      neutral[port(rack)] = edited[port(rack)] = 0;
      Host baseline(d, rate, neutral, &fixtures), bypass(d, rate, edited, &fixtures);
      const Controls saved = bypass.controls;
      bool off = true, restore = true;
      for (int block = 0; block < 120; ++block) {
        baseline.run(); bypass.run();
        off &= bypass.difference(baseline) < 1e-6;
      }
      for (int cycle = 0; cycle < 2; ++cycle) {
        baseline.controls[port(rack)] = bypass.controls[port(rack)] = 1;
        double audible = 0;
        for (int block = 0; block < 300; ++block) {
          baseline.run(); bypass.run();
          if (block > 200) audible += bypass.difference(baseline);
        }
        restore &= audible > .01;
        baseline.controls[port(rack)] = bypass.controls[port(rack)] = 0;
        // Global fades and DC/filter history settle before steady-state comparisons.
        for (int block = 0; block < 800; ++block) { baseline.run(true); bypass.run(true); }
        for (int block = 0; block < 120; ++block) {
          baseline.run(); bypass.run();
          off &= bypass.difference(baseline) < 1e-5;
        }
      }
      char label[200];
      std::snprintf(label, sizeof(label), "%s OFF matches neutral; ON restores processing twice (%g Hz, mode %d)",
                    kRackSlotKeys[i], rate, mode);
      check(off && restore && bypass.finite && baseline.finite, label);
      std::snprintf(label, sizeof(label), "%s OFF/ON preserves controls and never reloads models (%g Hz, mode %d)",
                    kRackSlotKeys[i], rate, mode);
      check(bypass.unchanged(saved) && bypass.loads == 0 && baseline.loads == 0, label);
    }

    Controls connected = defaults(mode);
    for (size_t i = 0; i < kRackCount; ++i) nonneutral(connected, static_cast<Rack>(i));
    // A legacy host has no selector/amount connection: compare with Captured,
    // not an accidentally active EL34 from the all-racks exercise above.
    connected[kPowerTubeTypePort] = PowerTube::kCaptured;
    connected[kPowerTubeCharacterPort] = kPowerTubeCharacterDefault;
    connected[47] = 1;
    Host explicitOn(d, rate, connected, &fixtures), legacy(d, rate, connected, &fixtures, true);
    bool match = true;
    for (int block = 0; block < 200; ++block) {
      explicitOn.run(); legacy.run();
      match &= explicitOn.difference(legacy) == 0;
    }
    check(match && legacy.finite, mode == 0 ? "unconnected rack/tube ports reproduce Captured exactly at base rate"
                                           : "unconnected rack/tube ports reproduce Captured exactly in True 8x");
  }

  for (int mode : {0, 6}) {
    const double rate = mode == 0 ? 48000 : 96000;
    bool combinations = true, preserves = true, neutral = true, nullSafe = true;
    for (int profile : {PowerTube::k6L6, PowerTube::kEL34}) {
      for (bool power : {false, true}) {
        for (bool tube : {false, true}) {
          Controls c = defaults(mode);
          nonneutral(c, Rack::Power);
          c[port(Rack::Power)] = power;
          c[port(Rack::PowerTube)] = tube;
          c[kPowerTubeTypePort] = static_cast<float>(profile);
          c[kPowerTubeCharacterPort] = 100;
          Controls equivalent = c;
          if (!power) equivalent[34] = equivalent[35] = equivalent[36] =
              equivalent[37] = equivalent[38] = equivalent[41] = 0;
          if (!tube) equivalent[kPowerTubeTypePort] = PowerTube::kCaptured;
          Host actual(d, rate, c), reference(d, rate, equivalent);
          Controls noTube = equivalent;
          noTube[kPowerTubeTypePort] = PowerTube::kCaptured;
          Host captured(d, rate, noTube);
          double audible = 0;
          const auto saved = actual.controls;
          for (int block = 0; block < 250; ++block) {
            actual.run(false, 4); reference.run(false, 4); captured.run(false, 4);
            combinations &= actual.difference(reference) == 0;
            if (block > 150) audible += actual.difference(captured);
          }
          combinations &= tube ? audible > .01 : audible == 0;
          preserves &= actual.unchanged(saved) && actual.loads == 0 && actual.finite && reference.finite;
        }
      }
    }
    check(combinations && preserves, mode == 0
        ? "Power and Tube independently honor all four ON/OFF combinations for both profiles at base rate"
        : "Power and Tube independently honor all four ON/OFF combinations for both profiles in True 8x");

    // A neutral Power toggle must be only a fade, not a new Tube startup.
    // Sculpt is neutral too, so its toggle supplies an identical reference fade
    // without touching the shared post-amp state.
    bool powerNeutral = true, powerReset = true;
    double worstPowerDifference = 0, worstPowerPeakRatio = 0;
    for (int profile : {PowerTube::k6L6, PowerTube::kEL34}) {
      for (float character : {0.0f, 50.0f, 100.0f}) {
        for (float level : {2.0f, 8.0f}) {
          Controls c = defaults(mode);
          c[kPowerTubeTypePort] = static_cast<float>(profile);
          c[kPowerTubeCharacterPort] = character;
          Host toggled(d, rate, c), faded(d, rate, c);
          const auto saved = toggled.controls;
          const int warmBlocks = static_cast<int>(std::ceil(rate * .3 / kBlock));
          const int testBlocks = static_cast<int>(std::ceil(rate * .08 / kBlock));
          for (int block = 0; block < warmBlocks; ++block) {
            toggled.run(false, level); faded.run(false, level);
          }
          for (float enabled : {0.0f, 1.0f, 0.0f, 1.0f}) {
            toggled.controls[port(Rack::Power)] = enabled;
            faded.controls[port(Rack::Sculpt)] = enabled;
            double actualPeak = 0, referencePeak = 0;
            for (int block = 0; block < testBlocks; ++block) {
              toggled.run(false, level); faded.run(false, level);
              for (size_t i = 0; i < kBlock; ++i) {
                const double difference = std::max(std::fabs(toggled.left[i] - faded.left[i]),
                                                   std::fabs(toggled.right[i] - faded.right[i]));
                worstPowerDifference = std::max(worstPowerDifference, difference);
                powerNeutral &= difference < 2e-6;
                actualPeak = std::max({actualPeak, std::fabs(static_cast<double>(toggled.left[i])),
                                      std::fabs(static_cast<double>(toggled.right[i]))});
                referencePeak = std::max({referencePeak, std::fabs(static_cast<double>(faded.left[i])),
                                         std::fabs(static_cast<double>(faded.right[i]))});
              }
            }
            worstPowerPeakRatio = std::max(worstPowerPeakRatio, actualPeak / referencePeak);
            powerNeutral &= std::fabs(actualPeak - referencePeak) < 2e-6;
          }
          powerNeutral &= toggled.finite && faded.finite && toggled.loads == 0 &&
                          faded.loads == 0 && toggled.unchanged(saved);
        }

        for (float bias : {-100.0f, 100.0f}) {
          Controls c = defaults(mode);
          c[kPowerTubeTypePort] = static_cast<float>(profile);
          c[kPowerTubeCharacterPort] = character;
          Controls charged = c;
          charged[34] = 12; charged[35] = -12;
          charged[36] = charged[38] = charged[41] = 100; charged[37] = bias;
          Host toggled(d, rate, charged), faded(d, rate, c);
          // Charge every smoother on silence. After Power OFF, its filters,
          // envelope and controls must reset, but the Tube amount must not.
          const int warmBlocks = static_cast<int>(std::ceil(rate * .3 / kBlock));
          for (int block = 0; block < warmBlocks; ++block) { toggled.run(true); faded.run(true); }
          toggled.controls[port(Rack::Power)] = faded.controls[port(Rack::Sculpt)] = 0;
          const int latchBlocks = static_cast<int>(std::ceil((rate * .005 + 1) / kBlock));
          for (int block = 0; block < latchBlocks; ++block) { toggled.run(true); faded.run(true); }
          for (int block = 0; block < 64; ++block) {
            toggled.run(false, 8); faded.run(false, 8);
            powerReset &= toggled.difference(faded) < 2e-6;
          }
          powerReset &= toggled.finite && faded.finite && toggled.loads == 0;
        }
      }
    }
    std::printf("        neutral Power toggle max sample error %.3g, peak/reference %.6f (%g Hz, mode %d)\n",
                worstPowerDifference, worstPowerPeakRatio, rate, mode);
    check(powerNeutral, "neutral Power OFF/ON preserves active Tube throughout identical fades, both profiles and hot levels");
    check(powerReset, "nonneutral Power OFF resets old Power controls without restarting unchanged Tube character");

    // Do not hide a reset burst by waiting for steady state or feeding silence
    // through the fade. Bound the entire hot transition by its two endpoints.
    for (bool power : {false, true}) {
      bool bounded = true, quiet = true, zeroExact = true;
      double worstRatio = 0;
      for (float presence : {-12.0f, 12.0f}) {
        for (float depth : {-12.0f, 12.0f}) {
          for (const auto& dynamic : {std::array<float, 2>{-100, 0}, {-100, 100},
                                      {100, 0}, {100, 100}}) {
            for (float character : {0.0f, 100.0f}) {
              Controls c = defaults(mode);
              c[port(Rack::Power)] = power;
              c[34] = presence; c[35] = depth; c[36] = c[41] = 100;
              c[37] = dynamic[0]; c[38] = dynamic[1];
              c[kPowerTubeTypePort] = PowerTube::k6L6;
              c[kPowerTubeCharacterPort] = character;
              Host switched(d, rate, c), reference(d, rate, c);
              const auto peak = [](const Host& h) {
                double value = 0;
                for (size_t i = 0; i < kBlock; ++i)
                  value = std::max({value, std::fabs(static_cast<double>(h.left[i])),
                                   std::fabs(static_cast<double>(h.right[i]))});
                return value;
              };
              const int warmBlocks = static_cast<int>(std::ceil(rate * .5 / kBlock));
              const int transitionBlocks = static_cast<int>(std::ceil(rate * .15 / kBlock));
              double before = 0;
              for (int block = 0; block < warmBlocks; ++block) {
                switched.run(false, 4); reference.run(false, 4);
                if (block >= warmBlocks - transitionBlocks / 3) before = std::max(before, peak(switched));
              }
              for (int edit = 0; edit < 6; ++edit) {
                if (edit == 2 || edit == 3) switched.controls[port(Rack::PowerTube)] = edit == 3;
                else switched.controls[kPowerTubeTypePort] = static_cast<float>(
                    edit == 1 ? PowerTube::k6L6 : edit == 4 ? PowerTube::kCaptured : PowerTube::kEL34);
                // Character 0 must retain the exact charged legacy state even
                // across bypass fades. Give the reference the same rack fade.
                if (edit == 2 || edit == 3) reference.controls[port(Rack::PowerTube)] = edit == 3;
                double during = 0, after = 0;
                for (int block = 0; block < transitionBlocks; ++block) {
                  switched.run(false, 4); reference.run(false, 4);
                  during = std::max(during, peak(switched));
                  if (block >= transitionBlocks * 2 / 3) after = std::max(after, peak(switched));
                  if (character == 0) zeroExact &= switched.difference(reference) == 0;
                }
                const double endpoint = std::max(before, after);
                worstRatio = std::max(worstRatio, during / std::max(endpoint, 1e-9));
                // Allow profile/DC-filter settling, but not the former 28 dB
                // burst from restarting the 15 ms Master/Sag smoothers.
                bounded &= during <= 1.6 * endpoint + .002;
                before = after;
              }
              for (int block = 0; block < warmBlocks; ++block) switched.run(true);
              for (int edit = 0; edit < 4; ++edit) {
                if (edit < 2) switched.controls[kPowerTubeTypePort] = static_cast<float>(
                    edit == 0 ? PowerTube::k6L6 : PowerTube::kEL34);
                else switched.controls[port(Rack::PowerTube)] = edit == 3;
                for (int block = 0; block < transitionBlocks / 3; ++block) {
                  switched.run(true);
                  quiet &= peak(switched) < 1e-5;
                }
              }
              bounded &= switched.finite && switched.loads == 0 && reference.loads == 0;
            }
          }
        }
      }
      char label[220];
      std::printf("        tube transition worst peak/endpoint %.3f (%+.2f dB)\n",
                  worstRatio, 20 * std::log10(worstRatio));
      std::snprintf(label, sizeof(label),
          "hot tube type/bypass transitions bounded at Master/Sag 100, +/- voicing/bias, NFB extremes, Power %s (%g Hz, mode %d)",
          power ? "ON" : "OFF", rate, mode);
      check(bounded, label);
      check(quiet, "charged tube type/bypass transitions on silence emit no DC pops, including both OFF");
      check(zeroExact, "Character 0 type/bypass transitions preserve exact legacy Power history");
    }

    // Both OFF skips the shared engine. It must still discard tube character
    // before a zero-amount re-enable, without resetting any Power history.
    Controls inactive = defaults(mode);
    inactive[port(Rack::Power)] = 0;
    nonneutral(inactive, Rack::PowerTube);
    Host oldCharacter(d, rate, inactive);
    for (int block = 0; block < 200; ++block) oldCharacter.run(false, 4);
    oldCharacter.controls[port(Rack::PowerTube)] = 0;
    // Let the downstream 5 Hz DC blocker settle to the same dry history.
    for (int block = 0; block < static_cast<int>(std::ceil(rate * .5 / kBlock)); ++block)
      oldCharacter.run(false, 4);
    Controls dryControls = oldCharacter.controls;
    dryControls[kPowerTubeCharacterPort] = 0;
    Host dryReference(d, rate, dryControls);
    while (dryReference.position < oldCharacter.position) dryReference.run(false, 4);
    oldCharacter.controls[kPowerTubeCharacterPort] = 0;
    oldCharacter.controls[port(Rack::PowerTube)] = dryReference.controls[port(Rack::PowerTube)] = 1;
    bool noStaleCharacter = true;
    for (int block = 0; block < 64; ++block) {
      oldCharacter.run(false, 4); dryReference.run(false, 4);
      noStaleCharacter &= oldCharacter.difference(dryReference) < 1e-6;
    }
    check(noStaleCharacter, "both OFF clears only tube character; re-enable at amount 0 has no stale saturation");

    // A charged nonlinear Power envelope makes an accidental shared-stage reset
    // observable. Compare every block, including immediately after selector edits.
    for (bool off : {false, true}) {
      Controls c = defaults(mode);
      nonneutral(c, Rack::Power);
      c[port(Rack::PowerTube)] = off ? 0 : 1;
      c[kPowerTubeCharacterPort] = off ? 100 : 0;
      Host edited(d, rate, c), untouched(d, rate, c);
      for (int block = 0; block < 150; ++block) { edited.run(); untouched.run(); }
      bool continuous = true;
      for (int profile : {PowerTube::k6L6, PowerTube::kEL34, PowerTube::kCaptured, PowerTube::kEL34}) {
        edited.controls[kPowerTubeTypePort] = static_cast<float>(profile);
        for (int block = 0; block < 32; ++block) {
          edited.run(); untouched.run();
          continuous &= edited.difference(untouched) == 0;
        }
      }
      char label[200];
      std::snprintf(label, sizeof(label), "selector edits with %s preserve charged Power history exactly, no fades/reloads (%g Hz, mode %d)",
                    off ? "Tube OFF" : "Character 0", rate, mode);
      check(continuous && edited.loads == 0 && edited.controls[kPowerTubeTypePort] == PowerTube::kEL34, label);

      // Restore audibility using the last offline selection, without selecting it
      // again. Match a host that already stored that selection through the same fade.
      Controls saved = c;
      saved[kPowerTubeTypePort] = PowerTube::kEL34;
      Host stored(d, rate, saved);
      while (stored.position < edited.position) stored.run();
      edited.controls[port(Rack::PowerTube)] = stored.controls[port(Rack::PowerTube)] = 1;
      edited.controls[kPowerTubeCharacterPort] = stored.controls[kPowerTubeCharacterPort] = 100;
      double restored = 0;
      bool selection = true;
      for (int block = 0; block < 300; ++block) {
        edited.run(false, 4); stored.run(false, 4); untouched.run(false, 4);
        selection &= edited.difference(stored) == 0;
        if (block > 200) restored += edited.difference(untouched);
      }
      check(selection && restored > .01 && edited.loads == 0,
            off ? "Tube ON restores the selector edited while OFF without reload"
                : "raising Character restores the selector edited at amount 0 without reload");
    }

    for (bool power : {false, true}) {
      Controls c = defaults(mode);
      if (power) nonneutral(c, Rack::Power);
      c[port(Rack::Power)] = power;
      for (int profile : {PowerTube::k6L6, PowerTube::kEL34}) {
        Controls zero = c;
        zero[kPowerTubeTypePort] = static_cast<float>(profile);
        zero[kPowerTubeCharacterPort] = 0;
        Host amountZero(d, rate, zero);
        Host fresh(d, rate, c);
        for (int block = 0; block < 180; ++block) {
          amountZero.run(); fresh.run();
          neutral &= amountZero.difference(fresh) == 0;
        }
      }
    }
    check(neutral, "Character 0 matches Captured exactly with Power ON or OFF");

    for (size_t missing : {port(Rack::PowerTube), size_t{kPowerTubeTypePort}, size_t{kPowerTubeCharacterPort}}) {
      Controls c = defaults(mode);
      nonneutral(c, Rack::PowerTube);
      Controls expected = c;
      if (missing == kPowerTubeTypePort) expected[missing] = PowerTube::kCaptured;
      else if (missing == kPowerTubeCharacterPort) expected[missing] = kPowerTubeCharacterDefault;
      Host disconnected(d, rate, expected), connected(d, rate, expected);
      // Retain nondefault host storage to prove the null pointer supplies defaults.
      disconnected.controls[missing] = missing == port(Rack::PowerTube) ? 0 : c[missing];
      d->connect_port(disconnected.instance, static_cast<uint32_t>(missing), nullptr);
      for (int block = 0; block < 180; ++block) {
        disconnected.run(false, 4); connected.run(false, 4);
        nullSafe &= disconnected.difference(connected) == 0;
      }
      nullSafe &= disconnected.finite && disconnected.loads == 0;
    }
    check(nullSafe, "each optional Tube port independently defaults safely when connected to null");

    bool sanitized = true;
    for (float selector : {-1000.0f, 1000.0f, std::numeric_limits<float>::quiet_NaN(),
                           std::numeric_limits<float>::infinity()}) {
      Controls c = defaults(mode);
      c[kPowerTubeTypePort] = selector;
      c[kPowerTubeCharacterPort] = std::numeric_limits<float>::quiet_NaN();
      Controls expected = c;
      expected[kPowerTubeTypePort] = selector == 1000 ? PowerTube::kEL34 : PowerTube::kCaptured;
      expected[kPowerTubeCharacterPort] = kPowerTubeCharacterDefault;
      Host invalid(d, rate, c), fallback(d, rate, expected);
      for (int block = 0; block < 180; ++block) {
        invalid.run(false, 4); fallback.run(false, 4);
        sanitized &= invalid.difference(fallback) == 0;
      }
      sanitized &= invalid.finite && invalid.loads == 0;
    }
    check(sanitized, "plugin clamps extreme/nonfinite Tube selectors and Character to finite exact fallback audio");
  }

  // Power bypass must disconnect NFB from an enabled speaker impedance model.
  Controls free = defaults(0);
  nonneutral(free, Rack::Speaker);
  free[port(Rack::Power)] = 0;
  Controls damped = free;
  nonneutral(damped, Rack::Power);
  Host freeSpeaker(d, 48000, free), powerOff(d, 48000, damped);
  bool damping = true;
  for (int block = 0; block < 200; ++block) {
    freeSpeaker.run(); powerOff.run();
    damping &= freeSpeaker.difference(powerOff) == 0;
  }
  check(damping, "Power OFF skips presence/depth and cannot damp the enabled Speaker through NFB");

  // Zero-input warmup leaves identical filter histories while charging the
  // damping smoother. Both hosts toggle Power together, so their fade gains
  // match; compare the first audible block after the fade-out latch.
  Controls undamped = defaults(0);
  undamped[42] = SpeakerDynamics::kModern412;
  undamped[43] = undamped[44] = undamped[45] = 0; undamped[46] = 100;
  Controls charged = undamped; charged[38] = 100;
  Host noNfb(d, 48000, undamped), chargedNfb(d, 48000, charged);
  for (int block = 0; block < 400; ++block) { noNfb.run(true); chargedNfb.run(true); }
  noNfb.controls[port(Rack::Power)] = chargedNfb.controls[port(Rack::Power)] = 0;
  for (int block = 0; block < 2; ++block) { noNfb.run(true); chargedNfb.run(true); }
  noNfb.run(); chargedNfb.run();
  check(noNfb.difference(chargedNfb) < 1e-6,
        "Power OFF snaps previously charged Speaker damping at the latch, without a 10 ms residual glide");

  Controls room = defaults(0);
  room[33] = 70; room[port(Rack::Reverb)] = 0;
  Controls plate = room;
  plate[54] = 85;
  Host roomOnly(d, 48000, room), plateOff(d, 48000, plate), dry(d, 48000, defaults(0));
  bool independent = true;
  double roomEnergy = 0;
  for (int block = 0; block < 300; ++block) {
    roomOnly.run(); plateOff.run(); dry.run();
    independent &= roomOnly.difference(plateOff) == 0;
    if (block > 200) roomEnergy += roomOnly.difference(dry);
  }
  check(independent && roomEnergy > .01, "Reverb OFF suppresses plate wet but leaves Spatial Room audible");

  // Room shares Size/Damping/Predelay with the plate. Disabling plate wet is
  // not equivalent to substituting default shaping values for those controls.
  Controls shaped = defaults(0);
  shaped[33] = 75; shaped[55] = 90; shaped[56] = 15; shaped[57] = 85; shaped[58] = 65;
  Controls shapedOff = shaped;
  shapedOff[54] = 80; shapedOff[port(Rack::Reverb)] = 0;
  Host shapedRoom(d, 48000, shaped), bypassPlate(d, 48000, shapedOff);
  bool sharedShaping = true;
  for (int block = 0; block < 300; ++block) {
    shapedRoom.run(); bypassPlate.run();
    sharedShaping &= shapedRoom.difference(bypassPlate) < 1e-6;
  }
  shapedRoom.controls[56] = bypassPlate.controls[56] = 95;
  shapedRoom.controls[57] = bypassPlate.controls[57] = 10;
  shapedRoom.controls[58] = bypassPlate.controls[58] = 5;
  for (int block = 0; block < 300; ++block) {
    shapedRoom.run(); bypassPlate.run();
    sharedShaping &= shapedRoom.difference(bypassPlate) < 1e-6;
  }
  check(sharedShaping, "plate OFF retains non-default shared Room shaping and live Size/Damping/Predelay edits");

  for (Rack disabled : {Rack::Spatial, Rack::Reverb}) {
    Controls both = shaped;
    both[54] = 75;
    Controls remaining = both;
    remaining[disabled == Rack::Spatial ? 33 : 54] = 0;
    Host switched(d, 48000, both), untouched(d, 48000, remaining);
    for (int block = 0; block < 300; ++block) { switched.run(); untouched.run(); }
    switched.controls[port(disabled)] = 0;
    for (int block = 0; block < 16; ++block) { switched.run(true); untouched.run(true); }
    bool history = true;
    double wetTail = 0;
    for (int block = 0; block < 80; ++block) {
      switched.run(true); untouched.run(true);
      history &= switched.difference(untouched) < 1e-6;
      for (size_t i = 0; i < kBlock; ++i)
        wetTail += std::fabs(untouched.left[i]) + std::fabs(untouched.right[i]);
    }
    check(history && wetTail > .01, disabled == Rack::Spatial
        ? "Spatial OFF preserves the already-running plate wet tail and shared shaping"
        : "Reverb OFF preserves the already-running Room history and shared shaping");
  }

  for (Rack bypassed : {Rack::Transformer, Rack::Speaker}) {
    Controls quiet = defaults(0);
    quiet[port(bypassed)] = 0;
    Host editedOff(d, 48000, quiet), dryReference(d, 48000, quiet);
    for (int block = 0; block < 100; ++block) { editedOff.run(); dryReference.run(); }
    nonneutral(editedOff.controls, bypassed);
    bool noDip = true;
    for (int block = 0; block < 32; ++block) {
      editedOff.run(); dryReference.run();
      noDip &= editedOff.difference(dryReference) == 0;
    }
    check(noDip, bypassed == Rack::Transformer
        ? "Transformer profile edits while rack OFF never fade the dry chain"
        : "Speaker profile edits while rack OFF never fade the dry chain");
  }

  for (int blocksBeforeRequest : {1, 3}) {
    Controls wet = defaults(0);
    wet[54] = 80; wet[55] = 95;
    Host queued(d, 48000, wet), modelTransition(d, 48000, wet);
    for (int block = 0; block < 300; ++block) { queued.run(); modelTransition.run(); }
    queued.controls[8] = modelTransition.controls[8] = 0;
    for (int block = 0; block < blocksBeforeRequest; ++block) {
      queued.run(true); modelTransition.run(true);
    }
    queued.controls[port(Rack::Sculpt)] = 0;
    queued.run(true); modelTransition.run(true);
    check(queued.difference(modelTransition) < 1e-6, blocksBeforeRequest == 1
        ? "rack request during non-rack fade-out does not retroactively fade the plate tail"
        : "rack request during non-rack fade-in waits rather than interrupting the plate tail");
  }

  for (Rack rack : {Rack::Delay, Rack::Reverb, Rack::Spatial}) {
    Controls c = defaults(0);
    nonneutral(c, rack);
    Host tail(d, 48000, c), reference(d, 48000, defaults(0));
    for (int block = 0; block < 200; ++block) { tail.run(); reference.run(); }
    tail.controls[port(rack)] = reference.controls[port(rack)] = 0;
    // 16 blocks exceed the two 5 ms legs, but are far shorter than the FX tail.
    for (int block = 0; block < 16; ++block) { tail.run(true); reference.run(true); }
    bool dryTail = true;
    for (int block = 0; block < 100; ++block) {
      tail.run(true); reference.run(true);
      dryTail &= tail.difference(reference) < 1e-6;
    }
    check(dryTail, rack == Rack::Delay ? "Delay OFF has no residual wet tail"
        : rack == Rack::Reverb ? "Reverb OFF has no residual plate wet" : "Spatial OFF has no Room reflections");
  }

  Fixtures fixtures(48000);
  Controls c = defaults(0);
  c[port(Rack::Spatial)] = 0;
  Host a(d, 48000, c, &fixtures);
  Controls bControls = c;
  bControls[9] = 0; bControls[47] = 1;
  Host b(d, 48000, bControls, &fixtures);
  c[47] = 1;
  Host pair(d, 48000, c, &fixtures);
  c[32] = 100; c[33] = 80;
  Host widthIgnored(d, 48000, c, &fixtures);
  bool stereoMix = true;
  double stereo = 0;
  for (int block = 0; block < 200; ++block) {
    a.run(); b.run(); pair.run(); widthIgnored.run();
    stereoMix &= pair.difference(widthIgnored) == 0;
    for (size_t i = 0; i < kBlock; ++i) {
      stereoMix &= std::fabs(pair.left[i] - (a.left[i] + b.left[i]) * std::sqrt(.5f)) < 2e-6f;
      stereoMix &= std::fabs(pair.right[i] - (a.right[i] + b.right[i]) * std::sqrt(.5f)) < 2e-6f;
      stereo += std::fabs(a.left[i] - a.right[i]);
    }
  }
  check(stereoMix && stereo > 1, "Spatial OFF preserves WAV L/R and equal-power dual-cab channels independently of Width/Room");

  for (float alignment : {-10.0f, 10.0f}) {
    Controls aligned = defaults(0);
    aligned[8] = 0; // WAV-only chain avoids unrelated post-model DC history.
    aligned[47] = 1; aligned[49] = alignment; aligned[port(Rack::Spatial)] = 0;
    Controls bypassed = aligned; bypassed[port(Rack::CabConsole)] = 0;
    Host primed(d, 48000, aligned, &fixtures), enabling(d, 48000, bypassed, &fixtures);
    for (int block = 0; block < 300; ++block) { primed.run(); enabling.run(); }
    // Fade both hosts identically; only the tested host changes alignment.
    primed.controls[port(Rack::Sculpt)] = 0;
    enabling.controls[port(Rack::CabConsole)] = 1;
    for (int block = 0; block < 2; ++block) { primed.run(true); enabling.run(true); }
    bool retained = true;
    for (int block = 0; block < 8; ++block) {
      primed.run(true); enabling.run(true);
      retained &= primed.difference(enabling) < 1e-6;
    }
    check(retained, alignment < 0
        ? "Console ON primes Cab A signed alignment immediately without discarding buffered audio"
        : "Console ON primes Cab B signed alignment immediately without discarding buffered audio");
  }

  // At 44.1 kHz, clamping the nominal 20 kHz neutral cut to 0.45*rate
  // accidentally enables it. OFF must bypass the filters, not fake neutral Hz.
  Fixtures cuts(44100);
  c = defaults(0); c[port(Rack::Spatial)] = c[port(Rack::CabConsole)] = 0;
  Controls edited = c;
  nonneutral(edited, Rack::CabConsole);
  Host uncut(d, 44100, c, &cuts), cutOff(d, 44100, edited, &cuts);
  Controls enabled = c; enabled[port(Rack::CabConsole)] = 1;
  Host clamped(d, 44100, enabled, &cuts);
  bool cutsBypassed = true;
  double cutDifference = 0;
  for (int block = 0; block < 200; ++block) {
    uncut.run(); cutOff.run(); clamped.run();
    cutsBypassed &= uncut.difference(cutOff) == 0;
    cutDifference += uncut.difference(clamped);
  }
  check(cutsBypassed && cutDifference > 1e-4, "Console OFF really bypasses cabinet cuts at 44.1 kHz, including the clamped neutral high cut");

  c = defaults(6); c[47] = 1; c[port(Rack::Spatial)] = c[port(Rack::CabConsole)] = 0;
  edited = c;
  nonneutral(edited, Rack::CabConsole);
  c[port(Rack::CabConsole)] = 1;
  Host compensated(d, 96000, c, nullptr, false, true), consoleOff(d, 96000, edited, nullptr, false, true);
  bool compensation = true;
  for (int block = 0; block < 200; ++block) {
    compensated.run(); consoleOff.run();
    compensation &= compensated.difference(consoleOff) < 1e-6;
  }
  check(compensation && compensated.controls[29] == 82,
        "Console OFF ignores signed user alignment and polarity but retains True-cab converter latency compensation");

  // With no models or effects, audio/input is exactly the global transition
  // gain. A one-sample host block exposes the latch/fade timeline directly.
  Host fade(d, 48000, defaults(0));
  fade.controls[8] = 0;
  for (int block = 0; block < 16; ++block) fade.run(true);
  bool clickSafe = true;
  for (size_t rack = 0; rack < kRackCount; ++rack) {
    for (float enabledValue : {0.0f, 1.0f}) {
      fade.controls[kRackControlFirstPort + rack] = enabledValue;
      float previous = 1, minimum = 1;
      for (int sample = 0; sample < 600; ++sample) {
        fade.input[0] = .25f;
        reinterpret_cast<LV2_Atom_Sequence*>(fade.notify.data())->atom.size = kAtomBytes - sizeof(LV2_Atom);
        d->run(fade.instance, 1);
        const float gain = fade.left[0] / .25f;
        if (sample == 0) clickSafe &= std::fabs(gain - 1) < 1e-6;
        if (sample == 120) clickSafe &= std::fabs(gain - std::sqrt(.5f)) < .02f;
        if (sample == 240) clickSafe &= gain < .02f;
        minimum = std::min(minimum, gain);
        clickSafe &= std::isfinite(gain) && std::fabs(gain - previous) < .02f;
        previous = gain;
      }
      clickSafe &= minimum < .01f && previous == 1;
    }
  }
  check(clickSafe, "every rack OFF/ON rides the existing 5 ms global fade-out/latch/fade-in");
}
} // namespace

int main(int argc, char** argv) {
  if (argc != 2) { std::puts("usage: verify_rack_bypass <fresh rig .so>"); return 2; }
  void* library = dlopen(argv[1], RTLD_NOW);
  if (!library) { std::fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
  try {
    auto descriptor = reinterpret_cast<const LV2_Descriptor* (*)(uint32_t)>(dlsym(library, "lv2_descriptor"));
    require(descriptor && descriptor(0), "rig descriptor exported");
    verify(descriptor(0));
  } catch (const std::exception& error) {
    check(false, error.what());
  }
  dlclose(library);
  std::printf("\n%d failures\n", failures);
  return failures ? 1 : 0;
}
