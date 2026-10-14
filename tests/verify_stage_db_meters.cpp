// Behavioral regression through a freshly built LV2 descriptor, not a DSP copy.
// Build: clang++ -O2 -std=c++17 -D_DARWIN_C_SOURCE -Isrc -Ideps/lv2/include \
//   -Ideps/NeuralAudio -Ideps/NeuralAudio/deps/RTNeural/modules/json \
//   tests/verify_stage_db_meters.cpp -o <test>
// Usage: <test> build/src/neural_amp_modeler_rig.so
#include "nam_rig_plugin.h"

#include <lv2/atom/util.h>
#include <dlfcn.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
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
constexpr double kRate = 96000.0, kPi = 3.14159265358979323846;
constexpr float kDbTolerance = 0.55f; // The notify stream is change-gated at 0.5 dB.
using Controls = std::array<float, Plugin::kPortCount>;
enum Meter { Input, Pre, Post, Output, MeterCount };
int failures = 0;

void require(bool ok, const char* label) {
  if (!ok) throw std::runtime_error(label);
}
void check(bool ok, const std::string& label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label.c_str());
  if (!ok) ++failures;
}
float db(float peak) { return peak > 1e-9f ? 20.0f * std::log10(peak) : -120.0f; }
float linear(float value) { return std::pow(10.0f, value / 20.0f); }
int factor(int mode) { return mode == 0 ? 1 : 1 << (mode - kOversampleTrue2 + 1); }
std::string domain(int mode) {
  return mode == 0 ? "base" : "True " + std::to_string(factor(mode)) + "x";
}

class Model final : public NeuralAudio::NeuralModel {
 public:
  enum Kind { Gain, Zero, Carrier } kind;
  float gain, inputPeak = 0, outputPeak = 0;
  size_t samples = 0, calls = 0, position = 0;
  explicit Model(float multiplier = 1, Kind behavior = Gain) : kind(behavior), gain(multiplier) {}
  float GetRecommendedInputDBAdjustment() override { return 0; }
  float GetRecommendedOutputDBAdjustment() override { return 0; }
  void resetObservation() { inputPeak = outputPeak = 0; samples = calls = 0; }
  void Process(float* input, float* output, size_t count) override {
    ++calls;
    samples += count;
    for (size_t i = 0; i < count; ++i) {
      inputPeak = std::max(inputPeak, std::fabs(input[i]));
      // A quarter-domain-rate carrier is at/above base Nyquist in every True mode.
      // It distinguishes an amp-domain POST tap from one after decimation.
      const float carrier[] = {0, .3f, 0, -.3f};
      const float y = kind == Zero ? 0 : kind == Carrier ? carrier[position++ % 4] : input[i] * gain;
      output[i] = y;
      outputPeak = std::max(outputPeak, std::fabs(y));
    }
  }
};

Controls defaults(int mode) {
  Controls c{};
  c[6] = c[7] = c[8] = c[9] = 1;
  c[15] = -80;
  c[20] = c[21] = static_cast<float>(mode);
  c[23] = 150;
  c[24] = 3;
  c[27] = 20000;
  c[43] = c[44] = 25;
  c[45] = c[46] = 50;
  c[50] = 400; c[51] = 35; c[52] = 40;
  c[55] = c[56] = c[57] = 50; c[58] = 10;
  std::copy(kTransformerControlDefaults.begin(), kTransformerControlDefaults.end(),
            c.begin() + kTransformerControlFirstPort);
  std::copy(kRackControlDefaults.begin(), kRackControlDefaults.end(), c.begin() + kRackControlFirstPort);
  c[kPowerTubeCharacterPort] = kPowerTubeCharacterDefault;
  const auto pins = pinEqDefaults();
  std::copy(pins.begin(), pins.end(), c.begin() + kPinEqFirstPort);
  c[kOverdriveTonePort] = Overdrive::kToneDefault;
  return c;
}

