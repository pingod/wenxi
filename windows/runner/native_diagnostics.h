#ifndef RUNNER_NATIVE_DIAGNOSTICS_H_
#define RUNNER_NATIVE_DIAGNOSTICS_H_

#include <windows.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

struct WindowsCrashEvent {
  int64_t time = 0;
  uint64_t record_id = 0;
  std::string version, module, module_version, code, offset, process_id;
};

struct NativeDiagnosticSnapshot {
  std::vector<std::string> reports, traces;
  std::vector<WindowsCrashEvent> exits;
  DWORD event_log_error = ERROR_SUCCESS;
};

// Only fixed event identifiers and numeric fields cross the plugin boundary.
// Never pass page text, URLs, cookies, request bodies or script results here.
extern "C" __declspec(dllexport) void __cdecl AsterLinkRecordNativeDiagnostic(
    const char* event, int64_t value1, int64_t value2, int64_t value3) noexcept;

class NativeDiagnostics {
 public:
  static NativeDiagnostics& Instance();
  bool Initialize(const std::wstring& test_directory = {}) noexcept;
  void InstallExceptionHandler() noexcept;
  void Shutdown() noexcept;
  bool SetEnabled(bool enabled) noexcept;
  bool Clear() noexcept;
  bool enabled() const { return enabled_.load(); }
  const std::wstring& directory() const { return directory_; }
  const std::string& session() const { return session_; }
  NativeDiagnosticSnapshot Snapshot();
  void Record(const char* event, int64_t a, int64_t b, int64_t c) noexcept;
  static LONG WINAPI UnhandledException(EXCEPTION_POINTERS* info) noexcept;

 private:
  void OpenTrace();
  void OpenCrash();
  void Prune();
  void CloseFiles();
  std::mutex mutex_;
  std::atomic<bool> enabled_{false};
  std::atomic<long> crashing_{0};
  std::atomic<bool> forwarding_filter_{false};
  std::wstring directory_, trace_path_, crash_path_;
  std::string session_;
  HANDLE trace_ = INVALID_HANDLE_VALUE, crash_ = INVALID_HANDLE_VALUE;
  size_t trace_bytes_ = 0;
  int64_t trace_day_ = 0, history_after_ = 0;
  unsigned part_ = 0;
  bool initialized_ = false;
  std::atomic<LPTOP_LEVEL_EXCEPTION_FILTER> previous_filter_{nullptr};
};

#endif
