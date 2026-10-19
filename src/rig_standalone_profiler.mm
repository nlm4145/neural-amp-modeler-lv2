#import "rig_standalone_profiler.h"
#import "rig_presets.h"

#include "nam_rig_plugin.h"
#include "polyphase_worker.h"
#include "rig_control_metadata.h"
#include "rig_knobs.h"
#include "win32_control_defaults.h"

#import <objc/runtime.h>
#include <json.hpp>
#include <lv2/atom/util.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <deque>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace {

using namespace NAMRig;
using json = nlohmann::json;

constexpr double kRate = 96000.0;
constexpr size_t kMaxProfileFrames = 128;
constexpr size_t kAtomBuf = 16384;

struct ProfilerHost {
  std::vector<std::string> ids;
  std::deque<std::vector<uint8_t>> jobs;
  std::deque<LV2SwitchModelMsg> replies;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  alignas(8) std::array<uint8_t, kAtomBuf> control{}, notify{};
  std::array<float, kMaxProfileFrames> input{}, left{}, right{};
  std::array<float, Plugin::kPortCount> controls{};
  PolyphaseWorker pool;
  Plugin plugin;
  uint32_t block = 64;
  size_t position = 0;
  double ticksPerFrame = 0.0;
  bool valid = false;

  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& ids = static_cast<ProfilerHost*>(handle)->ids;
    const auto found = std::find(ids.begin(), ids.end(), uri);
    if (found != ids.end()) return static_cast<LV2_URID>(found - ids.begin() + 1);
    ids.emplace_back(uri);
    return static_cast<LV2_URID>(ids.size());
  }

  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle, uint32_t size, const void* data) {
    const auto* bytes = static_cast<const uint8_t*>(data);
    static_cast<ProfilerHost*>(handle)->jobs.emplace_back(bytes, bytes + size);
    return LV2_WORKER_SUCCESS;
  }

  static LV2_Worker_Status respond(LV2_Worker_Respond_Handle handle, uint32_t size, const void* data) {
    if (size != sizeof(LV2SwitchModelMsg)) return LV2_WORKER_ERR_UNKNOWN;
    static_cast<ProfilerHost*>(handle)->replies.push_back(*static_cast<const LV2SwitchModelMsg*>(data));
    return LV2_WORKER_SUCCESS;
  }

  void drain() {
    unsigned attempts = 0;
    while (!jobs.empty() || !replies.empty()) {
      if (++attempts >= 100) break;
      while (!jobs.empty()) {
        auto bytes = std::move(jobs.front());
        jobs.pop_front();
        Plugin::work(&plugin, respond, this, static_cast<uint32_t>(bytes.size()), bytes.data());
      }
      while (!replies.empty()) {
        const auto reply = replies.front();
        replies.pop_front();
        Plugin::workResponse(&plugin, sizeof(reply), &reply);
      }
    }
  }

  ProfilerHost(const json& preset, uint32_t frames, size_t helpers, const std::string& variant)
      : block(frames) {
    NAMRigWin32::forEachWin32ControlDefault([&](uint32_t port, float value) { controls[port] = value; });
    for (size_t i = 0; i < kRigKnobCount; ++i) controls[kRigKnobPorts[i]] = kRigKnobDefaults[i];
    auto pins = pinEqDefaults();
    std::copy(pins.begin(), pins.end(), controls.begin() + kPinEqFirstPort);
    if (preset.contains("ports")) {
      for (const auto& item : preset["ports"].items()) {
        const auto port = std::stoul(item.key());
        if (port < controls.size()) controls[port] = item.value().get<float>();
      }
    }
    std::map<std::string, uint32_t> symbols;
    forEachRigControlSymbol([&](uint32_t port, const char* name) { symbols[name] = port; });
    if (preset.contains("params")) {
      for (const auto& item : preset["params"].items()) {
        if (symbols.count(item.key())) controls[symbols[item.key()]] = item.value().get<float>();
      }
    }
    if (preset.contains("stages")) {
      const auto& stages = preset["stages"];
      for (size_t i = 0; i < kStageCount && i < stages.size(); ++i)
        controls[i < 3 ? 7 + i : 47] = stages[i].value("enabled", i < 3) ? 1.0f : 0.0f;
      if (stages.size() > 0) controls[20] = stages[0].value("oversample", 6.0f);
      if (stages.size() > 1) {
        controls[21] = stages[1].value("oversample", 6.0f);
        controls[30] = stages[1].value("transformer", 0.0f);
      }
    }
    controls[4] = 0.0f;
    controls[16] = 0.0f;

    if (variant == "no-fx") { controls[33] = controls[54] = controls[53] = 0.0f; }
    if (variant == "amp-one-step-lower") { controls[21] = std::max(4.0f, controls[21] - 1.0f); }

    for (uint32_t port = 0; port < Plugin::kPortCount; ++port) {
      void* value = port == 0 ? static_cast<void*>(control.data())
                  : port == 1 ? notify.data()
                  : port == 2 ? static_cast<void*>(input.data())
                  : port == 3 ? left.data()
                  : port == 31 ? static_cast<void*>(right.data())
                  : &controls[port];
      *(reinterpret_cast<void**>(&plugin.ports) + port) = value;
    }

    LV2_Feature mf{LV2_URID__map, &map}, wf{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mf, &wf, nullptr};
    if (!plugin.initialize(kRate, features)) return;
    plugin.setMaxBufferSize(frames);

    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    ticksPerFrame = tb.numer > 0 ? 1.0e9 * tb.denom / (tb.numer * kRate) : 0.0;

    if (helpers) {
      if (pool.start(nullptr, static_cast<double>(frames) / kRate, helpers)) {
        plugin.setPolyphaseWorker(&pool);
      }
    }

    run();
    drain();

    LV2_Atom_Forge forge{};
    lv2_atom_forge_init(&forge, &map);
    lv2_atom_forge_set_buffer(&forge, control.data(), control.size());
    LV2_Atom_Forge_Frame sequence{};
    lv2_atom_forge_sequence_head(&forge, &sequence, 0);
    const std::array<const char*, 4> stageUris{NAM_RIG_PEDAL_URI, NAM_RIG_AMP_URI, NAM_RIG_CAB_URI, NAM_RIG_CAB2_URI};

    if (preset.contains("stages")) {
      const auto& stages = preset["stages"];
      for (size_t i = 0; i < kStageCount && i < stages.size(); ++i) {
        const auto path = stages[i].value("path", std::string{});
        if (path.empty() || controls[i < 3 ? 7 + i : 47] < 0.5f) continue;
        if (!std::filesystem::exists(path)) continue;
        LV2_Atom_Forge_Frame object{};
        lv2_atom_forge_frame_time(&forge, 0);
        lv2_atom_forge_object(&forge, &object, 0, mapUri(this, LV2_PATCH__Set));
        lv2_atom_forge_key(&forge, mapUri(this, LV2_PATCH__property));
        lv2_atom_forge_urid(&forge, mapUri(this, stageUris[i]));
        lv2_atom_forge_key(&forge, mapUri(this, LV2_PATCH__value));
        lv2_atom_forge_path(&forge, path.c_str(), static_cast<uint32_t>(path.size() + 1));
        lv2_atom_forge_pop(&forge, &object);
      }
    }
    lv2_atom_forge_pop(&forge, &sequence);
    run(false);
    drain();

    // Settle filters and state
    for (unsigned i = 0; i < 32; ++i) { run(); drain(); }
    valid = true;
  }

  ~ProfilerHost() {
    plugin.setPolyphaseWorker(nullptr);
    pool.stop();
    drain();
  }

  void run(bool clear = true) {
    if (clear) {
      auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
      seq->atom.type = mapUri(this, LV2_ATOM__Sequence);
      seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
      seq->body = {};
    }
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = kAtomBuf - sizeof(LV2_Atom);
    for (uint32_t i = 0; i < block; ++i) {
      const double t = static_cast<double>(position++) / kRate;
      input[i] = static_cast<float>(0.25 * std::sin(6.283185307179586 * 82.4 * t) +
                                    0.15 * std::sin(6.283185307179586 * 659.0 * t) +
                                    0.08 * std::sin(6.283185307179586 * 3100.0 * t));
    }
    plugin.process(block, mach_absolute_time() + static_cast<uint64_t>(block * ticksPerFrame * 0.9));
  }

  double benchmarkMedian(unsigned iterations = 40) {
    if (!valid) return 0.0;
    std::vector<double> times;
    times.reserve(iterations);
    for (unsigned i = 0; i < iterations; ++i) {
      const auto t0 = std::chrono::steady_clock::now();
      run();
      const auto t1 = std::chrono::steady_clock::now();
      times.push_back(std::chrono::duration<double, std::micro>(t1 - t0).count());
    }
    std::sort(times.begin(), times.end());
    return times[times.size() / 2];
  }
};

