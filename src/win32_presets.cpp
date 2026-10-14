#include "win32_presets.h"

#ifdef _WIN32
#include <windows.h>
#include <shlobj.h>
#endif

#include <algorithm>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <ctime>

#include <nlohmann/json.hpp>

#include "oversample_modes.h"
#include "output_transformer.h"
#include "pin_eq.h"
#include "power_tube_controls.h"
#include "rack_controls.h"
#include "speaker_dynamics.h"

using json = nlohmann::json;

namespace NAMRigWin32 {

namespace {

std::string getAppDataDirectory() {
#ifdef _WIN32
  wchar_t wpath[MAX_PATH];
  if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_APPDATA, NULL, 0, wpath))) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wpath, -1, NULL, 0, NULL, NULL);
    if (len > 0) {
      std::string out(len - 1, '\0');
      WideCharToMultiByte(CP_UTF8, 0, wpath, -1, &out[0], len, NULL, NULL);
      return out + "\\Axe FX";
    }
  }
#endif
  const char* appData = getenv("APPDATA");
  if (appData && *appData) {
    return std::string(appData) + "\\Axe FX";
  }
  return "C:\\Axe FX";
}

void ensureDirectory(const std::string& path) {
#ifdef _WIN32
  int wlen = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, NULL, 0);
  if (wlen > 0) {
    std::wstring wpath(wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, &wpath[0], wlen);
    CreateDirectoryW(wpath.c_str(), NULL);
  }
#endif
}

std::string getCurrentISOTime() {
  std::time_t now = std::time(nullptr);
  std::tm tm{};
#ifdef _WIN32
  gmtime_s(&tm, &now);
#else
  gmtime_r(&now, &tm);
#endif
  char buf[64];
  std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
  return std::string(buf);
}

} // namespace

const char* PresetManager::portToSymbol(uint32_t port) {
  switch (port) {
    case 4: return "input_level";
    case 5: return "output_level";
    case 7: return "pedal_enabled";
    case 8: return "amp_enabled";
    case 9: return "cab_enabled";
    case 12: return "bass";
    case 13: return "mid";
    case 14: return "treble";
    case 15: return "gate_threshold";
    case 20: return "pedal_oversample";
    case 21: return "amp_oversample";
    case 22: return "amp_drive";
    case 23: return "gate_release";
    case 24: return "ir_normalization";
    case 25: return "cab_level";
    case 26: return "cab_low_cut";
    case 27: return "cab_high_cut";
    case 28: return "compressor";
    case 30: return "transformer_type";
    case 32: return "stereo_width";
    case 33: return "room";
    case 34: return "presence";
    case 35: return "depth";
    case 36: return "sag";
    case 37: return "bias";
    case 38: return "negative_feedback";
    case 39: return "bright";
    case 40: return "input_eq";
    case 41: return "master";
    case 42: return "speaker_profile";
    case 43: return "speaker_drive";
    case 44: return "speaker_compression";
    case 45: return "speaker_thump";
    case 46: return "speaker_resonance";
    case 47: return "cab2_enabled";
    case 48: return "cab2_level";
    case 49: return "cab2_delay";
    case 50: return "delay_time";
    case 51: return "delay_feedback";
    case 52: return "delay_damping";
    case 53: return "delay_mix";
    case 54: return "reverb_mix";
    case 55: return "reverb_decay";
    case 56: return "reverb_size";
    case 57: return "reverb_damping";
    case 58: return "reverb_predelay";
    case 59: return "cab2_polarity";
    case 80: return "power_tube_type";
    case 81: return "power_tube_character";
    case 82: return "mid_push";
    case 179: return "od_drive";
    case 180: return "od_tone";
    case 181: return "od_level";
    default: break;
  }
  if (port >= NAMRig::kTransformerControlFirstPort &&
      port < NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount) {
    size_t idx = port - NAMRig::kTransformerControlFirstPort;
    return NAMRig::kTransformerControls[idx].symbol;
  }
  if (port >= NAMRig::kRackControlFirstPort &&
      port < NAMRig::kRackControlFirstPort + NAMRig::kRackCount) {
    size_t idx = port - NAMRig::kRackControlFirstPort;
    return NAMRig::kRackControlSymbols[idx];
  }
  return nullptr;
}