void pin(Controls& c, PinEqPane pane, float gain) {
  c[pinEqPort(pane, 0, kPinShape)] = kPinBell;
  c[pinEqPort(pane, 0, kPinFreq)] = 1500;
  c[pinEqPort(pane, 0, kPinGain)] = gain;
  c[pinEqPort(pane, 0, kPinQ)] = 1;
}
Controls shaped(int mode) {
  auto c = defaults(mode);
  c[4] = -3; c[5] = -6; c[22] = 12; c[25] = -9;
  pin(c, PinEqPane::Sculpt, 6);
  pin(c, PinEqPane::Transformer, 5);
  pin(c, PinEqPane::Speaker, 3);
  return c;
}

struct WavFixture {
  std::filesystem::path path = std::filesystem::temp_directory_path() /
      ("stage-db-meters-" + std::to_string(getpid()) + ".wav");
  WavFixture() {
    std::ofstream file(path, std::ios::binary);
    auto little = [&](uint32_t value, unsigned bytes) {
      for (unsigned i = 0; i < bytes; ++i) file.put(static_cast<char>(value >> (8 * i)));
    };
    constexpr uint32_t frames = 32, bytes = frames * 2;
    file.write("RIFF", 4); little(36 + bytes, 4); file.write("WAVEfmt ", 8);
    little(16, 4); little(1, 2); little(1, 2); little(static_cast<uint32_t>(kRate), 4);
    little(static_cast<uint32_t>(kRate) * 2, 4); little(2, 2); little(16, 2);
    file.write("data", 4); little(bytes, 4);
    for (uint32_t i = 0; i < frames; ++i) little(i == 0 ? 4096 : 0, 2);
    file.close();
    require(static_cast<bool>(file), "write gain-only WAV fixture");
  }
  ~WavFixture() { std::error_code error; std::filesystem::remove(path, error); }
};