struct BlockBenchmark {
  uint32_t block;
  double budgetUs;
  double multicoreUs;
  double serialUs;
  double multicorePct;
  double serialPct;
  double noFxUs;
  double ampLowerUs;
};

struct SingleProfileReport {
  std::string name;
  std::vector<BlockBenchmark> blocks;
};

SingleProfileReport runSingleProfile(const json& presetJson, const std::string& name) {
  SingleProfileReport rep;
  rep.name = name;
  for (uint32_t blk : {32u, 64u, 128u}) {
    BlockBenchmark bb{};
    bb.block = blk;
    bb.budgetUs = (static_cast<double>(blk) / kRate) * 1.0e6;

    {
      ProfilerHost host(presetJson, blk, 3, "full");
      bb.multicoreUs = host.benchmarkMedian();
      bb.multicorePct = (bb.multicoreUs / bb.budgetUs) * 100.0;
    }
    {
      ProfilerHost host(presetJson, blk, 0, "full");
      bb.serialUs = host.benchmarkMedian();
      bb.serialPct = (bb.serialUs / bb.budgetUs) * 100.0;
    }
    {
      ProfilerHost host(presetJson, blk, 3, "no-fx");
      bb.noFxUs = host.benchmarkMedian();
    }
    {
      ProfilerHost host(presetJson, blk, 3, "amp-one-step-lower");
      bb.ampLowerUs = host.benchmarkMedian();
    }
    rep.blocks.push_back(bb);
  }
  return rep;
}