int32_t PresetManager::symbolToPort(const std::string& symbol) {
  for (uint32_t p = 4; p <= 181; ++p) {
    const char* s = portToSymbol(p);
    if (s && symbol == s) return static_cast<int32_t>(p);
  }
  return -1;
}

RigPreset RigPreset::createDefault() {
  RigPreset p;
  p.name = "Default Rig";
  p.speakerProfile = 0.0f;

  const char* roles[] = {"pedal", "amp", "cab", "cab2"};
  for (size_t s = 0; s < 4; ++s) {
    p.stages[s].role = roles[s];
    p.stages[s].enabled = (s < 3);
    p.stages[s].path.clear();
    p.stages[s].oversample = static_cast<float>(NAMRig::kOversampleTrue8);
    p.stages[s].transformer = 0.0f;
    p.stages[s].irNormalization = 2.0f;
  }

  p.controls[4] = 0.0f;       // input_level
  p.controls[5] = 0.0f;       // output_level
  p.controls[7] = 1.0f;       // pedal_enabled
  p.controls[8] = 1.0f;       // amp_enabled
  p.controls[9] = 1.0f;       // cab_enabled
  p.controls[12] = 0.0f;      // bass
  p.controls[13] = 0.0f;      // mid
  p.controls[14] = 0.0f;      // treble
  p.controls[15] = -80.0f;    // gate_threshold
  p.controls[20] = static_cast<float>(NAMRig::kOversampleTrue8);
  p.controls[21] = static_cast<float>(NAMRig::kOversampleTrue8);
  p.controls[22] = 0.0f;      // amp_drive
  p.controls[23] = 150.0f;    // gate_release
  p.controls[24] = 2.0f;      // ir_normalization: Loudness
  p.controls[25] = 0.0f;      // cab_level
  p.controls[26] = 0.0f;      // cab_low_cut (0 = Off)
  p.controls[27] = 20000.0f;  // cab_high_cut (20k = Off)
  p.controls[28] = 0.0f;      // compressor
  p.controls[30] = 0.0f;      // transformer_type (0 = Captured/Off)
  p.controls[32] = 0.0f;      // stereo_width
  p.controls[33] = 0.0f;      // room
  p.controls[34] = 0.0f;      // presence
  p.controls[35] = 0.0f;      // depth
  p.controls[36] = 0.0f;      // sag
  p.controls[37] = 0.0f;      // bias
  p.controls[38] = 0.0f;      // negative_feedback
  p.controls[39] = 0.0f;      // bright
  p.controls[40] = 0.0f;      // input_eq
  p.controls[41] = 0.0f;      // master
  p.controls[42] = 0.0f;      // speaker_profile
  p.controls[43] = 25.0f;     // speaker_drive
  p.controls[44] = 25.0f;     // speaker_compression
  p.controls[45] = 50.0f;     // speaker_thump
  p.controls[46] = 50.0f;     // speaker_resonance
  p.controls[47] = 0.0f;      // cab2_enabled
  p.controls[48] = 0.0f;      // cab2_level
  p.controls[49] = 0.0f;      // cab2_delay
  p.controls[50] = 400.0f;    // delay_time
  p.controls[51] = 35.0f;     // delay_feedback
  p.controls[52] = 40.0f;     // delay_damping
  p.controls[53] = 0.0f;      // delay_mix
  p.controls[54] = 0.0f;      // reverb_mix
  p.controls[55] = 50.0f;     // reverb_decay
  p.controls[56] = 50.0f;     // reverb_size
  p.controls[57] = 50.0f;     // reverb_damping
  p.controls[58] = 10.0f;     // reverb_predelay
  p.controls[59] = 0.0f;      // cab2_polarity

  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
    p.controls[NAMRig::kTransformerControlFirstPort + i] = NAMRig::kTransformerControlDefaults[i];
  for (size_t i = 0; i < NAMRig::kRackCount; ++i)
    p.controls[NAMRig::kRackControlFirstPort + i] = NAMRig::kRackControlDefaults[i];

  p.controls[80] = 0.0f;      // power_tube_type
  p.controls[81] = 0.0f;      // power_tube_character
  p.controls[82] = 0.0f;      // mid_push
  p.controls[179] = 0.0f;     // od_drive
  p.controls[180] = 50.0f;    // od_tone
  p.controls[181] = 0.0f;     // od_level

  return p;
}