struct Host {
  const LV2_Descriptor* descriptor;
  const LV2_Worker_Interface* worker;
  LV2_Handle instance = nullptr;
  std::vector<std::string> uris;
  std::deque<std::vector<uint8_t>> jobs;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  Controls controls;
  std::array<Model*, kStageCount> models{};
  std::array<float, 2048> input{}, left{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, kAtomBytes> control{}, notify{};
  std::array<float, MeterCount> readings;
  std::array<unsigned, MeterCount> notifications{};
  size_t position = 0;
  uint32_t block = kBlock;
  float outputPeak = 0;
  bool finite = true, loadedWav = false, latePeak = false;

  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& ids = static_cast<Host*>(handle)->uris;
    const auto found = std::find(ids.begin(), ids.end(), uri);
    if (found != ids.end()) return static_cast<LV2_URID>(found - ids.begin() + 1);
    ids.emplace_back(uri);
    return static_cast<LV2_URID>(ids.size());
  }
  LV2_URID id(const char* uri) { return mapUri(this, uri); }
  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                       uint32_t size, const void* data) {
    auto& host = *static_cast<Host*>(handle);
    const auto* bytes = static_cast<const uint8_t*>(data);
    host.jobs.emplace_back(bytes, bytes + size);
    return LV2_WORKER_SUCCESS;
  }
  static LV2_Worker_Status respond(LV2_Worker_Respond_Handle handle, uint32_t size, const void* data) {
    auto& host = *static_cast<Host*>(handle);
    const auto& message = *static_cast<const LV2SwitchModelMsg*>(data);
    require(message.ir && !message.model, "worker response contains a real WAV IR");
    host.loadedWav = true;
    return host.worker->work_response(host.instance, size, data);
  }
  Host(const LV2_Descriptor* d, Controls values)
      : descriptor(d), worker(static_cast<const LV2_Worker_Interface*>(
            d->extension_data(LV2_WORKER__interface))), controls(values) {
    readings.fill(std::numeric_limits<float>::quiet_NaN());
    LV2_Feature mapFeature{LV2_URID__map, &map}, workerFeature{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mapFeature, &workerFeature, nullptr};
    instance = d->instantiate(d, kRate, "", features);
    require(instance && worker, "instantiate rig and worker interface");
    d->connect_port(instance, 0, control.data());
    d->connect_port(instance, 1, notify.data());
    d->connect_port(instance, 2, input.data());
    d->connect_port(instance, 3, left.data());
    d->connect_port(instance, 31, right.data());
    for (uint32_t p = 4; p < Plugin::kPortCount; ++p)
      if (p != 31) d->connect_port(instance, p, &controls[p]);
    run(0); // Latch modes and retain the initial -120 dB notifications.
  }
  ~Host() { if (instance) descriptor->cleanup(instance); }
  Model* install(Stage stage, float gain = 1, Model::Kind kind = Model::Gain) {
    auto* model = new Model(gain, kind);
    const size_t index = static_cast<size_t>(stage);
    require(!models[index], "each custom model is installed once");
    const int mode = stage == Stage::Cab2 ? kOversampleLegacy
        : static_cast<int>(controls[stage == Stage::Pedal ? 20 : 21]);
    LV2SwitchModelMsg message{kWorkTypeSwitch, stage, mode, 0, {}, model, nullptr, nullptr, false};
    require(worker->work_response(instance, sizeof(message), &message) == LV2_WORKER_SUCCESS,
            "install custom model through work_response");
    models[index] = model;
    return model;
  }
  void installWav(const WavFixture& fixture) {
    LV2LoadModelMsg message{kWorkTypeLoad, Stage::Cab, static_cast<int>(controls[21]), 0, {}};
    const auto path = fixture.path.string();
    require(path.size() < sizeof(message.path), "WAV path fits worker message");
    std::strcpy(message.path, path.c_str());
    require(worker->work(instance, respond, this, sizeof(message), &message) == LV2_WORKER_SUCCESS,
            "load WAV through real LV2 worker");
    require(loadedWav, "WAV worker delivered its response");
  }
  void readNotifications() {
    const auto* sequence = reinterpret_cast<const LV2_Atom_Sequence*>(notify.data());
    require(sequence->atom.type == id(LV2_ATOM__Sequence) &&
                sequence->atom.size <= kAtomBytes - sizeof(LV2_Atom), "valid notify sequence");
    const std::array<LV2_URID, MeterCount> properties = {
        id(NAM_RIG_INPUT_DB_URI), id(NAM_RIG_PRE_AMP_DB_URI),
        id(NAM_RIG_POST_AMP_DB_URI), id(NAM_RIG_OUTPUT_DB_URI)};
    LV2_ATOM_SEQUENCE_FOREACH(sequence, event) {
      if (event->body.type != id(LV2_ATOM__Object)) continue;
      const auto* object = reinterpret_cast<const LV2_Atom_Object*>(&event->body);
      if (object->body.otype != id(LV2_PATCH__Set)) continue;
      const LV2_Atom *property = nullptr, *value = nullptr;
      lv2_atom_object_get(object, id(LV2_PATCH__property), &property,
                          id(LV2_PATCH__value), &value, 0);
      if (!property || property->type != id(LV2_ATOM__URID) ||
          property->size != sizeof(LV2_URID)) continue;
      for (size_t i = 0; i < properties.size(); ++i) {
        if (reinterpret_cast<const LV2_Atom_URID*>(property)->body != properties[i]) continue;
        require(value && value->type == id(LV2_ATOM__Float) && value->size == sizeof(float) &&
                    event->time.frames == 0, "meter is a frame-zero patch:Set float");
        readings[i] = reinterpret_cast<const LV2_Atom_Float*>(value)->body;
        require(std::isfinite(readings[i]), "meter notifications are finite");
        ++notifications[i];
      }
    }
  }
  void run(float amplitude = .08f, bool dc = false) {
    require(block > 0 && block <= input.size(), "host block fits audio buffers");
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    sequence->atom.type = id(LV2_ATOM__Sequence);
    sequence->atom.size = sizeof(LV2_Atom_Sequence_Body);
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = kAtomBytes - sizeof(LV2_Atom);
    for (auto* model : models) if (model) model->resetObservation();
    for (size_t i = 0; i < block; ++i) {
      float& x = input[i];
      x = dc ? amplitude : amplitude * static_cast<float>(std::sin(2 * kPi * 1500 * (position % 64) / kRate));
      if (latePeak && i + 512 < block) x *= .25f;
      ++position;
    }
    descriptor->run(instance, block);
    outputPeak = 0;
    for (size_t i = 0; i < block; ++i) {
      finite &= std::isfinite(left[i]) && std::isfinite(right[i]);
      outputPeak = std::max({outputPeak, std::fabs(left[i]), std::fabs(right[i])});
    }
    readNotifications();
    while (!jobs.empty()) {
      auto job = std::move(jobs.front()); jobs.pop_front();
      require(*reinterpret_cast<const LV2WorkType*>(job.data()) == kWorkTypeFree,
              "custom models do not trigger unexpected worker reloads");
      require(worker->work(instance, respond, this, static_cast<uint32_t>(job.size()), job.data()) ==
                  LV2_WORKER_SUCCESS, "free replaced models outside the audio callback");
    }
  }
  void settle(float amplitude = .08f, int blocks = 900, bool dc = false) {
    for (int block = 0; block < blocks; ++block) run(amplitude, dc);
  }
  void expect(Meter meter, float expected, const std::string& label) const {
    const bool ok = notifications[meter] && std::fabs(readings[meter] - expected) <= kDbTolerance;
    check(ok, label);
    if (!ok) std::printf("        notified %.3f dB, expected %.3f dB (+/- %.2f), messages %u\n",
                         readings[meter], expected, kDbTolerance, notifications[meter]);
  }
};

