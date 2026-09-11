#import <Cocoa/Cocoa.h>

#include <lv2/atom/atom.h>
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <lv2/core/lv2.h>
#include <lv2/patch/patch.h>
#include <lv2/ui/ui.h>
#include <lv2/urid/urid.h>

#include <cstring>
#include <string>
#include <vector>

#import "rig_theme.h"
#import "rig_widgets.h"

constexpr const char* kPluginURI = "http://github.com/mikeoliphant/neural-amp-modeler-lv2";
constexpr const char* kUIURI = "http://github.com/mikeoliphant/neural-amp-modeler-lv2#cocoa-ui";
constexpr const char* kModelURI = "http://github.com/mikeoliphant/neural-amp-modeler-lv2#model";

struct UIState;

@interface NAMUIController : NSObject
@property(nonatomic, assign) UIState* state;
- (void)chooseModel:(id)sender;
- (void)controlChanged:(NSSlider*)sender;
@end

struct UIState {
  LV2UI_Write_Function write = nullptr;
  LV2UI_Controller controller = nullptr;
  LV2_URID_Map* map = nullptr;
  LV2_Atom_Forge forge{};

  LV2_URID atomEventTransfer = 0;
  LV2_URID atomObject = 0;
  LV2_URID atomPath = 0;
  LV2_URID atomURID = 0;
  LV2_URID patchGet = 0;
  LV2_URID patchSet = 0;
  LV2_URID patchProperty = 0;
  LV2_URID patchValue = 0;
  LV2_URID modelPath = 0;

  __strong NSView* view = nil;
  __weak NSView* parent = nil;
  __strong NSTextField* pathLabel = nil;
  __strong NAMUIController* uiController = nil;
  __strong NSSlider* inputSlider = nil;
  __strong NSSlider* qualitySlider = nil;
  __strong NSSlider* outputSlider = nil;
  __strong NSTextField* inputValue = nil;
  __strong NSTextField* qualityValue = nil;
  __strong NSTextField* outputValue = nil;
  LV2UI_Resize* hostResize = nullptr;

  void sendControl(uint32_t port, float value) {
    write(controller, port, sizeof(value), 0, &value);
  }

  void updateControl(uint32_t port, float value) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSSlider* slider = nil;
      NSTextField* label = nil;
      NSString* text = nil;

      if (port == 4) {
        slider = inputSlider;
        label = inputValue;
        text = [NSString stringWithFormat:@"%+.1f dB", value];
      } else if (port == 5) {
        slider = outputSlider;
        label = outputValue;
        text = [NSString stringWithFormat:@"%+.1f dB", value];
      } else if (port == 6) {
        slider = qualitySlider;
        label = qualityValue;
        text = [NSString stringWithFormat:@"%.0f%%", value * 100.0f];
      }

      if (slider && label) {
        slider.floatValue = value;
        label.stringValue = text;
      }
    });
  }

  void sendGet() {
    std::vector<uint8_t> buffer(256);
    lv2_atom_forge_set_buffer(&forge, buffer.data(), buffer.size());

    LV2_Atom_Forge_Frame frame{};
    auto* message = reinterpret_cast<LV2_Atom*>(
        lv2_atom_forge_object(&forge, &frame, 0, patchGet));
    if (!message)
      return;

    lv2_atom_forge_pop(&forge, &frame);
    write(controller, 0, lv2_atom_total_size(message), atomEventTransfer, message);
  }

  void sendModelPath(const char* path) {
    if (!path || !*path)
      return;

    const size_t pathLength = std::strlen(path) + 1;
    std::vector<uint8_t> buffer(pathLength + 256);
    lv2_atom_forge_set_buffer(&forge, buffer.data(), buffer.size());

    LV2_Atom_Forge_Frame frame{};
    auto* message = reinterpret_cast<LV2_Atom*>(
        lv2_atom_forge_object(&forge, &frame, 0, patchSet));
    if (!message)
      return;

    lv2_atom_forge_key(&forge, patchProperty);
    lv2_atom_forge_urid(&forge, modelPath);
    lv2_atom_forge_key(&forge, patchValue);
    lv2_atom_forge_path(&forge, path, static_cast<uint32_t>(pathLength));
    lv2_atom_forge_pop(&forge, &frame);

    write(controller, 0, lv2_atom_total_size(message), atomEventTransfer, message);
    setDisplayedPath(path);
  }

  void setDisplayedPath(const char* path) {
    const std::string copy = path ? path : "";
    dispatch_async(dispatch_get_main_queue(), ^{
      if (copy.empty()) {
        pathLabel.stringValue = @"No model loaded";
        pathLabel.toolTip = @"The active neural model file. No model is currently loaded.";
      } else {
        NSString* fullPath = [NSString stringWithUTF8String:copy.c_str()];
        pathLabel.stringValue = fullPath.lastPathComponent;
        pathLabel.toolTip = [NSString stringWithFormat:
            @"The active neural model file. Current file: %@", fullPath];
      }
    });
  }
};

