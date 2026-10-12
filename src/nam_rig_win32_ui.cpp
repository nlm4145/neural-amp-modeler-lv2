#include <windows.h>

#include <lv2/atom/atom.h>
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <lv2/core/lv2.h>
#include <lv2/patch/patch.h>
#include <lv2/ui/ui.h>
#include <lv2/urid/urid.h>

#include <array>
#include <cstring>
#include <memory>
#include <vector>

#include "nam_rig_plugin.h"
#include "win32_ui_view.h"

namespace {

static constexpr const char* kRigURI = NAM_RIG_URI;
static constexpr const char* kRigUIURI = NAM_RIG_URI "-ui";

static constexpr std::array<const char*, 4> kPathURIs = {
    NAM_RIG_PEDAL_URI, NAM_RIG_AMP_URI, NAM_RIG_CAB_URI, NAM_RIG_CAB2_URI};

struct Win32UI {
  LV2UI_Write_Function write = nullptr;
  LV2UI_Controller controller = nullptr;
  LV2_URID_Map* map = nullptr;
  HWND parent = NULL;
  LV2UI_Resize* hostResize = nullptr;

  LV2_URID eventTransfer = 0;
  LV2_URID atomObject = 0;
  LV2_URID atomPath = 0;
  LV2_URID atomURID = 0;
  LV2_URID patchGet = 0;
  LV2_URID patchSet = 0;
  LV2_URID patchProperty = 0;
  LV2_URID patchValue = 0;
  LV2_URID atomFloat = 0;
  LV2_URID tunerNoteURID = 0;
  LV2_URID tunerCentsURID = 0;
  LV2_URID inputDbURID = 0;
  LV2_URID outputDbURID = 0;
  std::array<LV2_URID, 4> pathURIDs = {};

  LV2_Atom_Forge forge{};
  std::unique_ptr<NAMRigWin32::Win32UIView> view;

  void sendControl(uint32_t port, float value) {
    if (write && controller) {
      write(controller, port, sizeof(float), 0, &value);
    }
  }