NSString* formatSingleReport(const SingleProfileReport& rep) {
  NSMutableString* s = [NSMutableString string];
  [s appendString:@"================================================================================\n"];
  [s appendFormat:@"AXE FX — PRESET PERFORMANCE PROFILE: %@\n", [NSString stringWithUTF8String:rep.name.c_str()]];
  [s appendString:@"Session: 96.0 kHz  ·  Budget = Audio buffer period (100% = underrun threshold)\n"];
  [s appendString:@"================================================================================\n\n"];

  [s appendString:@"AUDIO BUFFER PERFORMANCE & HEADROOM:\n"];
  [s appendString:@"--------------------------------------------------------------------------------\n"];
  [s appendString:@"Buffer Size    Period Budget    Multicore (3 Helpers)    Serial (0 Helpers)     Status\n"];
  [s appendString:@"--------------------------------------------------------------------------------\n"];

  for (const auto& b : rep.blocks) {
    NSString* status = b.multicorePct <= 75.0 ? @"SAFE"
                     : b.multicorePct <= 100.0 ? @"ACCEPTABLE"
                                              : @"OVERRUN DANGER";
    if (b.serialPct > 100.0 && b.multicorePct <= 100.0) {
      status = [NSString stringWithFormat:@"%@ (Needs Multicore)", status];
    }
    [s appendFormat:@"%3u samples    %6.1f µs         %5.1f µs (%5.1f%%)       %5.1f µs (%5.1f%%)     %@\n",
                    b.block, b.budgetUs, b.multicoreUs, b.multicorePct, b.serialUs, b.serialPct, status];
  }
  [s appendString:@"--------------------------------------------------------------------------------\n\n"];

  if (rep.blocks.size() >= 2) {
    const auto& b64 = rep.blocks[1]; // 64 samples
    const double fxCost = std::max(0.0, b64.multicoreUs - b64.noFxUs);
    const double fxPct = (fxCost / std::max(1.0, b64.multicoreUs)) * 100.0;
    const double lowerSave = std::max(0.0, b64.multicoreUs - b64.ampLowerUs);
    const double lowerPct = (lowerSave / std::max(1.0, b64.multicoreUs)) * 100.0;

    [s appendString:@"COMPONENT BREAKDOWN & WHAT-IF OPTIMIZATIONS (at 64 samples):\n"];
    [s appendString:@"--------------------------------------------------------------------------------\n"];
    [s appendFormat:@"  • Stereo Reverb / Delay FX:    %5.1f µs (%4.1f%% of callback)\n", fxCost, fxPct];
    [s appendFormat:@"  • Performance Mode True 4×:   Saves %5.1f µs (-%4.1f%% total CPU)\n", lowerSave, lowerPct];
    [s appendString:@"--------------------------------------------------------------------------------\n\n"];
  }

  [s appendString:@"STATUS & ADVICE:\n"];
  [s appendString:@"--------------------------------------------------------------------------------\n"];
  if (!rep.blocks.empty()) {
    const auto& b32 = rep.blocks[0];
    if (b32.multicorePct <= 70.0) {
      [s appendFormat:@"  ✓ Excellent headroom at 32 samples (%.1f%% of budget used with 3 helpers).\n", b32.multicorePct];
    } else if (b32.multicorePct <= 100.0) {
      [s appendFormat:@"  ✓ Playable at 32 samples (%.1f%% budget used). Consider True 4x for extra margin.\n", b32.multicorePct];
    } else {
      [s appendString:@"  ⚠️ Warning: 32-sample buffer exceeds time budget! Select 'Performance Mode -> True 4x'\n"
                       "     or use a 64-sample buffer to prevent audio dropouts.\n"];
    }
    if (b32.serialPct > 100.0) {
      [s appendString:@"  • Multicore acceleration is actively preventing buffer dropouts on this preset.\n"];
    }
  }
  [s appendString:@"================================================================================\n"];
  return s;
}