@implementation NAMUIController
- (void)chooseModel:(id)sender {
  (void)sender;
  if (!_state)
    return;

  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Choose a Neural Amp Model";
  panel.prompt = @"Load Model";
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  panel.allowedFileTypes = @[@"nam", @"nammodel", @"json", @"aidax", @"aidadspmodel"];

  if ([panel runModal] == NSModalResponseOK) {
    const char* path = panel.URL.path.fileSystemRepresentation;
    _state->sendModelPath(path);
  }
}

- (void)controlChanged:(NSSlider*)sender {
  if (!_state)
    return;

  const uint32_t port = (uint32_t)sender.tag;
  const float value = sender.floatValue;
  _state->sendControl(port, value);
  _state->updateControl(port, value);
}
@end

static NSTextField* addText(NSView* parent,
                            NSString* text,
                            NSRect frame,
                            NSFont* font,
                            NSColor* color) {
  NSTextField* label = [NSTextField labelWithString:text];
  label.frame = frame;
  label.font = font;
  label.textColor = color;
  label.alignment = NSTextAlignmentCenter;
  [parent addSubview:label];
  return label;
}

static NSSlider* addKnob(NSView* parent,
                         NSInteger port,
                         double value,
                         double minimum,
                         double maximum,
                         NSPoint origin,
                         id target) {
  RigKnob* knob = [[RigKnob alloc] initWithFrame:NSMakeRect(origin.x, origin.y, 64, 64)];
  knob.minValue = minimum;
  knob.maxValue = maximum;
  knob.doubleValue = value;
  knob.defaultValue = value;
  knob.target = target;
  knob.action = @selector(controlChanged:);
  knob.continuous = YES;
  knob.tag = port;
  [parent addSubview:knob];
  return knob;
}

