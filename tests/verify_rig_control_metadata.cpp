// Portable test: link win32_presets.cpp and pass neural_amp_modeler_rig.ttl.in.
#include "rig_control_metadata.h"
#include "win32_control_defaults.h"
#include "win32_presets.h"

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <regex>
#include <set>

#include <nlohmann/json.hpp>

using namespace NAMRig;
using NAMRigWin32::PresetManager;
using NAMRigWin32::RigPreset;
using json = nlohmann::json;

static int failures = 0;
#define CHECK(condition, ...) do { \
  if (!(condition)) { \
    ++failures; \
    std::printf("  FAIL %s:%d: ", __FILE__, __LINE__); \
    std::printf(__VA_ARGS__); \
    std::printf("\n"); \
  } \
} while (0)

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s resources/neural_amp_modeler_rig.ttl.in\n", argv[0]);
    return 1;
  }

  std::array<float, kRigControlPortCount> hostDefaults{};
  std::array<bool, kRigControlPortCount> initialized{};
  size_t defaultCount = 0;
  NAMRigWin32::forEachWin32ControlDefault([&](uint32_t port, float value) {
    CHECK(port < hostDefaults.size(), "default port in host storage at %u", port);
    if (port >= hostDefaults.size()) return;
    CHECK(!initialized[port], "initialize default port %u once", port);
    initialized[port] = true;
    hostDefaults[port] = value;
    ++defaultCount;
  });
  const RigPreset defaultPreset = RigPreset::createDefault();
  CHECK(defaultCount == 77 && defaultPreset.controls.size() == 77, "exact Windows default key coverage");
  const std::map<uint32_t, float> nonzeroStaticDefaults = {
      {7, 1.0f}, {8, 1.0f}, {9, 1.0f}, {15, -80.0f},
      {20, static_cast<float>(kOversampleTrue8)}, {21, static_cast<float>(kOversampleTrue8)},
      {23, 150.0f}, {24, 2.0f}, {27, 20000.0f}, {43, 25.0f}, {44, 25.0f},
      {45, 50.0f}, {46, 50.0f}, {50, 400.0f}, {51, 35.0f}, {52, 40.0f},
      {55, 50.0f}, {56, 50.0f}, {57, 50.0f}, {58, 10.0f}, {180, 50.0f},
      {182, 8.0f}, {183, 120.0f}, {184, 1.0f}, {185, 1.0f}};
  for (uint32_t port = 0; port < hostDefaults.size(); ++port) {
    const bool mapped = PresetManager::portToSymbol(port) != nullptr;
    CHECK(initialized[port] == mapped, "default enumeration matches Windows mapping at %u", port);
    CHECK(defaultPreset.controls.count(port) == static_cast<size_t>(mapped), "default preset coverage at %u", port);
    if (!mapped) {
      CHECK(hostDefaults[port] == 0.0f, "shared defaults leave pins and host-only controls untouched at %u", port);
      continue;
    }
    CHECK(defaultPreset.controls.at(port) == hostDefaults[port], "shared callback/actual preset parity at %u", port);
    float expected = nonzeroStaticDefaults.count(port) ? nonzeroStaticDefaults.at(port) : 0.0f;
    if (port >= kTransformerControlFirstPort && port < kTransformerControlFirstPort + kTransformerControlCount)
      expected = kTransformerControlDefaults[port - kTransformerControlFirstPort];
    if (port >= kRackControlFirstPort && port < kRackControlFirstPort + kRackCount)
      expected = kRackControlDefaults[port - kRackControlFirstPort];
    CHECK(hostDefaults[port] == expected, "unchanged Windows default value at %u", port);
  }
  CHECK(defaultPreset.name == "Default Rig" && defaultPreset.speakerProfile == 0.0f, "default preset identity/profile");
  const char* roles[] = {"pedal", "amp", "cab", "cab2"};
  for (size_t i = 0; i < defaultPreset.stages.size(); ++i) {
    const auto& stage = defaultPreset.stages[i];
    CHECK(stage.role == roles[i] && stage.enabled == (i < 3) && stage.path.empty(), "default stage %zu", i);
    CHECK(stage.oversample == static_cast<float>(kOversampleTrue8) &&
          stage.transformer == 0.0f && stage.irNormalization == 2.0f, "default stage modes %zu", i);
  }

  // Replay only the actual constructor's host-only assignments, not a second initializer.
  std::ifstream hostFile(std::filesystem::path(argv[1]).parent_path().parent_path() / "src/standalone_main_win32.cpp");
  CHECK(hostFile.is_open(), "open Windows host source");
  const std::string hostSource{std::istreambuf_iterator<char>(hostFile), std::istreambuf_iterator<char>()};
  const std::regex constructorPattern("// Default control values([\\s\\S]*?)\\n  \\}");
  std::smatch constructor;
  CHECK(std::regex_search(hostSource, constructor, constructorPattern), "find Windows constructor defaults");
  const std::string defaults = constructor[1];
  CHECK(defaults.find("controls_.fill(0.0f);") != std::string::npos, "host starts with zeroed control storage");
  CHECK(defaults.find("NAMRigWin32::forEachWin32ControlDefault(") != std::string::npos &&
        defaults.find("controls_[port] = value;") != std::string::npos, "host uses shared callback initializer");
  const std::regex assignmentPattern("controls_\\[(\\d+)\\] = ([-0-9.]+)f;");
  std::map<uint32_t, float> hostExtras;
  for (std::sregex_iterator it(defaults.begin(), defaults.end(), assignmentPattern), end; it != end; ++it) {
    const uint32_t port = std::stoul((*it)[1]);
    CHECK(port < hostDefaults.size() && !initialized[port], "host extra outside shared preset coverage at %u", port);
    CHECK(hostExtras.emplace(port, std::stof((*it)[2])).second, "unique host extra at %u", port);
    if (port < hostDefaults.size()) hostDefaults[port] = std::stof((*it)[2]);
  }
  CHECK((hostExtras == std::map<uint32_t, float>{{6, 1.0f}, {10, 1.0f}, {17, -1.0f}, {19, 1.0f}}),
        "unchanged quality, auto-cab, tuner-note and legacy host-only defaults");
  for (uint32_t port = 0; port < hostDefaults.size(); ++port)
    if (!initialized[port] && !hostExtras.count(port))
      CHECK(hostDefaults[port] == 0.0f, "host gaps, meters and pins remain zero at %u", port);
  CHECK(hostSource.find("pinEqControls_.fill(0.0f);") != std::string::npos,
        "host retains separate all-zero pin storage, not generic pin defaults");

  std::ifstream ttlFile(argv[1]);
  CHECK(ttlFile.is_open(), "open TTL fixture");
  const std::string ttl{std::istreambuf_iterator<char>(ttlFile), std::istreambuf_iterator<char>()};
  const std::regex portPattern("lv2:index\\s+(\\d+)\\s*;\\s*lv2:symbol\\s+\"([^\"]+)\"");
  std::map<uint32_t, std::string> ttlSymbols;
  for (std::sregex_iterator it(ttl.begin(), ttl.end(), portPattern), end; it != end; ++it)
    CHECK(ttlSymbols.emplace(std::stoul((*it)[1]), (*it)[2]).second, "unique TTL port");
  CHECK(ttlSymbols.size() == 186, "complete shipped TTL fixture");

  const std::set<uint32_t> excluded = {0, 1, 2, 3, 6, 10, 11, 16, 17, 18, 19, 29, 31};
  std::map<uint32_t, const char*> symbols;
  std::set<std::string> names;
  forEachRigControlSymbol([&](uint32_t port, const char* symbol) {
    CHECK(symbol && *symbol, "non-empty symbol at %u", port);
    CHECK(symbols.emplace(port, symbol).second, "enumerate port %u once", port);
    CHECK(names.emplace(symbol).second, "unique symbol at %u", port);
    CHECK(port < 186 && !excluded.count(port), "preset coverage at %u", port);
    CHECK(ttlSymbols.count(port) && ttlSymbols.at(port) == symbol, "TTL parity at %u", port);
    CHECK(rigControlSymbol(port) == symbol, "lookup/enumeration pointer identity at %u", port);
  });
  CHECK(symbols.size() == 173, "exact macOS/shared preset coverage");

  for (uint32_t port = 0; port <= 186; ++port) {
    const char* symbol = rigControlSymbol(port);
    const bool mapped = port < 186 && !excluded.count(port);
    CHECK((symbol != nullptr) == mapped, "lookup coverage at %u", port);
    CHECK(symbols.count(port) == static_cast<size_t>(mapped), "enumeration coverage at %u", port);
    const char* windows = PresetManager::portToSymbol(port);
    if (!mapped || isPinEqPort(port)) {
      CHECK(!windows, "Windows excludes gaps/audio/pins at %u", port);
      if (symbol)
        CHECK(PresetManager::symbolToPort(symbol) == -1, "Windows rejects pin name at %u", port);
    } else {
      CHECK(windows == symbol, "Windows uses shared pointer at %u", port);
      CHECK(PresetManager::symbolToPort(symbol) == static_cast<int32_t>(port),
            "Windows reverse lookup at %u", port);
    }
  }
  CHECK(!rigControlSymbol(UINT32_MAX) && !PresetManager::portToSymbol(UINT32_MAX), "large invalid port");
  for (const auto& symbol : {"", "input", "output", "quality_scale", "auto_cab", "tuner_enable",
                            "oversample_mode", "latency", "output_r", "unknown"})
    CHECK(PresetManager::symbolToPort(symbol) == -1, "Windows rejects excluded name %s", symbol);
  CHECK(std::string(rigControlSymbol(83)) == "sculpt_pin1_shape", "first pin");
  CHECK(std::string(rigControlSymbol(112)) == "transformer_pin2_freq", "transformer pin");
  CHECK(std::string(rigControlSymbol(154)) == "cab_console_pin6_q", "console last pin");
  CHECK(std::string(rigControlSymbol(178)) == "speaker_pin6_q", "last pin");
  for (int pass = 0; pass < 3; ++pass) {
    forEachRigControlSymbol([&](uint32_t port, const char* symbol) {
      CHECK(symbols.at(port) == symbol, "stable enumeration pointer at %u", port);
    });
    for (const auto& entry : symbols) {
      CHECK(rigControlSymbol(entry.first) == entry.second, "stable lookup pointer at %u", entry.first);
      CHECK(ttlSymbols.at(entry.first) == entry.second, "stable contents at %u", entry.first);
      if (isPinEqPort(entry.first))
        CHECK(pinEqSymbol(entry.first) == entry.second, "existing pin descriptor at %u", entry.first);
    }
  }

  RigPreset preset;
  for (uint32_t port = 0; port <= 185; ++port)
    preset.controls[port] = static_cast<float>(port) + 0.25f;
  const auto path = std::filesystem::temp_directory_path() /
      ("verify-rig-symbols-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".json");
  CHECK(preset.saveToFile(path.string()), "save actual Windows preset");
  json saved;
  {
    std::ifstream file(path);
    file >> saved;
  }
  CHECK(saved["ports"].size() == preset.controls.size(), "all numeric ports preserved, including unknowns");
  CHECK(saved["params"].size() == 77, "Windows named coverage unchanged");
  for (const auto& control : preset.controls) {
    CHECK(saved["ports"][std::to_string(control.first)] == control.second, "numeric value at %u", control.first);
    const char* symbol = rigControlSymbol(control.first);
    if (symbol) {
      if (isPinEqPort(control.first))
        CHECK(!saved["params"].contains(symbol), "Windows does not serialize pin name at %u", control.first);
      else
        CHECK(saved["params"][symbol] == control.second, "named value at %u", control.first);
    }
  }
  RigPreset loaded;
  CHECK(loaded.loadFromFile(path.string()), "load actual Windows preset");
  CHECK(loaded.controls == preset.controls, "numeric and named round trip");
  for (auto& parameter : saved["params"].items()) parameter.value() = -7.5f;
  saved["params"]["sculpt_pin1_shape"] = 3.0f;
  saved["params"]["output"] = 99.0f;
  saved["params"]["unknown"] = 100.0f;
  {
    std::ofstream file(path);
    file << saved;
  }
  RigPreset overridden;
  CHECK(overridden.loadFromFile(path.string()), "load mixed numeric/named fixture");
  CHECK(overridden.controls.size() == preset.controls.size(), "unknown names add no controls");
  for (const auto& control : preset.controls) {
    const float expected = PresetManager::portToSymbol(control.first) ? -7.5f : control.second;
    CHECK(overridden.controls.at(control.first) == expected, "named precedence/pin exclusion at %u", control.first);
  }
  std::filesystem::remove(path);
  std::printf("  %s  Windows defaults, shared symbols, stable pointers, TTL parity and Windows serialization\n",
              failures ? "FAIL" : "PASS");
  return failures ? 1 : 0;
}
