#pragma once
#include <algorithm>
#include <cmath>
#include <cctype>
#include <deque>
#include <limits>
#include <string>
#include <vector>

namespace NAMRig::Tuning {
inline double frequency(double midi, double reference = 440) { return reference * std::exp2((midi - 69) / 12); }
inline double referenceOffset(double reference) { return 12 * std::log2(reference / 440); }
inline std::string noteName(int midi) {
  static const char* names[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
  return std::string(names[(midi % 12 + 12) % 12]) + std::to_string(midi / 12 - 1);
}
inline int parseNote(const std::string& text) {
  if (text.size() < 2 || text.size() > 4) return -1;
  const char letter = (char)std::toupper((unsigned char)text[0]);
  int pitch = -1;
  switch (letter) { case 'C': pitch=0; break; case 'D':pitch=2;break;case 'E':pitch=4;break;
    case 'F':pitch=5;break;case 'G':pitch=7;break;case 'A':pitch=9;break;case 'B':pitch=11;break; }
  if (pitch < 0) return -1;
  size_t at = 1;
  if (text[at] == '#' || text[at] == 'b') pitch += text[at++] == '#' ? 1 : -1;
  if (at + 1 != text.size() || text[at] < '0' || text[at] > '8') return -1;
  int midi = (text[at] - '0' + 1) * 12 + pitch;
  return frequency(midi) >= 30 && frequency(midi) <= 1400 ? midi : -1;
}
struct Preset { const char* name; std::vector<int> notes; };
inline const std::vector<Preset>& factoryTunings() {
  static const std::vector<Preset> presets = {
    {"6-string Standard", {40,45,50,55,59,64}}, {"6-string Drop D", {38,45,50,55,59,64}},
    {"6-string E-flat", {39,44,49,54,58,63}}, {"6-string D Standard", {38,43,48,53,57,62}},
    {"6-string Drop C", {36,43,48,53,57,62}}, {"6-string Drop B", {35,42,47,52,56,61}},
    {"7-string Standard", {35,40,45,50,55,59,64}}, {"7-string Drop A", {33,40,45,50,55,59,64}},
    {"8-string Standard", {30,35,40,45,50,55,59,64}}, {"8-string Drop E", {28,35,40,45,50,55,59,64}},
    {"8-string Drop D", {26,33,38,43,48,53,57,62}}
  };
  return presets;
}
enum class Status { Listening, Weak, Fading, Settling, Stable };
struct Trace { double time, cents; bool valid; };
struct Reading { double time, midi; };
class Model {
 public:
  double reference = 440;
  std::vector<int> strings = factoryTunings()[0].notes;
  int locked = -1;
  double pitch = -1, cents = 0;
  Status status = Status::Listening;
  std::deque<Trace> history;
  bool harmonicBaseline = false, hasBaseline = false, hasComparison = false;
  double baseline = 0, comparison = 0;
  std::deque<Reading> settling;
  double previousTarget = std::numeric_limits<double>::quiet_NaN();
  void clearHistory() { history.clear(); settling.clear(); status = Status::Settling; previousTarget = std::numeric_limits<double>::quiet_NaN(); }
  void resetIntonation() { hasBaseline = hasComparison = false; settling.clear(); status = Status::Settling; }
  void setReference(double value) {
    if (!std::isfinite(value)) return;
    reference = std::clamp(value, 400.0, 480.0); clearHistory(); resetIntonation();
  }
  double targetRaw() const {
    if (hasBaseline) return baseline + (harmonicBaseline ? 0 : 12);
    if (locked >= 0 && locked < (int)strings.size()) return strings[locked] + referenceOffset(reference);
    return std::round(pitch - referenceOffset(reference)) + referenceOffset(reference);
  }
  void update(double time, double midi, double confidence, double db) {
    pitch = std::isfinite(midi) ? midi : -1;
    bool valid = pitch >= 0 && std::isfinite(confidence) && confidence >= .80 && std::isfinite(db) && db > -60;
    double target = valid ? targetRaw() : previousTarget;
    if (valid && std::isfinite(previousTarget) && std::abs(target - previousTarget) > .1) clearHistory();
    if (valid) previousTarget = target;
    cents = valid ? 100 * (pitch - target) : 0;
    history.push_back({time, cents, valid});
    while (!history.empty() && history.front().time < time - 10) history.pop_front();
    if (!valid) { status = pitch < 0 ? Status::Listening : Status::Weak; settling.clear(); return; }
    if (db < -44) { status = Status::Fading; settling.clear(); return; }
    if (confidence < .90) { status = Status::Weak; settling.clear(); return; }
    settling.push_back({time, midi});
    while (!settling.empty() && settling.front().time < time - .5) settling.pop_front();
    double mean = 0, minimum = midi, maximum = midi;
    for (const auto& p : settling) { mean += p.midi; minimum = std::min(minimum,p.midi); maximum = std::max(maximum,p.midi); }
    mean /= settling.size();
    double variance = 0;
    for (const auto& p : settling) variance += std::pow(100 * (p.midi - mean), 2);
    variance /= settling.size();
    status = settling.size() >= 7 && time - settling.front().time >= .35 &&
        variance <= 2.25 && (maximum - minimum) * 100 <= 5 ? Status::Stable : Status::Settling;
  }
  bool captureBaseline() {
    if (status != Status::Stable || pitch < 0) return false;
    baseline = pitch; hasBaseline = true; hasComparison = false; clearHistory(); return true;
  }
  bool captureFretted() {
    if (!hasBaseline || status != Status::Stable || pitch < 0) return false;
    double expected = baseline + (harmonicBaseline ? 0 : 12);
    if (std::abs(pitch - expected) > 1) return false;
    comparison = pitch; hasComparison = true; return true;
  }
  double intonationCents() const { return 100 * (comparison - baseline - (harmonicBaseline ? 0 : 12)); }
};
}