std::vector<RigPreset> RigPreset::getFactoryPresets() {
  std::vector<RigPreset> list;

  // 1. Clean Studio
  {
    RigPreset p = createDefault();
    p.name = "Clean Studio";
    p.controls[15] = -60.0f;    // gate
    p.controls[28] = 20.0f;     // subtle compressor
    p.controls[33] = 18.0f;     // room reflections
    p.controls[34] = 1.5f;      // presence
    p.controls[39] = 25.0f;     // bright
    p.controls[54] = 15.0f;     // plate reverb mix
    p.controls[55] = 45.0f;     // decay
    list.push_back(p);
  }

  // 2. Edge of Breakup
  {
    RigPreset p = createDefault();
    p.name = "Edge of Breakup";
    p.controls[179] = 22.0f;    // subtle OD drive
    p.controls[180] = 55.0f;    // tone
    p.controls[22] = 2.5f;      // amp drive
    p.controls[12] = 1.0f;      // bass
    p.controls[13] = 1.5f;      // mid
    p.controls[14] = 0.5f;      // treble
    p.controls[36] = 20.0f;     // sag
    p.controls[30] = 1.0f;      // Modern transformer
    p.controls[53] = 12.0f;     // delay mix
    p.controls[50] = 350.0f;
    p.controls[54] = 12.0f;     // reverb mix
    list.push_back(p);
  }

  // 3. Heavy Rhythm
  {
    RigPreset p = createDefault();
    p.name = "Heavy Rhythm";
    p.controls[15] = -48.0f;    // tight gate
    p.controls[179] = 45.0f;    // TS tight boost
    p.controls[180] = 60.0f;
    p.controls[181] = 2.0f;
    p.controls[22] = 4.0f;      // amp drive
    p.controls[12] = 2.0f;      // bass
    p.controls[13] = -1.0f;     // slight scoop
    p.controls[14] = 1.5f;      // treble
    p.controls[34] = 3.0f;      // presence bite
    p.controls[35] = 2.5f;      // depth thump
    p.controls[30] = 5.0f;      // Tight Metal transformer
    p.controls[82] = 20.0f;     // mid push
    list.push_back(p);
  }

  // 4. Lead Solo
  {
    RigPreset p = createDefault();
    p.name = "Lead Solo";
    p.controls[15] = -52.0f;
    p.controls[179] = 55.0f;
    p.controls[180] = 65.0f;
    p.controls[22] = 5.0f;
    p.controls[13] = 3.0f;      // singing midrange
    p.controls[34] = 2.0f;
    p.controls[36] = 35.0f;     // tube sag bloom
    p.controls[80] = 1.0f;      // 6L6 tube
    p.controls[81] = 40.0f;     // character
    p.controls[53] = 25.0f;     // delay mix
    p.controls[50] = 480.0f;    // delay time
    p.controls[51] = 42.0f;     // feedback
    p.controls[54] = 22.0f;     // reverb mix
    list.push_back(p);
  }

  // 5. Modern High-Gain
  {
    RigPreset p = createDefault();
    p.name = "Modern High-Gain";
    p.controls[15] = -42.0f;    // fast precision noise gate
    p.controls[23] = 40.0f;     // quick release
    p.controls[179] = 30.0f;
    p.controls[180] = 70.0f;
    p.controls[22] = 6.0f;
    p.controls[35] = 3.5f;      // depth
    p.controls[38] = 30.0f;     // negative feedback control
    p.controls[30] = 7.0f;      // Thrash Bite iron
    p.controls[45] = 65.0f;     // speaker thump
    list.push_back(p);
  }

  // 6. Ambient Shimmer
  {
    RigPreset p = createDefault();
    p.name = "Ambient Shimmer";
    p.controls[28] = 35.0f;     // studio compressor
    p.controls[32] = 60.0f;     // wide stereo image
    p.controls[33] = 40.0f;     // room acoustic
    p.controls[53] = 35.0f;     // delay mix
    p.controls[50] = 520.0f;
    p.controls[51] = 65.0f;     // long feedback
    p.controls[54] = 45.0f;     // huge plate reverb
    p.controls[55] = 85.0f;     // decay
    p.controls[56] = 80.0f;     // size
    list.push_back(p);
  }

  return list;
}

