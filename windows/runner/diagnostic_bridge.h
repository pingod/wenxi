#ifndef RUNNER_DIAGNOSTIC_BRIDGE_H_
#define RUNNER_DIAGNOSTIC_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

class DiagnosticBridge {
 public:
  explicit DiagnosticBridge(flutter::BinaryMessenger* messenger);
  ~DiagnosticBridge();
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
