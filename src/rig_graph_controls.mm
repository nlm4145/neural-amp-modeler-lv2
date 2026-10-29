#import "rig_graph_controls.h"
#import "rig_ui_state.h"
#include "rig_control_contract.h"
#include "overdrive.h"
#include "dynamics.h"
#include <cstring>

namespace {
// Handles edit existing ports only. No additional processing or audio-thread work.
NAMGraphControlPin* controlPin(RigUIState* state, NSString* name, int xPort, int yPort,
                              NSPoint (^position)(NSRect), float xScale = 1, float yScale = 1, BOOL labelBelow = NO) {
  NAMGraphControlPin* pin = [NAMGraphControlPin new];
  pin.label = name;
  pin.labelBelow = labelBelow;
  pin.position = position;
  auto alive = state->isAlive;
  __block float startX = 0, startY = 0;
  __block BOOL changed = NO;
  pin.isEnabled = ^BOOL {
    if (!alive || !*alive) return NO;
    for (int port : {xPort, yPort})
      if (port >= (int)NAMRig::kTransformerControlFirstPort &&
          port < (int)(NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount) &&
          state->transformerProfile == 0) return NO;
    return YES;
  };
  pin.onBegin = ^{
    if (!alive || !*alive) return;
    startX = xPort >= 0 ? state->currentPortValueForSlot(xPort) : 0;
    startY = yPort >= 0 ? state->currentPortValueForSlot(yPort) : 0;
    changed = NO;
  };
  pin.onDrag = ^(NSPoint delta) {
    if (!alive || !*alive) return;
    bool wrote = false;
    const auto move = [&](int port, float initial, double distance) {
      if (port < 0 || distance == 0) return;
      const auto* contract = NAMRig::rigControlContract(port);
      if (!contract) return;
      float minimum = contract->minimum, maximum = contract->maximum;
      bool logarithmic = minimum > 0 && (strcmp(contract->unit, "Hz") == 0 ||
          strcmp(contract->unit, "ms") == 0 || strcmp(contract->unit, "x") == 0);
      double value = logarithmic ? std::exp(std::log(std::max(initial, minimum)) +
          distance * std::log(maximum / minimum)) : initial + distance * (maximum - minimum);
      value = std::clamp(value, (double)minimum, (double)maximum);
      if (contract->integer) value = std::round(value);
      if (port >= (int)NAMRig::kTransformerControlFirstPort &&
          port < (int)(NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount)) {
        if (state->transformerProfile == 0) return;
        const size_t index = port - NAMRig::kTransformerControlFirstPort;
        const auto base = NAMRig::OutputTransformer::controlValues(
            NAMRig::OutputTransformer::parametersForProfile(state->transformerProfile));
        const auto range = state->transformerControlRange(index);
        const bool ratio = NAMRig::kTransformerControls[index].defaultValue == 1;
        double absolute = ratio ? value * base[index] : value + base[index];
        absolute = std::clamp(absolute, (double)range[0], (double)range[1]);
        value = ratio ? absolute / base[index] : absolute - base[index];
      }
      if (std::fabs(value - state->currentPortValueForSlot(port)) < 1e-6) return;
      state->sendControl(port, (float)value);
      state->updateControl(port, (float)value);
      wrote = true;
    };
    move(xPort, startX, delta.x * xScale);
    move(yPort, startY, delta.y * yScale);
    if (wrote) changed = YES;
  };
  pin.onCommit = ^{
    if (!alive || !*alive || !changed) return;
    state->markModified();
    changed = NO;
  };
  return pin;
}
void attach(NSView* graph, NSArray<NAMGraphControlPin*>* pins) {
  if (!graph) return;
  NAMGraphControlEditor* editor = [[NAMGraphControlEditor alloc] initWithFrame:graph.bounds];
  editor.pins = pins;
  editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  editor.toolTip = @"Drag the labeled pins to edit the response. Hold Shift for fine adjustment. Double-click empty frequency plots to add EQ pins.";
  [graph addSubview:editor];
}
NSPoint frequencyPoint(NSView* graph, NAMPinEQEditor* editor, double hz) {
  NSRect plot = NSInsetRect(editor.bounds, kPinEditorInset, kPinEditorInset);
  NSPoint p = NSMakePoint(NSMinX(plot) + NSWidth(plot) * std::log(std::clamp(hz, 20.0, 20000.0) / 20) / std::log(1000.0),
      NSMidY(plot) + NSHeight(plot) * std::clamp([editor responseDbAtFrequency:hz] / 36.0, -0.5, 0.5));
  return [editor convertPoint:p toView:graph];
}
}