LV2UI_Handle instantiate(const LV2UI_Descriptor*,
                         const char* pluginURI,
                         const char*,
                         LV2UI_Write_Function writeFunction,
                         LV2UI_Controller controller,
                         LV2UI_Widget* widget,
                         const LV2_Feature* const* features) {
  if (!pluginURI || std::strcmp(pluginURI, kPluginURI) != 0 ||
      !writeFunction || !controller || !widget) {
    return nullptr;
  }

  LV2_URID_Map* map = nullptr;
  NSView* parent = nil;
  LV2UI_Resize* hostResize = nullptr;
  for (const LV2_Feature* const* feature = features; feature && *feature; ++feature) {
    if (std::strcmp((*feature)->URI, LV2_URID__map) == 0) {
      map = static_cast<LV2_URID_Map*>((*feature)->data);
    } else if (std::strcmp((*feature)->URI, LV2_UI__parent) == 0) {
      parent = (__bridge NSView*)(*feature)->data;
    } else if (std::strcmp((*feature)->URI, LV2_UI__resize) == 0) {
      hostResize = static_cast<LV2UI_Resize*>((*feature)->data);
    }
  }
  if (!map || !parent)
    return nullptr;

  @autoreleasepool {
    auto* state = new UIState();
    state->write = writeFunction;
    state->controller = controller;
    state->map = map;
    state->parent = parent;
    state->hostResize = hostResize;
    state->atomEventTransfer = map->map(map->handle, LV2_ATOM__eventTransfer);
    state->atomObject = map->map(map->handle, LV2_ATOM__Object);
    state->atomPath = map->map(map->handle, LV2_ATOM__Path);
    state->atomURID = map->map(map->handle, LV2_ATOM__URID);
    state->patchGet = map->map(map->handle, LV2_PATCH__Get);
    state->patchSet = map->map(map->handle, LV2_PATCH__Set);
    state->patchProperty = map->map(map->handle, LV2_PATCH__property);
    state->patchValue = map->map(map->handle, LV2_PATCH__value);
    state->modelPath = map->map(map->handle, kModelURI);
    lv2_atom_forge_init(&state->forge, map);

    state->view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 258)];
    state->view.wantsLayer = YES;
    state->view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    state->view.layer.backgroundColor = rigBG().CGColor;

    NSTextField* title = [NSTextField labelWithString:@"NEURAL AMP MODELER"];
    title.font = [NSFont systemFontOfSize:15.0 weight:NSFontWeightBold];
    title.textColor = rigText();
    rigApplyTracking(title, 1.6);
    title.frame = NSMakeRect(18, 218, 340, 24);
    title.alignment = NSTextAlignmentLeft;
    title.toolTip = @"The compact single-model Neural Amp Modeler plug-in.";
    [state->view addSubview:title];

    state->pathLabel = [NSTextField labelWithString:@"No model loaded"];
    state->pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    state->pathLabel.textColor = rigDimText();
    state->pathLabel.font = [NSFont systemFontOfSize:12.0];
    state->pathLabel.frame = NSMakeRect(18, 180, 455, 24);
    state->pathLabel.toolTip = @"The active neural model file. No model is currently loaded.";
    [state->view addSubview:state->pathLabel];

    state->uiController = [[NAMUIController alloc] init];
    state->uiController.state = state;

    RigButton* choose = [[RigButton alloc] initWithFrame:NSMakeRect(540, 176, 162, 30)];
    choose.title = @"Choose NAM Model…";
    choose.bordered = NO;
    choose.primary = YES;
    choose.target = state->uiController;
    choose.action = @selector(chooseModel:);
    choose.toolTip = @"Choose and load a NAM, NAMModel, JSON, AIDA-X, or AIDA DSP model file.";
    [state->view addSubview:choose];

    RigPanel* panel = [[RigPanel alloc] initWithFrame:NSMakeRect(18, 26, 684, 130)];
    panel.toolTip = @"Model level and quality controls.";
    [state->view addSubview:panel];

    state->inputSlider = addKnob(state->view, 4, 0.0, -20.0, 20.0,
                                 NSMakePoint(112, 78), state->uiController);
    state->qualitySlider = addKnob(state->view, 6, 1.0, 0.0, 1.0,
                                   NSMakePoint(328, 78), state->uiController);
    state->outputSlider = addKnob(state->view, 5, 0.0, -20.0, 20.0,
                                   NSMakePoint(544, 78), state->uiController);

    NSArray<NSString*>* controlTips = @[
      @"Input trim before the neural model. Positive values drive the capture harder; negative values clean it up.",
      @"Model quality scale. Higher values use the fullest available model tier and may increase CPU usage.",
      @"Final output trim after the neural model."
    ];
    NSArray<NSSlider*>* controlKnobs = @[state->inputSlider, state->qualitySlider,
                                         state->outputSlider];
    for (NSUInteger i = 0; i < controlKnobs.count; ++i)
      controlKnobs[i].toolTip = [NSString stringWithFormat:
          @"%@ Drag vertically; hold Shift for fine adjustment; double-click to reset.",
          controlTips[i]];

    NSFont* nameFont = [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold];
    NSTextField* inputName = addText(state->view, @"INPUT", NSMakeRect(92, 54, 104, 18),
                                    nameFont, rigDimText());
    NSTextField* qualityName = addText(state->view, @"QUALITY", NSMakeRect(308, 54, 104, 18),
                                      nameFont, rigDimText());
    NSTextField* outputName = addText(state->view, @"OUTPUT", NSMakeRect(524, 54, 104, 18),
                                     nameFont, rigDimText());
    rigApplyTracking(inputName, 1.1);
    rigApplyTracking(qualityName, 1.1);
    rigApplyTracking(outputName, 1.1);
    inputName.toolTip = controlTips[0];
    qualityName.toolTip = controlTips[1];
    outputName.toolTip = controlTips[2];

    state->inputValue = addText(state->view, @"+0.0 dB", NSMakeRect(92, 34, 104, 18),
                                [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular],
                                rigText());
    state->qualityValue = addText(state->view, @"100%", NSMakeRect(308, 34, 104, 18),
                                  [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular],
                                  rigText());
    state->outputValue = addText(state->view, @"+0.0 dB", NSMakeRect(524, 34, 104, 18),
                                 [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular],
                                 rigText());
    state->inputValue.toolTip = controlTips[0];
    state->qualityValue.toolTip = controlTips[1];
    state->outputValue.toolTip = controlTips[2];

    NSTextField* note = [NSTextField labelWithString:
        @"Set Element's sample rate before loading (96 kHz = 2× for a 48 kHz model)."];
    note.textColor = rigDimText();
    note.font = [NSFont systemFontOfSize:11.0];
    note.alignment = NSTextAlignmentCenter;
    note.frame = NSMakeRect(18, 8, 684, 18);
    note.toolTip = @"NAM models normally expect their training rate, usually 48 kHz. Integer multiples can be used for oversampled operation.";
    [state->view addSubview:note];

    // Cocoa LV2 hosts (including Element/JUCE) provide the native parent view.
    // The UI must embed itself there; merely returning an unattached NSView
    // produces an empty/black editor window in Element.
    [parent addSubview:state->view];
    state->view.frame = NSMakeRect(0, 0, 720, 258);

    if (hostResize && hostResize->ui_resize)
      hostResize->ui_resize(hostResize->handle, 720, 258);

    *widget = (__bridge void*)state->view;
    state->sendGet();
    return state;
  }
}