bool RigPreset::loadFromFile(const std::string& path) {
  std::ifstream f(path);
  if (!f.is_open()) return false;

  json root;
  try {
    f >> root;
  } catch (...) {
    return false;
  }

  filePath = path;
  if (root.contains("name") && root["name"].is_string()) {
    name = root["name"].get<std::string>();
  } else {
    size_t lastSlash = path.find_last_of("\\/");
    size_t lastDot = path.find_last_of('.');
    if (lastSlash == std::string::npos) lastSlash = 0; else ++lastSlash;
    if (lastDot == std::string::npos || lastDot < lastSlash) lastDot = path.length();
    name = path.substr(lastSlash, lastDot - lastSlash);
  }

  if (root.contains("speaker_profile") && root["speaker_profile"].is_number()) {
    speakerProfile = root["speaker_profile"].get<float>();
  }

  const char* roles[] = {"pedal", "amp", "cab", "cab2"};
  for (size_t s = 0; s < 4; ++s) {
    stages[s].role = roles[s];
    stages[s].enabled = (s < 3);
    stages[s].path.clear();
    stages[s].oversample = static_cast<float>(NAMRig::kOversampleTrue8);
    stages[s].transformer = 0.0f;
    stages[s].irNormalization = 2.0f;
  }

  if (root.contains("stages") && root["stages"].is_array()) {
    const auto& arr = root["stages"];
    for (size_t s = 0; s < std::min(arr.size(), (size_t)4); ++s) {
      const auto& st = arr[s];
      if (!st.is_object()) continue;
      if (st.contains("enabled") && st["enabled"].is_boolean()) stages[s].enabled = st["enabled"].get<bool>();
      if (st.contains("path") && st["path"].is_string()) stages[s].path = st["path"].get<std::string>();
      if (st.contains("oversample") && st["oversample"].is_number()) stages[s].oversample = st["oversample"].get<float>();
      if (st.contains("transformer") && st["transformer"].is_number()) stages[s].transformer = st["transformer"].get<float>();
      if (st.contains("ir_normalization") && st["ir_normalization"].is_number()) stages[s].irNormalization = st["ir_normalization"].get<float>();
    }
  }

  controls[59] = 0.0f; // legacy normal polarity default
  if (root.contains("ports") && root["ports"].is_object()) {
    for (auto& el : root["ports"].items()) {
      try {
        uint32_t port = static_cast<uint32_t>(std::stoul(el.key()));
        if (el.value().is_number()) {
          controls[port] = el.value().get<float>();
        }
      } catch (...) {}
    }
  }

  if (root.contains("params") && root["params"].is_object()) {
    for (auto& el : root["params"].items()) {
      int32_t port = PresetManager::symbolToPort(el.key());
      if (port >= 0 && el.value().is_number()) {
        controls[static_cast<uint32_t>(port)] = el.value().get<float>();
      }
    }
  }

  slotPresets.clear();
  if (root.contains("slot_presets") && root["slot_presets"].is_object()) {
    for (auto& el : root["slot_presets"].items()) {
      if (el.value().is_string()) {
        slotPresets[el.key()] = el.value().get<std::string>();
      }
    }
  }

  return true;
}