void showReportWindow(NSString* reportText, NSString* title) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSRect frame = NSMakeRect(0, 0, 780, 520);
    NSWindow* win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskTitled |
                                                          NSWindowStyleMaskClosable |
                                                          NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = title;
    win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [win center];

    NSView* content = [[NSView alloc] initWithFrame:frame];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    win.contentView = content;

    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 52, 780 - 32, 520 - 68)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.borderType = NSBezelBorder;

    NSTextView* tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    tv.textColor = [NSColor colorWithSRGBRed:0.86 green:0.90 blue:0.96 alpha:1.0];
    tv.backgroundColor = [NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0];
    tv.string = reportText;
    scroll.documentView = tv;
    [content addSubview:scroll];

    NSButton* copyBtn = [NSButton buttonWithTitle:@"Copy to Clipboard" target:nil action:nil];
    copyBtn.bezelStyle = NSBezelStyleRounded;
    copyBtn.frame = NSMakeRect(16, 12, 140, 32);
    copyBtn.target = copyBtn;
    [copyBtn setAction:@selector(copyToClipboard:)];
    objc_setAssociatedObject(copyBtn, "reportText", reportText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [content addSubview:copyBtn];

    NSButton* closeBtn = [NSButton buttonWithTitle:@"Close" target:win action:@selector(close)];
    closeBtn.bezelStyle = NSBezelStyleRounded;
    closeBtn.frame = NSMakeRect(780 - 16 - 90, 12, 90, 32);
    closeBtn.keyEquivalent = @"\r";
    [content addSubview:closeBtn];

    [win makeKeyAndOrderFront:nil];
  });
}

} // namespace

@implementation RigStandaloneProfiler

+ (void)profileActivePresetWithParentWindow:(NSWindow*)parentWindow {
  RigPresetManager* mgr = [RigPresetManager sharedManager];
  [mgr ensureDefaultPresetExists];
  [mgr rescanPresets];
  NSString* name = mgr.currentPresetName;
  if (!name || name.length == 0) {
    if (mgr.presetNames.count > 0) {
      name = mgr.presetNames[0];
    } else {
      name = @"Default Rig";
    }
  }
  NSString* path = [mgr.presetsDirectory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]];

  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Cannot Profile Preset";
    alert.informativeText = [NSString stringWithFormat:@"Preset file '%@.json' not found on disk.", name];
    if (parentWindow) [alert beginSheetModalForWindow:parentWindow completionHandler:nil];
    else [alert runModal];
    return;
  }

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    std::ifstream file([path UTF8String]);
    if (!file.is_open()) return;
    json presetJson;
    try {
      file >> presetJson;
    } catch (...) {
      return;
    }
    SingleProfileReport rep = runSingleProfile(presetJson, [name UTF8String]);
    NSString* report = formatSingleReport(rep);
    showReportWindow(report, [NSString stringWithFormat:@"Axe FX Performance Profile — %@", name]);
  });
}