void cleanup(LV2UI_Handle handle) {
  auto* state = static_cast<UIState*>(handle);
  [state->view removeFromSuperview];
  delete state;
}

void portEvent(LV2UI_Handle handle,
               uint32_t portIndex,
               uint32_t bufferSize,
               uint32_t format,
               const void* buffer) {
  auto* state = static_cast<UIState*>(handle);
  if (!state)
    return;

  if (format == 0 && buffer && bufferSize == sizeof(float) &&
      (portIndex == 4 || portIndex == 5 || portIndex == 6)) {
    state->updateControl(portIndex, *static_cast<const float*>(buffer));
    return;
  }

  if (portIndex != 1 || format != state->atomEventTransfer ||
      !buffer || bufferSize < sizeof(LV2_Atom_Object)) {
    return;
  }

  const auto* atom = static_cast<const LV2_Atom*>(buffer);
  if (atom->type != state->atomObject)
    return;

  const auto* object = reinterpret_cast<const LV2_Atom_Object*>(atom);
  if (object->body.otype != state->patchSet)
    return;

  const LV2_Atom* property = nullptr;
  const LV2_Atom* value = nullptr;
  lv2_atom_object_get(object,
                      state->patchProperty, &property,
                      state->patchValue, &value,
                      0);

  if (!property || property->type != state->atomURID ||
      reinterpret_cast<const LV2_Atom_URID*>(property)->body != state->modelPath ||
      !value || value->type != state->atomPath || value->size == 0) {
    return;
  }

  state->setDisplayedPath(reinterpret_cast<const char*>(value + 1));
}

const void* extensionData(const char*) {
  return nullptr;
}

const LV2UI_Descriptor descriptor{
    kUIURI,
    instantiate,
    cleanup,
    portEvent,
    extensionData,
};

extern "C" __attribute__((visibility("default")))
const LV2UI_Descriptor* lv2ui_descriptor(uint32_t index) {
  return index == 0 ? &descriptor : nullptr;
}