bool RigPreset::saveToFile(const std::string& path) const {
  json root;
  root["name"] = name.empty() ? "Untitled" : name;
  root["version"] = 2;
  root["created"] = getCurrentISOTime();
  root["speaker_profile"] = speakerProfile;

  json stagesArr = json::array();
  for (size_t s = 0; s < 4; ++s) {
    json st = json::object();
    st["role"] = stages[s].role;
    st["enabled"] = stages[s].enabled;
    st["path"] = stages[s].path;
    if (s == 0 || s == 1) st["oversample"] = stages[s].oversample;
    if (s == 1) st["transformer"] = stages[s].transformer;
    if (s == 2) st["ir_normalization"] = stages[s].irNormalization;
    stagesArr.push_back(st);
  }
  root["stages"] = stagesArr;
  if (!slotPresets.empty()) {
    json sp = json::object();
    for (const auto& pair : slotPresets) {
      sp[pair.first] = pair.second;
    }
    root["slot_presets"] = sp;
  }

  json portsObj = json::object();
  json paramsObj = json::object();

  for (const auto& pair : controls) {
    portsObj[std::to_string(pair.first)] = pair.second;
    const char* sym = PresetManager::portToSymbol(pair.first);
    if (sym) {
      paramsObj[sym] = pair.second;
    }
  }
  root["ports"] = portsObj;
  root["params"] = paramsObj;

  std::ofstream f(path);
  if (!f.is_open()) return false;
  f << std::setw(2) << root << std::endl;
  return true;
}

PresetManager::PresetManager() {
  appDataDir_ = getAppDataDirectory();
  presetsDir_ = appDataDir_ + "\\Presets";
  slotPresetsFile_ = appDataDir_ + "\\slot-presets.json";
  currentPresetName_ = "Default Rig";
  factoryPresets_ = RigPreset::getFactoryPresets();
}

PresetManager& PresetManager::instance() {
  static PresetManager inst;
  return inst;
}

void PresetManager::initialize() {
  ensureDirectory(appDataDir_);
  ensureDirectory(presetsDir_);
  rescanPresets();
}

void PresetManager::rescanPresets() {
  userPresetNames_.clear();
#ifdef _WIN32
  std::string pattern = presetsDir_ + "\\*.json";
  int wlen = MultiByteToWideChar(CP_UTF8, 0, pattern.c_str(), -1, NULL, 0);
  if (wlen > 0) {
    std::wstring wpattern(wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, pattern.c_str(), -1, &wpattern[0], wlen);

    WIN32_FIND_DATAW fd;
    HANDLE hFind = FindFirstFileW(wpattern.c_str(), &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
      do {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
          int nlen = WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, NULL, 0, NULL, NULL);
          if (nlen > 0) {
            std::string filename(nlen - 1, '\0');
            WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, &filename[0], nlen, NULL, NULL);
            size_t dot = filename.rfind(".json");
            if (dot != std::string::npos) {
              userPresetNames_.push_back(filename.substr(0, dot));
            }
          }
        }
      } while (FindNextFileW(hFind, &fd));
      FindClose(hFind);
    }
  }
#endif
  std::sort(userPresetNames_.begin(), userPresetNames_.end());
}

bool PresetManager::loadPresetNamed(const std::string& name, RigPreset& outPreset) {
  for (const auto& fp : factoryPresets_) {
    if (fp.name == name) {
      outPreset = fp;
      currentPresetName_ = name;
      return true;
    }
  }

  std::string file = presetsDir_ + "\\" + name + ".json";
  if (outPreset.loadFromFile(file)) {
    currentPresetName_ = name;
    return true;
  }
  return false;
}

bool PresetManager::savePresetNamed(const std::string& name, const RigPreset& preset) {
  std::string file = presetsDir_ + "\\" + name + ".json";
  RigPreset toSave = preset;
  toSave.name = name;
  if (toSave.saveToFile(file)) {
    currentPresetName_ = name;
    rescanPresets();
    return true;
  }
  return false;
}