void rigInstallGraphControls(RigUIState* state) {
  __weak NAMPowerStageVisualizer* power = state->powerVisualizer;
  const auto powerPoint = ^NSPoint(NSRect r, double input) {
    double output = std::tanh((input + power.bias * .0025) * 1.8) * (1 - power.sag * .004);
    return NSMakePoint(NSWidth(r) * .46 + input * NSWidth(r) * .72 * .48,
        12 + (NSHeight(r) - 56) * (.5 + output * .45));
  };
  attach(power, @[
    controlPin(state, @"BIAS ↔", 37, -1, ^NSPoint(NSRect r) { return powerPoint(r, -power.bias * .0025); }, -2),
    controlPin(state, @"SAG ↕", -1, 36, ^NSPoint(NSRect r) { return powerPoint(r, .75); }, 1, -2)
  ]);

  for (size_t which = 0; which < 2; ++which) {
    __weak NAMCompressorVisualizer* comp = which ? state->postCompressorVisualizer : state->compressorVisualizer;
    const int amountPort = which ? NAMRig::kPostCompressorAmountPort : 28;
    const int attackPort = which ? NAMRig::kPostCompressorAttackPort : NAMRig::kCompressorAttackPort;
    const int releasePort = which ? NAMRig::kPostCompressorReleasePort : NAMRig::kCompressorReleasePort;
    attach(comp, @[
      controlPin(state, @"AMOUNT ↔", amountPort, -1, ^NSPoint(NSRect r) { return [comp controlPointForIndex:0]; }, -2),
      controlPin(state, @"ATTACK ↔", attackPort, -1, ^NSPoint(NSRect r) { return [comp controlPointForIndex:1]; }, 2, 1, YES),
      controlPin(state, @"RELEASE ↔", releasePort, -1, ^NSPoint(NSRect r) { return [comp controlPointForIndex:2]; }, 2, 1, YES)
    ]);
  }
  __weak NAMDelayTapVisualizer* delay = state->delayVisualizer;
  attach(delay, @[
    controlPin(state, @"TIME ↔ / MIX ↕", 50, 53, ^NSPoint(NSRect r) { return [delay controlPointForIndex:0]; }),
    controlPin(state, @"FEEDBACK ↕", -1, 51, ^NSPoint(NSRect r) { return [delay controlPointForIndex:1]; }, 1, 2)
  ]);
  __weak NAMReverbDecayVisualizer* reverb = state->reverbVisualizer;
  attach(reverb, @[
    controlPin(state, @"PRE-DELAY ↔ / MIX ↕", 58, 54, ^NSPoint(NSRect r) { return [reverb controlPointForIndex:0]; }, 2, 1, YES),
    controlPin(state, @"DECAY ↔", 55, -1, ^NSPoint(NSRect r) { return [reverb controlPointForIndex:1]; }, 2)
  ]);

  __weak NAMSpatialAcousticVisualizer* spatial = state->spatialVisualizer;
  attach(spatial, @[
    controlPin(state, @"WIDTH ↔", 32, -1, ^NSPoint(NSRect r) {
      double split = NSWidth(r) * .46, radius = std::min(split * .36, (NSHeight(r) - 36) * .44);
      return NSMakePoint(split * .5 + radius * spatial.width / 100, (NSHeight(r) - 20) * .5 + 14);
    }, 2),
    controlPin(state, @"ROOM ↕", -1, 33, ^NSPoint(NSRect r) {
      double split = NSWidth(r) * .46;
      return NSMakePoint(split + 16 + (NSWidth(r) - split - 32) * .8,
          10 + (NSHeight(r) - 48) * (.3 + .55 * spatial.room / 100));
    }, 1, 2)
  ]);

  __weak NAMBoostVisualizer* boost = state->boostVisualizer;
  attach(boost, @[
    controlPin(state, @"DRIVE ↕", -1, NAMRig::kOverdriveDrivePort, ^NSPoint(NSRect r) { return [boost controlPointForIndex:0]; }, 1, 2, YES),
    controlPin(state, @"TIGHT ↔", NAMRig::kOverdriveTightPort, -1, ^NSPoint(NSRect r) { return [boost controlPointForIndex:1]; }, 2),
    controlPin(state, @"TONE ↕", -1, NAMRig::kOverdriveTonePort, ^NSPoint(NSRect r) { return [boost controlPointForIndex:2]; }, 1, 2)
  ]);

  __weak NAMPowerTubeVisualizer* tube = state->powerTubeVisualizer;
  attach(tube, @[controlPin(state, @"CHARACTER ↕", -1, NAMRig::kPowerTubeCharacterPort, ^NSPoint(NSRect r) {
    const auto& profile = NAMRig::PowerTube::kProfiles[NAMRig::PowerTube::clampProfile(tube.profile)];
    const auto& base = NAMRig::PowerTube::kProfiles[NAMRig::PowerTube::kCaptured];
    double a = tube.enabled && tube.profile != 0 ? tube.character * .01 : 0;
    double knee = base.knee + a * (profile.knee - base.knee), headroom = base.headroom + a * (profile.headroom - base.headroom);
    double asymmetry = base.asymmetry + a * (profile.asymmetry - base.asymmetry);
    const auto sat = [knee](double x) {
      double v = std::abs(x); if (v <= knee) return x;
      return std::copysign(knee + (1 - knee) * (v - knee) / (1 - knee + v - knee), x);
    };
    double shaped = headroom * (sat(.65 / headroom + asymmetry) - sat(asymmetry));
    double y = .65 + a * (shaped - .65);
    return NSMakePoint(31 + (NSWidth(r) - 50) * .825, 39 + (NSHeight(r) - 104) * (.5 + y * .5));
  }, 1, -2)]);

  __weak NAMTransformerVisualizer* transformer = state->transformerVisualizer;
  attach(transformer, @[
    controlPin(state, @"DRIVE ↔ / MIX ↕", 62, 63, ^NSPoint(NSRect r) {
      const auto p = transformer.parameters;
      const auto sigmoid = [](double v) { return v / std::sqrt(1 + v * v); };
      double y = .65 + p.saturationMix * ((sigmoid(p.drive * .65 + p.asymmetry) - sigmoid(p.asymmetry)) / p.drive - .65);
      double split = std::round(NSWidth(r) * .36);
      return NSMakePoint(split * .5 + .65 * (split - 24) * .46, 10 + (NSHeight(r) - 48) * .5 + y * (NSHeight(r) - 54) * .45);
    }, 2, -2),
    controlPin(state, @"LOW CUT ↔", 60, -1, ^NSPoint(NSRect r) { return frequencyPoint(transformer, transformer.pinEditor, transformer.parameters.lowCutHz); }, 2),
    controlPin(state, @"HIGH CUT ↔", 61, -1, ^NSPoint(NSRect r) { return frequencyPoint(transformer, transformer.pinEditor, transformer.parameters.highCutHz); }, 2),
    controlPin(state, @"VOICE ↔ ↕", 65, 66, ^NSPoint(NSRect r) { return frequencyPoint(transformer, transformer.pinEditor, transformer.parameters.voiceHz); }, 2, 2),
    controlPin(state, @"LEAKAGE ↔ ↕", 68, 69, ^NSPoint(NSRect r) { return frequencyPoint(transformer, transformer.pinEditor, transformer.parameters.leakageHz); }, 2, 2)
  ]);
}
