#include "diagnostic_bridge.h"
#include <flutter/standard_method_codec.h>
#include "native_diagnostics.h"
#include "utils.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

DiagnosticBridge::DiagnosticBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "com.asterlink.app/diagnostics", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const auto& call, auto result) {
    try {
      auto& recorder = NativeDiagnostics::Instance();
      if (call.method_name() == "diagnosticPaths") {
        if (recorder.directory().empty()) {
          result->Error("diagnostics_unavailable", "Windows diagnostic directory unavailable");
          return;
        }
        result->Success(EncodableValue(EncodableMap{
          {EncodableValue("logs"), EncodableValue(Utf8FromUtf16(recorder.directory().c_str()))},
          {EncodableValue("enabled"), EncodableValue(recorder.enabled())},
          {EncodableValue("session"), EncodableValue(recorder.session())},
          {EncodableValue("pid"), EncodableValue(static_cast<int64_t>(GetCurrentProcessId()))},
        }));
      } else if (call.method_name() == "diagnosticEnabled") {
        const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
        const bool* enabled = nullptr;
        if (args) {
          const auto item = args->find(EncodableValue("enabled"));
          if (item != args->end()) enabled = std::get_if<bool>(&item->second);
        }
        if (!enabled || !recorder.SetEnabled(*enabled)) {
          result->Error("diagnostics_preference", "Unable to save recording preference");
          return;
        }
        result->Success();
      } else if (call.method_name() == "diagnosticClear") {
        if (recorder.Clear()) result->Success();
        else result->Error("diagnostics_clear", "Unable to clear all Windows diagnostic files");
      } else if (call.method_name() == "diagnosticSnapshot") {
        const auto snapshot = recorder.Snapshot();
        EncodableList reports, traces, exits;
        for (const auto& content : snapshot.reports) {
          reports.emplace_back(EncodableMap{{EncodableValue("content"), EncodableValue(content)}});
        }
        for (const auto& content : snapshot.traces) {
          traces.emplace_back(EncodableMap{{EncodableValue("content"), EncodableValue(content)}});
        }
        for (const auto& entry : snapshot.exits) {
          exits.emplace_back(EncodableMap{
            {EncodableValue("time"), EncodableValue(entry.time)},
            {EncodableValue("reason"), EncodableValue("native_crash")},
            {EncodableValue("source"), EncodableValue("windows_application_error")},
            {EncodableValue("recordId"), EncodableValue(static_cast<int64_t>(entry.record_id))},
            {EncodableValue("version"), EncodableValue(entry.version)},
            {EncodableValue("faultModule"), EncodableValue(entry.module)},
            {EncodableValue("moduleVersion"), EncodableValue(entry.module_version)},
            {EncodableValue("exceptionCode"), EncodableValue(entry.code)},
            {EncodableValue("faultOffset"), EncodableValue(entry.offset)},
            {EncodableValue("pid"), EncodableValue(entry.process_id)},
          });
        }
        result->Success(EncodableValue(EncodableMap{
          {EncodableValue("system"), EncodableValue("windows")},
          {EncodableValue("nativeSession"), EncodableValue(recorder.session())},
          {EncodableValue("reports"), EncodableValue(std::move(reports))},
          {EncodableValue("traces"), EncodableValue(std::move(traces))},
          {EncodableValue("exits"), EncodableValue(std::move(exits))},
          {EncodableValue("exitHistoryUnavailable"), EncodableValue(snapshot.event_log_error != ERROR_SUCCESS)},
          {EncodableValue("eventLogError"), EncodableValue(static_cast<int64_t>(snapshot.event_log_error))},
        }));
      } else {
        result->NotImplemented();
      }
    } catch (...) {
      result->Error("diagnostics_failed", "Windows diagnostic operation failed");
    }
  });
}

DiagnosticBridge::~DiagnosticBridge() { channel_->SetMethodCallHandler(nullptr); }