bool PresetManager::renamePresetNamed(const std::string& oldName, const std::string& newName) {
  std::string oldFile = presetsDir_ + "\\" + oldName + ".json";
  std::string newFile = presetsDir_ + "\\" + newName + ".json";
#ifdef _WIN32
  int wold = MultiByteToWideChar(CP_UTF8, 0, oldFile.c_str(), -1, NULL, 0);
  int wnew = MultiByteToWideChar(CP_UTF8, 0, newFile.c_str(), -1, NULL, 0);
  if (wold > 0 && wnew > 0) {
    std::wstring woldFile(wold, L'\0');
    std::wstring wnewFile(wnew, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, oldFile.c_str(), -1, &woldFile[0], wold);
    MultiByteToWideChar(CP_UTF8, 0, newFile.c_str(), -1, &wnewFile[0], wnew);
    if (MoveFileW(woldFile.c_str(), wnewFile.c_str())) {
      if (currentPresetName_ == oldName) currentPresetName_ = newName;
      rescanPresets();
      return true;
    }
  }
#endif
  return false;
}

bool PresetManager::deletePresetNamed(const std::string& name) {
  std::string file = presetsDir_ + "\\" + name + ".json";
#ifdef _WIN32
  int wlen = MultiByteToWideChar(CP_UTF8, 0, file.c_str(), -1, NULL, 0);
  if (wlen > 0) {
    std::wstring wfile(wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, file.c_str(), -1, &wfile[0], wlen);
    if (DeleteFileW(wfile.c_str())) {
      rescanPresets();
      return true;
    }
  }
#endif
  return false;
}

std::vector<std::string> PresetManager::getSlotFactoryPresets(const std::string& slotKey) {
  if (slotKey == "delay") {
    return {"Digital Clean (400ms)", "Warm Tape (320ms)", "Quarter Note (500ms)", "Slapback (90ms)", "Ambient Wash (650ms)"};
  } else if (slotKey == "reverb") {
    return {"Studio Plate", "Large Hall", "Warm Room", "Bright Ambience", "Deep Space"};
  } else if (slotKey == "transformer") {
    return {"Modern Iron", "US Vintage", "UK Vintage", "Tight Metal", "Small Iron", "Studio Linear"};
  } else if (slotKey == "power_tube") {
    return {"Captured Clean", "6L6 Warmth (25%)", "6L6 Saturated (50%)", "EL34 Punch (35%)", "EL34 High-Gain (65%)"};
  } else if (slotKey == "sculpt") {
    return {"Flat Bypass", "TS Tight Boost", "Midrange Push", "Fat Lead"};
  }
  return {"Default"};
}

std::vector<std::string> PresetManager::getSlotUserPresets(const std::string& slotKey) {
  std::vector<std::string> names;
  std::ifstream f(slotPresetsFile_);
  if (!f.is_open()) return names;

  try {
    json root;
    f >> root;
    if (root.contains("slots") && root["slots"].contains(slotKey)) {
      const auto& slotObj = root["slots"][slotKey];
      if (slotObj.contains("user_presets") && slotObj["user_presets"].is_object()) {
        for (auto& el : slotObj["user_presets"].items()) {
          names.push_back(el.key());
        }
      }
    }
  } catch (...) {}
  std::sort(names.begin(), names.end());
  return names;
}

bool PresetManager::loadSlotPreset(const std::string& slotKey, const std::string& name,
                                   std::unordered_map<std::string, float>& outParams) {
  outParams.clear();
  std::ifstream f(slotPresetsFile_);
  if (!f.is_open()) return false;

  try {
    json root;
    f >> root;
    if (root.contains("slots") && root["slots"].contains(slotKey)) {
      const auto& slotObj = root["slots"][slotKey];
      if (slotObj.contains("user_presets") && slotObj["user_presets"].contains(name)) {
        const auto& pObj = slotObj["user_presets"][name];
        for (auto& el : pObj.items()) {
          if (el.value().is_number()) outParams[el.key()] = el.value().get<float>();
        }
        return true;
      }
    }
  } catch (...) {}
  return false;
}

bool PresetManager::saveSlotPreset(const std::string& slotKey, const std::string& name,
                                   const std::unordered_map<std::string, float>& params) {
  json root;
  std::ifstream fin(slotPresetsFile_);
  if (fin.is_open()) {
    try { fin >> root; } catch (...) { root = json::object(); }
    fin.close();
  }

  json pObj = json::object();
  for (const auto& pair : params) {
    pObj[pair.first] = pair.second;
  }
  root["slots"][slotKey]["user_presets"][name] = pObj;

  std::ofstream fout(slotPresetsFile_);
  if (!fout.is_open()) return false;
  fout << std::setw(2) << root << std::endl;
  propagateSlotValues(slotKey, name, params);
  return true;
}

