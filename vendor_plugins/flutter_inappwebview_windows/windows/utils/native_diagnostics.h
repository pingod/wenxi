#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_NATIVE_DIAGNOSTICS_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_NATIVE_DIAGNOSTICS_H_

#include <windows.h>
#include <atomic>
#include <cstdint>

namespace flutter_inappwebview_plugin {
inline void nativeDiagnostic(const char* event, int64_t a = 0, int64_t b = 0, int64_t c = 0) noexcept {
  using Record = void(__cdecl*)(const char*, int64_t, int64_t, int64_t) noexcept;
  // Optional host facility: the vendored plugin still works with other runners.
  static const auto record = reinterpret_cast<Record>(GetProcAddress(
      GetModuleHandleW(nullptr), "AsterLinkRecordNativeDiagnostic"));
  if (record) record(event, a, b, c);
}
inline int64_t nextNativeDiagnosticId() noexcept {
  static std::atomic<int64_t> sequence{0};
  return ++sequence;
}
inline uint32_t nativeDiagnosticSource(const char* path) noexcept {
  if (!path || !*path) return 0;
  const char* basename = path;
  for (const char* ch = path; *ch; ++ch) {
    if (*ch == '\\' || *ch == '/') basename = ch + 1;
  }
  uint32_t hash = 2166136261u;
  for (const char* ch = basename; *ch; ++ch) hash = (hash ^ static_cast<uint8_t>(*ch)) * 16777619u;
  return hash;
}
}  // namespace flutter_inappwebview_plugin

#endif