+ (void)profileAllPresetsWithParentWindow:(NSWindow*)parentWindow {
  RigPresetManager* mgr = [RigPresetManager sharedManager];
  [mgr ensureDefaultPresetExists];
  [mgr rescanPresets];
  NSString* dir = mgr.presetsDirectory;
  NSArray<NSString*>* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
  NSMutableArray<NSString*>* presetFiles = [NSMutableArray array];
  for (NSString* f in files) {
    if ([f.pathExtension.lowercaseString isEqualToString:@"json"]) {
      [presetFiles addObject:[dir stringByAppendingPathComponent:f]];
    }
  }

  if (presetFiles.count == 0) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"No Presets Found";
    alert.informativeText = @"No preset JSON files found in Application Support/Axe FX/Presets.";
    if (parentWindow) [alert beginSheetModalForWindow:parentWindow completionHandler:nil];
    else [alert runModal];
    return;
  }

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    struct SummaryRow {
      std::string name;
      double b32Pct;
      double b64Pct;
      double b128Pct;
    };
    std::vector<SummaryRow> rows;

    for (NSString* p in presetFiles) {
      std::ifstream file([p UTF8String]);
      if (!file.is_open()) continue;
      json pj;
      try { file >> pj; } catch (...) { continue; }
      std::string stem = [[p.lastPathComponent stringByDeletingPathExtension] UTF8String];
      try {
        SingleProfileReport rep = runSingleProfile(pj, stem);
        if (rep.blocks.size() >= 3) {
          rows.push_back({stem, rep.blocks[0].multicorePct, rep.blocks[1].multicorePct, rep.blocks[2].multicorePct});
        }
      } catch (...) {}
    }

    // Sort by 32-sample load (heaviest first)
    std::sort(rows.begin(), rows.end(), [](const SummaryRow& a, const SummaryRow& b) {
      return a.b32Pct > b.b32Pct;
    });

    NSMutableString* s = [NSMutableString string];
    [s appendString:@"================================================================================\n"];
    [s appendString:@"AXE FX — ALL PRESETS PERFORMANCE BENCHMARK SUMMARY\n"];
    [s appendFormat:@"Session: 96.0 kHz  ·  Total Presets Evaluated: %zu\n", rows.size()];
    [s appendString:@"Ranked from Heaviest to Lightest CPU load at 32 samples (Multicore enabled)\n"];
    [s appendString:@"================================================================================\n\n"];
    [s appendString:@" #   Preset Name                          32-Smp CPU%    64-Smp CPU%    32-Smp Status\n"];
    [s appendString:@"--------------------------------------------------------------------------------\n"];

    for (size_t i = 0; i < rows.size(); ++i) {
      const auto& r = rows[i];
      NSString* status = r.b32Pct <= 75.0 ? @"SAFE (Good Headroom)"
                       : r.b32Pct <= 100.0 ? @"ACCEPTABLE"
                                           : @"OVERRUN RISK";
      [s appendFormat:@"%2zu.  %-35s  %6.1f%%        %6.1f%%        %@\n",
                      i + 1, r.name.substr(0, 35).c_str(), r.b32Pct, r.b64Pct, status];
    }
    [s appendString:@"--------------------------------------------------------------------------------\n\n"];
    [s appendString:@"KEY TAKEAWAYS:\n"];
    [s appendString:@"  • Presets with <75% CPU load at 32 samples run reliably with low latency.\n"];
    [s appendString:@"  • Presets exceeding 75% at 32 samples benefit immediately from choosing:\n"];
    [s appendString:@"    Performance Mode -> True 4x (Low Latency / Live) from the Axe FX menu.\n"];
    [s appendString:@"================================================================================\n"];

    showReportWindow(s, @"Axe FX — All Presets Performance Benchmark");
  });
}

@end

// Category to handle copy-to-clipboard on the report button
@interface NSButton (ReportCopyHandler)
- (void)copyToClipboard:(id)sender;
@end

@implementation NSButton (ReportCopyHandler)
- (void)copyToClipboard:(id)sender {
  NSString* text = objc_getAssociatedObject(self, "reportText");
  if (text) {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
    self.title = @"Copied!";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      self.title = @"Copy to Clipboard";
    });
  }
}
@end