bool PresetManager::renameSlotPreset(const std::string& slotKey, const std::string& oldName,
                                     const std::string& newName) {
  json root;
  std::ifstream fin(slotPresetsFile_);
  if (!fin.is_open()) return false;
  try { fin >> root; } catch (...) { return false; }
  fin.close();

  if (root.contains("slots") && root["slots"].contains(slotKey)) {
    auto& slotObj = root["slots"][slotKey];
    if (slotObj.contains("user_presets") && slotObj["user_presets"].contains(oldName)) {
      json p = slotObj["user_presets"][oldName];
      slotObj["user_presets"].erase(oldName);
      slotObj["user_presets"][newName] = p;

      std::ofstream fout(slotPresetsFile_);
      if (!fout.is_open()) return false;
      fout << std::setw(2) << root << std::endl;
      renameSlotPresetInAllPresets(slotKey, oldName, newName);
      return true;
    }
  }
  return false;
}

bool PresetManager::deleteSlotPreset(const std::string& slotKey, const std::string& name) {
  json root;
  std::ifstream fin(slotPresetsFile_);
  if (!fin.is_open()) return false;
  try { fin >> root; } catch (...) { return false; }
  fin.close();

  if (root.contains("slots") && root["slots"].contains(slotKey)) {
    auto& slotObj = root["slots"][slotKey];
    if (slotObj.contains("user_presets") && slotObj["user_presets"].contains(name)) {
      slotObj["user_presets"].erase(name);

      std::ofstream fout(slotPresetsFile_);
      if (!fout.is_open()) return false;
      fout << std::setw(2) << root << std::endl;
      deleteSlotPresetInAllPresets(slotKey, name);
      return true;
    }
  }
  return false;
}

size_t PresetManager::propagateSlotValues(
    const std::string& slotKey,
    const std::string& presetName,
    const std::unordered_map<std::string, float>& params) {
  if (params.empty()) return 0;
  rescanPresets();
  size_t count = 0;
  for (const auto& uname : userPresetNames_) {
    std::string file = presetsDir_ + "\\" + uname + ".json";
    RigPreset p;
    if (p.loadFromFile(file)) {
      for (const auto& pair : params) {
        int32_t port = -1;
        try {
          port = std::stoi(pair.first);
        } catch (...) {
          port = symbolToPort(pair.first);
        }
        if (port >= 0) {
          p.controls[static_cast<uint32_t>(port)] = pair.second;
        }
      }
      if (!slotKey.empty() && !presetName.empty()) {
        p.slotPresets[slotKey] = presetName;
      }
      if (p.saveToFile(file)) {
        count++;
      }
    }
  }
  return count;
}

void PresetManager::renameSlotPresetInAllPresets(const std::string& slotKey,
                                                const std::string& oldName,
                                                const std::string& newName) {
  if (slotKey.empty() || oldName.empty() || newName.empty()) return;
  rescanPresets();
  for (const auto& uname : userPresetNames_) {
    std::string file = presetsDir_ + "\\" + uname + ".json";
    RigPreset p;
    if (p.loadFromFile(file)) {
      auto it = p.slotPresets.find(slotKey);
      if (it != p.slotPresets.end() && it->second == oldName) {
        it->second = newName;
        p.saveToFile(file);
      }
    }
  }
}

void PresetManager::deleteSlotPresetInAllPresets(const std::string& slotKey,
                                                const std::string& deletedName) {
  if (slotKey.empty() || deletedName.empty()) return;
  rescanPresets();
  for (const auto& uname : userPresetNames_) {
    std::string file = presetsDir_ + "\\" + uname + ".json";
    RigPreset p;
    if (p.loadFromFile(file)) {
      auto it = p.slotPresets.find(slotKey);
      if (it != p.slotPresets.end() && it->second == deletedName) {
        p.slotPresets.erase(it);
        p.saveToFile(file);
      }
    }
  }
}

} // namespace NAMRigWin32