void slicedPlacement(const LV2_Descriptor* d, int pedalMode, int ampMode, bool active = true) {
  auto c = shaped(ampMode);
  c[20] = static_cast<float>(pedalMode);
  c[8] = active ? 1 : 0;
  Host host(d, c);
  host.block = 2048;
  host.latePeak = true; // A missed later fallback slice must not hide behind equal peaks.
  auto* pedal = host.install(Stage::Pedal, .5f);
  auto* amp = host.install(Stage::Amp, .5f);
  auto* cab = host.install(Stage::Cab, .125f);
  host.settle(.08f, 150);
  const auto label = "2048 frames " + domain(pedalMode) + " pedal / " + domain(ampMode) +
      (active ? " amp+cab" : " bypassed amp+cab");
  host.expect(Pre, db(active ? amp->inputPeak : cab->inputPeak), label + ": PRE aggregates sliced inputs");
  host.expect(Post, db(cab->inputPeak), label + ": POST aggregates pre-cab peaks across slices");
  check(pedal->calls == 4 && amp->calls == (active ? 4u : 0u) && cab->calls == 4 &&
            pedal->samples == host.block * factor(pedalMode) &&
            amp->samples == (active ? host.block * factor(ampMode) : 0) &&
            cab->samples == host.block * factor(ampMode) && host.finite,
        label + ": four 512-frame slices preserve each model's domain and finite audio");
  const auto latency = [](int mode) { return factor(mode) == 2 ? 23 : factor(mode) == 4 ? 35 :
      factor(mode) == 8 ? 41 : 44; };
  check(host.controls[29] == latency(ampMode) + (active && pedalMode == ampMode ? 0 : latency(pedalMode)),
        label + ": latency confirms merged or unequal-factor domains, counted once per host block");
  const float post = host.readings[Post];
  cab->gain = 2;
  host.settle(.08f, 100);
  host.expect(Post, post, label + ": sliced POST stays independent of cabinet gain");
}

