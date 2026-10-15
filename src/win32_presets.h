#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "win32_control_defaults.h"

namespace NAMRigWin32 {

struct StagePreset {
  std::string role;      // "pedal", "amp", "cab", "cab2"
  bool enabled = true;
  std::string path;
  float oversample = static_cast<float>(NAMRig::kOversampleTrue8); // port 20 or 21
  float transformer = 0.0f;    // port 30 (amp only)
  float irNormalization = 2.0f;// port 24 (cab only)
};

struct RigPreset {
  std::string name;
  std::string filePath;
  float speakerProfile = 0.0f; // port 42
  std::array<StagePreset, 4> stages;
  std::unordered_map<uint32_t, float> controls;
  std::unordered_map<std::string, std::string> slotPresets;

  static RigPreset createDefault();
  static std::vector<RigPreset> getFactoryPresets();
  bool loadFromFile(const std::string& path);
  bool saveToFile(const std::string& path) const;
};

class PresetManager {
 public:
  static PresetManager& instance();

  void initialize();
  void rescanPresets();

  const std::string& presetsDirectory() const { return presetsDir_; }
  const std::vector<std::string>& userPresetNames() const { return userPresetNames_; }
  const std::vector<RigPreset>& factoryPresets() const { return factoryPresets_; }

  const std::string& currentPresetName() const { return currentPresetName_; }
  void setCurrentPresetName(const std::string& name) { currentPresetName_ = name; }

  bool loadPresetNamed(const std::string& name, RigPreset& outPreset);
  bool savePresetNamed(const std::string& name, const RigPreset& preset);
  bool renamePresetNamed(const std::string& oldName, const std::string& newName);
  bool deletePresetNamed(const std::string& name);

  // Slot preset support conforming to studio-deck-slot-presets rule
  std::vector<std::string> getSlotFactoryPresets(const std::string& slotKey);
  std::vector<std::string> getSlotUserPresets(const std::string& slotKey);
  bool loadSlotPreset(const std::string& slotKey, const std::string& name,
                      std::unordered_map<std::string, float>& outParams);
  bool saveSlotPreset(const std::string& slotKey, const std::string& name,
                      const std::unordered_map<std::string, float>& params);
  bool renameSlotPreset(const std::string& slotKey, const std::string& oldName,
                        const std::string& newName);
  bool deleteSlotPreset(const std::string& slotKey, const std::string& name);
  size_t propagateSlotValues(const std::string& slotKey, const std::string& presetName,
                             const std::unordered_map<std::string, float>& params);
  void renameSlotPresetInAllPresets(const std::string& slotKey, const std::string& oldName,
                                    const std::string& newName);
  void deleteSlotPresetInAllPresets(const std::string& slotKey, const std::string& deletedName);

  static const char* portToSymbol(uint32_t port);
  static int32_t symbolToPort(const std::string& symbol);

 private:
  PresetManager();
  std::string appDataDir_;
  std::string presetsDir_;
  std::string slotPresetsFile_;
  std::string currentPresetName_;
  std::vector<std::string> userPresetNames_;
  std::vector<RigPreset> factoryPresets_;
};

} // namespace NAMRigWin32
