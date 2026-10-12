#pragma once

#ifdef _WIN32
#include <windows.h>
#include <unknwn.h>
#endif

#include <cstdint>
#include <string>
#include <vector>

namespace NAMRigWin32 {

using ASIOBool = long;
using ASIOError = long;
using ASIOSampleRate = double;

enum {
  ASE_OK = 0,
  ASE_SUCCESS = 0x3f482c,
  ASE_NotPresent = -1000,
  ASE_HWMalfunction,
  ASE_InvalidParameter,
  ASE_InvalidMode,
  ASE_SPNotAdvancing,
  ASE_NoClock,
  ASE_NoMemory
};

enum ASIOSampleType {
  ASIOSTInt16MSB = 0,
  ASIOSTInt24MSB = 1,
  ASIOSTInt32MSB = 2,
  ASIOSTFloat32MSB = 3,
  ASIOSTFloat64MSB = 4,
  ASIOSTInt32MSB16 = 8,
  ASIOSTInt32MSB18 = 9,
  ASIOSTInt32MSB20 = 10,
  ASIOSTInt32MSB24 = 11,
  ASIOSTInt16LSB = 16,
  ASIOSTInt24LSB = 17,
  ASIOSTInt32LSB = 18,
  ASIOSTFloat32LSB = 19,
  ASIOSTFloat64LSB = 20,
  ASIOSTInt32LSB16 = 24,
  ASIOSTInt32LSB18 = 25,
  ASIOSTInt32LSB20 = 26,
  ASIOSTInt32LSB24 = 27
};

struct ASIOSamples {
  unsigned long hi = 0;
  unsigned long lo = 0;
};

struct ASIOTimeStamp {
  unsigned long hi = 0;
  unsigned long lo = 0;
};

struct ASIOChannelInfo {
  long channel = 0;
  ASIOBool isInput = 0;
  ASIOBool isActive = 0;
  long channelGroup = 0;
  ASIOSampleType type = ASIOSTFloat32LSB;
  char name[32] = {0};
};

struct ASIOBufferInfo {
  ASIOBool isInput = 0;
  long channelNum = 0;
  void* buffers[2] = {nullptr, nullptr};
};

struct ASIOTimeCode {
  double speed = 1.0;
  ASIOSamples timeCodeSamples{};
  unsigned long flags = 0;
  char future[64] = {0};
};

struct ASIOTimeInfo {
  double speed = 1.0;
  ASIOTimeStamp systemTime{};
  ASIOSamples samplePosition{};
  ASIOSampleRate sampleRate = 48000.0;
  unsigned long flags = 0;
  char reserved[12] = {0};
};

struct ASIOTime {
  long reserved[4] = {0};
  ASIOTimeInfo timeInfo{};
  ASIOTimeCode timeCode{};
};

struct ASIOCallbacks {
  void (*bufferSwitch)(long doubleBufferIndex, ASIOBool directProcess) = nullptr;
  void (*sampleRateDidChange)(ASIOSampleRate sRate) = nullptr;
  long (*asioMessage)(long selector, long value, void* message, double* opt) = nullptr;
  ASIOTime* (*bufferSwitchTimeInfo)(ASIOTime* params, long doubleBufferIndex, ASIOBool directProcess) = nullptr;
};

struct ASIOClockSource {
  long index = 0;
  long associatedChannel = 0;
  long associatedGroup = 0;
  ASIOBool isCurrentSource = 0;
  char name[32] = {0};
};

#ifdef _WIN32
// {96987720-16DE-11d1-833E-00A0C9691A13}
static const IID IID_IASIO = {
    0x96987720, 0x16DE, 0x11d1, {0x83, 0x3E, 0x00, 0xA0, 0xC9, 0x69, 0x1A, 0x13}};

class IASIO : public IUnknown {
 public:
  virtual ASIOBool init(void* sysHandle) = 0;
  virtual void getDriverName(char* name) = 0;
  virtual long getDriverVersion() = 0;
  virtual ASIOError getErrorMessage(char* string) = 0;
  virtual ASIOError start() = 0;
  virtual ASIOError stop() = 0;
  virtual ASIOError getChannels(long* numInputChannels, long* numOutputChannels) = 0;
  virtual ASIOError getLatencies(long* inputLatency, long* outputLatency) = 0;
  virtual ASIOError getBufferSize(long* minSize, long* maxSize, long* preferredSize, long* granularity) = 0;
  virtual ASIOError canSampleRate(ASIOSampleRate sampleRate) = 0;
  virtual ASIOError getSampleRate(ASIOSampleRate* sampleRate) = 0;
  virtual ASIOError setSampleRate(ASIOSampleRate sampleRate) = 0;
  virtual ASIOError getClockSources(ASIOClockSource* clocks, long* numSources) = 0;
  virtual ASIOError setClockSource(long reference) = 0;
  virtual ASIOError getSamplePosition(ASIOSamples* sPos, ASIOTimeStamp* tStamp) = 0;
  virtual ASIOError getChannelInfo(ASIOChannelInfo* info) = 0;
  virtual ASIOError createBuffers(ASIOBufferInfo* bufferInfos, long numChannels, long bufferSize, ASIOCallbacks* callbacks) = 0;
  virtual ASIOError disposeBuffers() = 0;
  virtual ASIOError controlPanel() = 0;
  virtual ASIOError future(long selector, void* opt) = 0;
  virtual ASIOError outputReady() = 0;
};
#endif

struct AsioDriverDesc {
  std::string name;
  std::string clsidString;
  CLSID clsid{};
};

std::vector<AsioDriverDesc> enumerateAsioDrivers();

} // namespace NAMRigWin32