void placement(const LV2_Descriptor* d, int mode, bool pedal, bool parallel) {
  auto c = shaped(mode);
  c[47] = parallel ? 1 : 0;
  Host host(d, c);
  if (pedal) host.install(Stage::Pedal, .5f);
  auto* amp = host.install(Stage::Amp, .5f);
  auto* cab = host.install(Stage::Cab, .125f);
  auto* cabB = parallel ? host.install(Stage::Cab2, .03125f) : nullptr;
  host.settle();
  const std::string label = domain(mode) + (parallel ? " parallel NAM cabs" :
      pedal ? " pedal+amp+NAM cab" : " amp+NAM cab");
  host.expect(Input, db(.08f), label + ": IN remains raw");
  host.expect(Pre, db(amp->inputPeak), label + ": PRE equals actual amp input after drive/sculpt");
  host.expect(Post, db(cabB ? cabB->inputPeak : cab->inputPeak),
              label + ": POST equals pre-cab signal, not attenuated cab output");
  check(db(amp->inputPeak) - db(.08f) > 7 &&
            db(cab->inputPeak) - db(amp->outputPeak) > 7,
        label + ": nonneutral pre-sculpt and both post-amp pin panes are audible");
  check(amp->samples == kBlock * factor(mode) && cab->samples == kBlock * factor(mode) &&
            (!pedal || host.models[0]->samples == kBlock * factor(mode)) &&
            (!cabB || cabB->samples == kBlock), label + ": actual model sample counts exercise requested domains");
  const unsigned latency = mode == 0 ? 0 : factor(mode) == 2 ? 23 : factor(mode) == 4 ? 35 :
      factor(mode) == 8 ? 41 : 44;
  check(host.controls[29] == static_cast<float>(latency * (parallel ? 2 : 1)),
        label + ": latency confirms merged group or independent parallel cab domain");
  const float pre = host.readings[Pre], post = host.readings[Post], output = db(host.outputPeak);
  cab->gain = 2;
  if (cabB) cabB->gain = 1;
  host.controls[25] = -3;
  host.settle(.08f, 600);
  host.expect(Pre, pre, label + ": changing cabinet gain/trim leaves PRE unchanged");
  host.expect(Post, post, label + ": changing cabinet gain/trim leaves POST unchanged");
  check(db(host.outputPeak) - output > 12 && host.finite,
        label + ": cabinet edit really changes finite output audio");
}

void beforeDownsample(const LV2_Descriptor* d, int mode) {
  Host host(d, defaults(mode));
  auto* amp = host.install(Stage::Amp, 1, Model::Carrier);
  host.settle();
  const auto label = domain(mode) + " isolated amp";
  host.expect(Pre, db(amp->inputPeak), label + ": PRE is actual nonzero model input");
  host.expect(Post, db(amp->outputPeak), label + ": POST retains domain-rate carrier before downsampling");
  check(amp->inputPeak > .05f && amp->samples == kBlock * factor(mode) && host.finite &&
            (mode == 0 || host.outputPeak < .003f),
        label + ": carrier exists in amp domain but True converter rejects it at output");
}

void zeroAmp(const LV2_Descriptor* d, int mode) {
  Host host(d, defaults(mode));
  host.install(Stage::Pedal, .5f);
  auto* amp = host.install(Stage::Amp, 1, Model::Zero);
  auto* cab = host.install(Stage::Cab, .125f);
  host.settle(.08f, 5000); // Allow any setup/bypass readings to release fully to the floor.
  const auto label = domain(mode) + " zero-output amp";
  check(amp->inputPeak > .03f && amp->outputPeak == 0 && cab->inputPeak == 0,
        label + ": nonzero PRE really enters an amp that emits silence");
  host.expect(Pre, db(amp->inputPeak), label + ": PRE remains nonzero");
  host.expect(Post, -120, label + ": POST does not substitute PRE for a captured zero");
}

void fallback(const LV2_Descriptor* d, int mode, bool bypass) {
  auto c = shaped(mode);
  c[8] = bypass ? 0 : 1;
  Host host(d, c);
  host.install(Stage::Pedal, .5f);
  auto* amp = bypass ? host.install(Stage::Amp, 8) : nullptr;
  auto* cab = host.install(Stage::Cab, .125f);
  host.settle();
  const auto label = domain(mode) + (bypass ? " bypassed amp" : " absent amp");
  host.expect(Pre, db(cab->inputPeak), label + ": PRE falls back to post-pedal signal");
  host.expect(Post, db(cab->inputPeak), label + ": POST falls back before cabinet processing");
  check((!amp || amp->calls == 0) && std::fabs(db(cab->inputPeak) - (db(.08f) - 9.0206f)) < .1f &&
            host.finite, label + ": amp drive/sculpt/post effects stay bypassed");
}