  void sendPath(size_t stage, const char* path) {
    if (stage >= pathURIDs.size() || !path || !write || !controller) return;
    const size_t length = std::strlen(path) + 1;
    std::vector<uint8_t> buffer(length + 256);
    lv2_atom_forge_set_buffer(&forge, buffer.data(), buffer.size());
    LV2_Atom_Forge_Frame frame{};
    auto* message = reinterpret_cast<LV2_Atom*>(lv2_atom_forge_object(&forge, &frame, 0, patchSet));
    if (!message) return;
    lv2_atom_forge_key(&forge, patchProperty);
    lv2_atom_forge_urid(&forge, pathURIDs[stage]);
    lv2_atom_forge_key(&forge, patchValue);
    lv2_atom_forge_path(&forge, path, static_cast<uint32_t>(length));
    lv2_atom_forge_pop(&forge, &frame);
    write(controller, 0, lv2_atom_total_size(message), eventTransfer, message);
  }
};

static LV2UI_Handle instantiate(
    const LV2UI_Descriptor* descriptor,
    const char* plugin_uri,
    const char* bundle_path,
    LV2UI_Write_Function write_function,
    LV2UI_Controller controller,
    LV2UI_Widget* widget,
    const LV2_Feature* const* features) {
  (void)descriptor; (void)bundle_path;
  if (!plugin_uri || std::strcmp(plugin_uri, kRigURI) != 0 || !write_function || !controller || !widget)
    return nullptr;

  LV2_URID_Map* map = nullptr;
  HWND parent = NULL;
  LV2UI_Resize* resize = nullptr;

  for (const LV2_Feature* const* feature = features; feature && *feature; ++feature) {
    if (!std::strcmp((*feature)->URI, LV2_URID__map)) {
      map = static_cast<LV2_URID_Map*>((*feature)->data);
    } else if (!std::strcmp((*feature)->URI, LV2_UI__parent)) {
      parent = static_cast<HWND>((*feature)->data);
    } else if (!std::strcmp((*feature)->URI, LV2_UI__resize)) {
      resize = static_cast<LV2UI_Resize*>((*feature)->data);
    }
  }

  if (!map || !parent) return nullptr;

  auto* ui = new Win32UI();
  ui->write = write_function;
  ui->controller = controller;
  ui->map = map;
  ui->parent = parent;
  ui->hostResize = resize;

  ui->eventTransfer = map->map(map->handle, LV2_ATOM__eventTransfer);
  ui->atomObject = map->map(map->handle, LV2_ATOM__Object);
  ui->atomPath = map->map(map->handle, LV2_ATOM__Path);
  ui->atomURID = map->map(map->handle, LV2_ATOM__URID);
  ui->patchGet = map->map(map->handle, LV2_PATCH__Get);
  ui->patchSet = map->map(map->handle, LV2_PATCH__Set);
  ui->patchProperty = map->map(map->handle, LV2_PATCH__property);
  ui->patchValue = map->map(map->handle, LV2_PATCH__value);
  ui->atomFloat = map->map(map->handle, LV2_ATOM__Float);
  ui->tunerNoteURID = map->map(map->handle, NAM_RIG_TUNER_NOTE_URI);
  ui->tunerCentsURID = map->map(map->handle, NAM_RIG_TUNER_CENTS_URI);
  ui->inputDbURID = map->map(map->handle, NAM_RIG_INPUT_DB_URI);
  ui->outputDbURID = map->map(map->handle, NAM_RIG_OUTPUT_DB_URI);
  for (size_t i = 0; i < kPathURIs.size(); ++i) {
    ui->pathURIDs[i] = map->map(map->handle, kPathURIs[i]);
  }
  lv2_atom_forge_init(&ui->forge, map);

  ui->view = std::make_unique<NAMRigWin32::Win32UIView>();
  HWND childHwnd = ui->view->create(parent, 0, 0, 1180, 780);
  if (!childHwnd) {
    delete ui;
    return nullptr;
  }

  ui->view->setOnControlChanged([ui](uint32_t port, float value) {
    ui->sendControl(port, value);
  });

  ui->view->setOnStageFileChanged([ui](uint32_t stage, const std::string& path) {
    ui->sendPath(stage, path.c_str());
  });

  if (ui->hostResize && ui->hostResize->ui_resize) {
    ui->hostResize->ui_resize(ui->hostResize->handle, 1180, 780);
  }

  *widget = static_cast<LV2UI_Widget>(childHwnd);
  return static_cast<LV2UI_Handle>(ui);
}

static void cleanup(LV2UI_Handle handle) {
  auto* ui = static_cast<Win32UI*>(handle);
  if (ui) {
    delete ui;
  }
}

static void port_event(
    LV2UI_Handle handle,
    uint32_t port_index,
    uint32_t buffer_size,
    uint32_t format,
    const void* buffer) {
  auto* ui = static_cast<Win32UI*>(handle);
  if (!ui || !buffer) return;

  // Float control ports (4..181)
  if (format == 0 && buffer_size == sizeof(float) &&
      port_index >= 4 && port_index < NAMRig::kRigControlPortCount) {
    float val = *static_cast<const float*>(buffer);
    ui->view->setControlValue(port_index, val, false);
    return;
  }

  // Atom events on notify port (port 1)
  if (port_index != 1 || format != ui->eventTransfer || buffer_size < sizeof(LV2_Atom_Object))
    return;

  const auto* atom = static_cast<const LV2_Atom*>(buffer);
  if (atom->type != ui->atomObject) return;

  const auto* object = reinterpret_cast<const LV2_Atom_Object*>(atom);
  if (object->body.otype != ui->patchSet) return;

  const LV2_Atom* property = nullptr;
  const LV2_Atom* value = nullptr;
  lv2_atom_object_get(object, ui->patchProperty, &property, ui->patchValue, &value, 0);

  if (!property || property->type != ui->atomURID || !value) return;
  const LV2_URID propID = reinterpret_cast<const LV2_Atom_URID*>(property)->body;

  if (value->type == ui->atomPath && value->size > 0) {
    for (size_t i = 0; i < ui->pathURIDs.size(); ++i) {
      if (propID == ui->pathURIDs[i]) {
        ui->view->setStagePath(static_cast<uint32_t>(i), reinterpret_cast<const char*>(value + 1));
      }
    }
    return;
  }

  if (value->type == ui->atomFloat && value->size == sizeof(float)) {
    float val = *reinterpret_cast<const float*>(value + 1);
    if (propID == ui->tunerNoteURID) {
      ui->view->setTuner(val, 0.0f);
    } else if (propID == ui->tunerCentsURID) {
      ui->view->setTuner(ui->view->getControlValue(16), val);
    } else if (propID == ui->inputDbURID) {
      ui->view->setAudioLevels(val, 0.0f);
    } else if (propID == ui->outputDbURID) {
      ui->view->setAudioLevels(0.0f, val);
    }
  }
}

static const void* extension_data(const char*) {
  return nullptr;
}

static const LV2UI_Descriptor descriptor = {
    kRigUIURI,
    instantiate,
    cleanup,
    port_event,
    extension_data};

} // namespace

extern "C" __declspec(dllexport)
const LV2UI_Descriptor* lv2ui_descriptor(uint32_t index) {
  return (index == 0) ? &descriptor : nullptr;
}