void wavRouting(const LV2_Descriptor* d, int mode, const WavFixture& fixture) {
  Host reference(d, shaped(mode)), wav(d, shaped(mode));
  auto* amp = wav.install(Stage::Amp, .5f);
  reference.install(Stage::Amp, .5f);
  wav.installWav(fixture);
  for (int block = 0; block < 900; ++block) { reference.run(); wav.run(); }
  const auto label = domain(mode) + " deferred WAV cab";
  wav.expect(Pre, db(amp->inputPeak), label + ": PRE equals actual amp input");
  wav.expect(Post, reference.readings[Post], label + ": POST agrees with no-cab reference");
  // Original source taps (normalization=3) make this IR exactly a 1/8 gain.
  check(std::fabs(db(wav.outputPeak) - db(reference.outputPeak) + 18.0618f + 9) < .1f && wav.finite,
        label + ": WAV gain and cab trim affect output, not POST");
}

void sculptSilence(const LV2_Descriptor* d, int mode) {
  auto c = defaults(mode);
  c[40] = 100; // A DC input is rejected by Sculpt's high-pass before the amp.
  Host host(d, c);
  auto* amp = host.install(Stage::Amp);
  host.settle(.1f, 6000, true);
  const auto label = domain(mode) + " sculpt rejects DC";
  check(amp->inputPeak < 1e-9f && host.input[0] == .1f && amp->calls > 0,
        label + ": nonzero upstream input produces a meter-floor amp input");
  host.expect(Pre, -120, label + ": captured silent PRE must not use nonzero fallback");
  host.expect(Post, -120, label + ": POST is also silent");
}

void notificationGate(const LV2_Descriptor* d) {
  Host host(d, defaults(0));
  host.expect(Pre, -120, "notify: retain initial PRE notification during setup");
  host.expect(Post, -120, "notify: retain initial POST notification during setup");
  auto* amp = host.install(Stage::Amp);
  auto* cab = host.install(Stage::Cab);
  host.settle(.04f);
  const auto counts = host.notifications;
  host.settle(.04f, 100);
  check(host.notifications[Pre] == counts[Pre] && host.notifications[Post] == counts[Post],
        "notify: steady peaks do not republish PRE/POST every block");
  host.settle(.04f * linear(.2f), 300);
  check(host.notifications[Pre] == counts[Pre] && host.notifications[Post] == counts[Post],
        "notify: sub-0.5 dB amplitude change stays gated");
  host.settle(.04f * linear(1.2f), 300);
  check(host.notifications[Pre] > counts[Pre] && host.notifications[Post] > counts[Post],
        "notify: larger amplitude change republishes both meters");
  host.expect(Pre, db(amp->inputPeak), "notify: republished PRE matches actual steady model input");
  host.expect(Post, db(cab->inputPeak), "notify: republished POST matches actual steady pre-cab input");
}
} // namespace

int main(int argc, char** argv) {
  if (argc != 2) { std::printf("usage: verify_stage_db_meters <freshly built rig .so>\n"); return 1; }
  void* library = dlopen(argv[1], RTLD_NOW);
  if (!library) { std::printf("FAIL: %s\n", dlerror()); return 1; }
  try {
    auto get = reinterpret_cast<const LV2_Descriptor* (*)(uint32_t)>(dlsym(library, "lv2_descriptor"));
    require(get && get(0) && std::strcmp(get(0)->URI, NAM_RIG_URI) == 0, "load rig LV2 descriptor");
    const auto* d = get(0);
    WavFixture fixture;
    notificationGate(d);
    for (int mode : {0, kOversampleTrue2, kOversampleTrue4, kOversampleTrue8, kOversampleTrue16}) {
      placement(d, mode, true, false);
      placement(d, mode, false, false);
      placement(d, mode, true, true);
      beforeDownsample(d, mode);
      zeroAmp(d, mode);
      fallback(d, mode, true);
      fallback(d, mode, false);
      wavRouting(d, mode, fixture);
      if (mode != 0) slicedPlacement(d, mode, mode);
    }
    slicedPlacement(d, kOversampleTrue2, kOversampleTrue8);
    slicedPlacement(d, kOversampleTrue16, kOversampleTrue4);
    slicedPlacement(d, kOversampleTrue4, kOversampleTrue4, false);
    slicedPlacement(d, kOversampleTrue8, kOversampleTrue2, false);
    sculptSilence(d, 0);
  } catch (const std::exception& error) {
    check(false, std::string("harness infrastructure: ") + error.what());
  }
  dlclose(library);
  std::printf("\n%d failures\n", failures);
  return failures ? 1 : 0;
}
