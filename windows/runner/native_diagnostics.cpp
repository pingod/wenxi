#include "native_diagnostics.h"

#include <shlobj.h>
#include <winevt.h>
#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <regex>
#include <utility>

#ifndef FLUTTER_VERSION
#define FLUTTER_VERSION "test"
#endif

namespace {
namespace fs = std::filesystem;
constexpr size_t kTraceBytes = 256 * 1024, kCrashBytes = 16 * 1024;
constexpr size_t kFilesPerKind = 8;
constexpr uint64_t kEpoch = 116444736000000000ULL;
constexpr int64_t kRetentionMs = 7LL * 24 * 60 * 60 * 1000;
NativeDiagnostics* recorder = nullptr;
// Preallocated storage: a damaged heap or exhausted thread stack must not be
// needed just to save the exception code and fault location.
char crash_buffer[kCrashBytes];
void* crash_frames[24];

uint64_t FileTimeValue(FILETIME value) {
  return (static_cast<uint64_t>(value.dwHighDateTime) << 32) | value.dwLowDateTime;
}
int64_t Now() {
  FILETIME time{};
  GetSystemTimeAsFileTime(&time);
  return static_cast<int64_t>((FileTimeValue(time) - kEpoch) / 10000);
}
std::wstring Wide(const std::string& ascii) { return {ascii.begin(), ascii.end()}; }
bool RegularPath(const fs::path& path, bool directory = false) {
  const auto attrs = GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_REPARSE_POINT) &&
      bool(attrs & FILE_ATTRIBUTE_DIRECTORY) == directory;
}
bool Owned(const fs::path& path, bool crash) {
  static const std::wregex trace_name(L"native-[0-9]+-[0-9]+-[0-9]+\\.jsonl");
  static const std::wregex crash_name(L"crash-[0-9]+-[0-9]+\\.json");
  return std::regex_match(path.filename().wstring(), crash ? crash_name : trace_name);
}
std::vector<fs::directory_entry> Files(const fs::path& directory, bool crash) {
  std::vector<fs::directory_entry> files;
  if (!RegularPath(directory, true)) return files;
  for (const auto& file : fs::directory_iterator(directory)) {
    if (Owned(file.path(), crash) && RegularPath(file.path())) files.push_back(file);
  }
  std::sort(files.begin(), files.end(), [](const auto& a, const auto& b) {
    return a.last_write_time() > b.last_write_time();
  });
  return files;
}
std::string ReadBounded(const fs::path& path, size_t limit) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  BY_HANDLE_FILE_INFORMATION info{};
  std::string text;
  if (GetFileInformationByHandle(file, &info) &&
      !(info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
      info.nFileSizeHigh == 0 && info.nFileSizeLow <= limit) {
    text.resize(info.nFileSizeLow);
    DWORD read = 0;
    if (!ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &read, nullptr)) read = 0;
    text.resize(read);
  }
  CloseHandle(file);
  return text;
}
bool Write(HANDLE file, const char* text, size_t length) noexcept {
  DWORD written = 0;
  return file != INVALID_HANDLE_VALUE && WriteFile(file, text,
      static_cast<DWORD>(length), &written, nullptr) && written == length;
}
// Module names in diagnostics are basenames, never installation/user paths.
void Location(void* address, char* module, size_t capacity, uint64_t* offset) noexcept {
  module[0] = '\0';
  *offset = 0;
  MEMORY_BASIC_INFORMATION region{};
  if (!VirtualQuery(address, &region, sizeof(region)) || region.Type != MEM_IMAGE) return;
  wchar_t path[1024]{};
  if (!GetModuleFileNameW(static_cast<HMODULE>(region.AllocationBase), path, 1024)) return;
  const wchar_t* leaf = path;
  for (const wchar_t* next = path; *next; ++next) {
    if (*next == L'\\' || *next == L'/') leaf = next + 1;
  }
  size_t i = 0;
  for (; leaf[i] && i + 1 < capacity; ++i) {
    const auto ch = leaf[i];
    module[i] = ch >= 32 && ch < 127 && ch != L'"' && ch != L'\\' ? static_cast<char>(ch) : '_';
  }
  module[i] = '\0';
  *offset = reinterpret_cast<uintptr_t>(address) - reinterpret_cast<uintptr_t>(region.AllocationBase);
}
unsigned FaultFrames(CONTEXT* source, bool stack_overflow) noexcept {
  unsigned count = 0;
#if defined(_M_X64)
  // No C++ objects needing unwinding inside this SEH guard. Bad stack memory
  // truncates the backtrace; it never replaces the original exception.
  __try {
    CONTEXT context = *source;
    while (context.Rip && count < 24) {
      crash_frames[count++] = reinterpret_cast<void*>(context.Rip);
      if (stack_overflow) break;
      DWORD64 image_base = 0;
      auto* entry = RtlLookupFunctionEntry(context.Rip, &image_base, nullptr);
      const auto previous_sp = context.Rsp;
      if (entry) {
        void* handler_data = nullptr;
        DWORD64 establisher = 0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER, image_base, context.Rip, entry,
                        &context, &handler_data, &establisher, nullptr);
      } else {
        context.Rip = *reinterpret_cast<DWORD64*>(context.Rsp);
        context.Rsp += sizeof(DWORD64);
      }
      if (context.Rsp <= previous_sp) break;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {}
#endif
  return count;
}

struct EventHandle {
  EVT_HANDLE value = nullptr;
  ~EventHandle() { if (value) EvtClose(value); }
};
std::string EventString(const EVT_VARIANT& value, bool basename = false) {
  if (value.Type != EvtVarTypeString || !value.StringVal) return {};
  std::wstring text(value.StringVal);
  if (basename) text = fs::path(text).filename().wstring();
  // The fields we read are module names, versions, and hex error identifiers.
  // Constrain their length and characters before they leave the native layer.
  if (text.size() > 160) text.resize(160);
  std::string clean;
  for (const auto ch : text) {
    clean += ch >= 32 && ch < 127 && ch != L'\\' && ch != L'/' ? static_cast<char>(ch) : '_';
  }
  return clean;
}
std::string AppVersion(std::string version) {
  // Windows stores 1.9.0.190; export as the application's 1.9.0+190 format.
  // Besides matching About, this prevents IP redaction from hiding a version.
  if (version.find_first_not_of("0123456789.") == std::string::npos &&
      std::count(version.begin(), version.end(), '.') == 3) {
    version[version.rfind('.')] = '+';
  }
  return version;
}
bool RenderValues(EVT_HANDLE context, EVT_HANDLE event,
                  std::vector<EVT_VARIANT>& storage, DWORD& count) {
  DWORD used = 0;
  EvtRender(context, event, EvtRenderEventValues, 0, nullptr, &used, &count);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || used > 32 * 1024) return false;
  storage.resize((used + sizeof(EVT_VARIANT) - 1) / sizeof(EVT_VARIANT));
  return EvtRender(context, event, EvtRenderEventValues,
      used, storage.data(), &used, &count) != FALSE;
}
void CollectSystemCrashes(NativeDiagnosticSnapshot& snapshot, int64_t after) {
  EventHandle query{EvtQuery(nullptr, L"Application",
      L"*[System[Provider[@Name='Application Error'] and (EventID=1000) and "
      L"TimeCreated[timediff(@SystemTime) <= 604800000]]] and "
      L"*[EventData[(Data[@Name='AppName']='asterlink.exe') or (Data[1]='asterlink.exe')]]",
      EvtQueryChannelPath | EvtQueryReverseDirection)};
  if (!query.value) { snapshot.event_log_error = GetLastError(); return; }
  const wchar_t* paths[] = {
    L"Event/EventData/Data[@Name='AppVersion']", L"Event/EventData/Data[@Name='ModuleName']",
    L"Event/EventData/Data[@Name='ModuleVersion']", L"Event/EventData/Data[@Name='ExceptionCode']",
    L"Event/EventData/Data[@Name='FaultingOffset']", L"Event/EventData/Data[@Name='ProcessId']",
  };
  EventHandle named_context{EvtCreateRenderContext(6, paths, EvtRenderContextValues)};
  // EvtCreateRenderContext's value-path parser rejects positional Data[n]
  // expressions on classic providers even though EvtQuery accepts them. Use
  // the documented typed system/user contexts for those positional fields.
  EventHandle system_context{EvtCreateRenderContext(0, nullptr, EvtRenderContextSystem)};
  EventHandle user_context{EvtCreateRenderContext(0, nullptr, EvtRenderContextUser)};
  if (!system_context.value || !user_context.value) { snapshot.event_log_error = GetLastError(); return; }
  for (size_t index = 0; index < 8; ++index) {
    EventHandle event;
    DWORD returned = 0;
    if (!EvtNext(query.value, 1, &event.value, 0, 0, &returned)) {
      const auto error = GetLastError();
      if (error != ERROR_NO_MORE_ITEMS) snapshot.event_log_error = error;
      break;
    }
    DWORD system_count = 0, user_count = 0, named_count = 0;
    std::vector<EVT_VARIANT> system, user, named;
    if (!RenderValues(system_context.value, event.value, system, system_count) ||
        !RenderValues(user_context.value, event.value, user, user_count) ||
        system_count <= EvtSystemEventRecordId || user_count < 9) {
      snapshot.event_log_error = ERROR_INVALID_DATA;
      continue;
    }
    if (EventString(user[0]) != "asterlink.exe") continue;
    const auto& time = system[EvtSystemTimeCreated];
    if (time.Type != EvtVarTypeFileTime || time.FileTimeVal < kEpoch) {
      snapshot.event_log_error = ERROR_INVALID_DATA;
      continue;
    }
    WindowsCrashEvent crash;
    crash.time = static_cast<int64_t>((time.FileTimeVal - kEpoch) / 10000);
    if (crash.time <= after) continue;
    const auto& record_id = system[EvtSystemEventRecordId];
    if (record_id.Type == EvtVarTypeUInt64) crash.record_id = record_id.UInt64Val;
    const bool has_named = named_context.value &&
        RenderValues(named_context.value, event.value, named, named_count) && named_count == 6;
    auto field = [&](size_t index, size_t classic_index, bool basename = false) {
      auto value = has_named ? EventString(named[index], basename) : std::string{};
      return value.empty() ? EventString(user[classic_index], basename) : value;
    };
    crash.version = AppVersion(field(0, 1));
    crash.module = field(1, 3, true);
    crash.module_version = field(2, 4);
    crash.code = field(3, 6);
    crash.offset = field(4, 7);
    crash.process_id = field(5, 8);
    snapshot.exits.push_back(std::move(crash));
  }
}
}  // namespace

NativeDiagnostics& NativeDiagnostics::Instance() {
  // Stable until process termination, including late DLL/CRT failure callbacks.
  static auto* instance = new NativeDiagnostics();
  return *instance;
}

bool NativeDiagnostics::Initialize(const std::wstring& test_directory) noexcept {
  if (initialized_) return !directory_.empty();
  try {
    fs::path root(test_directory);
    if (root.empty()) {
      PWSTR app_data = nullptr;
      if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &app_data))) return false;
      root = fs::path(app_data) / L"com.asterlink" / L"文析助手" / L"AsterLink" / L"diagnostics";
      CoTaskMemFree(app_data);
    }
    fs::create_directories(root / L"native");
    if (!RegularPath(root, true) || !RegularPath(root / L"native", true)) return false;
    directory_ = root.wstring();
    session_ = std::to_string(Now()) + "-" + std::to_string(GetCurrentProcessId());
    const auto history = ReadBounded(root / L"native-history-after", 32);
    if (!history.empty()) {
      try { history_after_ = std::stoll(history); }
      catch (...) { history_after_ = Now(); }
    }
    enabled_ = GetFileAttributesW((root / L"disabled").c_str()) == INVALID_FILE_ATTRIBUTES &&
        GetLastError() == ERROR_FILE_NOT_FOUND;
    if (enabled_) { OpenCrash(); OpenTrace(); }
    Prune();
    recorder = this;
    ULONG stack_reserve = 64 * 1024;
    SetThreadStackGuarantee(&stack_reserve);
    InstallExceptionHandler();
    initialized_ = true;
    Record("windows.session_started", 0, 0, 0);
    return true;
  } catch (...) { enabled_ = false; CloseFiles(); directory_.clear(); return false; }
}

void NativeDiagnostics::InstallExceptionHandler() noexcept {
  if (recorder != this) return;
  const auto previous = SetUnhandledExceptionFilter(UnhandledException);
  if (previous != UnhandledException) previous_filter_ = previous;
}

void NativeDiagnostics::OpenTrace() {
  if (trace_ != INVALID_HANDLE_VALUE) CloseHandle(trace_);
  trace_path_ = (fs::path(directory_) / L"native" /
      Wide("native-" + session_ + "-" + std::to_string(part_++) + ".jsonl")).wstring();
  trace_ = CreateFileW(trace_path_.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
      nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  trace_bytes_ = 0;
  trace_day_ = Now() / (24 * 60 * 60 * 1000);
}
void NativeDiagnostics::OpenCrash() {
  crash_path_ = (fs::path(directory_) / L"native" / Wide("crash-" + session_ + ".json")).wstring();
  crash_ = CreateFileW(crash_path_.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
      nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
}
void NativeDiagnostics::CloseFiles() {
  if (trace_ != INVALID_HANDLE_VALUE) CloseHandle(std::exchange(trace_, INVALID_HANDLE_VALUE));
  if (crash_ != INVALID_HANDLE_VALUE) CloseHandle(std::exchange(crash_, INVALID_HANDLE_VALUE));
}
void NativeDiagnostics::Prune() {
  for (const bool crash : {false, true}) {
    auto files = Files(fs::path(directory_) / L"native", crash);
    size_t kept = 0;
    for (const auto& file : files) {
      const auto active = file.path() == fs::path(crash ? crash_path_ : trace_path_);
      const auto old = fs::file_time_type::clock::now() - file.last_write_time() >
          std::chrono::milliseconds(kRetentionMs);
      if (active || (!old && kept < kFilesPerKind - 1)) { ++kept; continue; }
      DeleteFileW(file.path().c_str());
    }
  }
}

void NativeDiagnostics::Record(const char* event, int64_t a, int64_t b, int64_t c) noexcept {
  if (!enabled_ || !event || crashing_) return;
  try {
    // Only constant, short ASCII event identifiers are accepted. This is also
    // enforced at the ABI boundary to prevent accidental credential logging.
    size_t length = 0;
    for (; length < 80 && event[length]; ++length) {
      const char ch = event[length];
      if (!((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_')) return;
    }
    if (!length || length == 80) return;
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!enabled_ || crashing_) return;
    char line[512];
    const int size = _snprintf_s(line, sizeof(line), _TRUNCATE,
        "{\"time\":%lld,\"session\":\"%s\",\"version\":\"%s\",\"pid\":%lu,\"thread\":%lu,"
        "\"event\":\"%s\",\"value1\":%lld,\"value2\":%lld,\"value3\":%lld}\n",
        Now(), session_.c_str(), FLUTTER_VERSION, GetCurrentProcessId(), GetCurrentThreadId(), event, a, b, c);
    if (size <= 0) return;
    if (trace_ == INVALID_HANDLE_VALUE || trace_bytes_ + size > kTraceBytes ||
        trace_day_ != Now() / (24 * 60 * 60 * 1000)) { OpenTrace(); Prune(); }
    if (Write(trace_, line, size)) trace_bytes_ += size;
  } catch (...) {}  // Logging cannot become a new failure path.
}

LONG WINAPI NativeDiagnostics::UnhandledException(EXCEPTION_POINTERS* info) noexcept {
  auto* self = recorder;
  if (self && self->enabled_ && info && info->ExceptionRecord &&
      self->crashing_.exchange(1) == 0 && self->crash_ != INVALID_HANDLE_VALUE) {
    char module[160];
    uint64_t offset = 0;
    Location(info->ExceptionRecord->ExceptionAddress, module, sizeof(module), &offset);
    int used = _snprintf_s(crash_buffer, sizeof(crash_buffer), _TRUNCATE,
        "{\"time\":%lld,\"event\":\"windows.unhandled_exception\",\"session\":\"%s\","
        "\"version\":\"%s\",\"pid\":%lu,\"thread\":%lu,\"exceptionCode\":\"0x%08lx\","
        "\"faultModule\":\"%s\",\"faultOffset\":\"0x%llx\",\"frames\":[",
        Now(), self->session_.c_str(), FLUTTER_VERSION, GetCurrentProcessId(), GetCurrentThreadId(),
        info->ExceptionRecord->ExceptionCode, module, offset);
    const unsigned count = info->ContextRecord ? FaultFrames(info->ContextRecord,
        info->ExceptionRecord->ExceptionCode == EXCEPTION_STACK_OVERFLOW) : 0;
    for (unsigned i = 0; i < count && used > 0 && used < static_cast<int>(sizeof(crash_buffer)) - 300; ++i) {
      Location(crash_frames[i], module, sizeof(module), &offset);
      const int size = _snprintf_s(crash_buffer + used, sizeof(crash_buffer) - used, _TRUNCATE,
          "%s{\"module\":\"%s\",\"offset\":\"0x%llx\"}", i ? "," : "", module, offset);
      if (size < 0) break;
      used += size;
    }
    if (used > 0) {
      const int size = _snprintf_s(crash_buffer + used, sizeof(crash_buffer) - used, _TRUNCATE, "]}\n");
      if (size > 0) Write(self->crash_, crash_buffer, used + size);
      FlushFileBuffers(self->crash_);
    }
  }
  // Preserve normal Windows/Flutter crash handling. Never resume a damaged process.
  const auto previous = self ? self->previous_filter_.load() : nullptr;
  if (previous && !self->forwarding_filter_.exchange(true)) {
    const auto result = previous(info);
    self->forwarding_filter_ = false;
    return result;
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

bool NativeDiagnostics::SetEnabled(bool enabled) noexcept {
  try {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (directory_.empty()) return false;
    const auto flag = fs::path(directory_) / L"disabled";
    if (enabled) {
      if (!DeleteFileW(flag.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) return false;
      if (crash_ == INVALID_HANDLE_VALUE) OpenCrash();
      if (trace_ == INVALID_HANDLE_VALUE) OpenTrace();
    } else {
      HANDLE file = CreateFileW(flag.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
          FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr);
      if (file == INVALID_HANDLE_VALUE) return false;
      const bool ok = Write(file, "disabled", 8);
      CloseHandle(file);
      if (!ok) return false;
    }
    enabled_ = enabled;
    return true;
  } catch (...) { return false; }
}

bool NativeDiagnostics::Clear() noexcept {
  if (directory_.empty()) return false;
  const bool was_enabled = enabled_.exchange(false);
  try {
    const std::lock_guard<std::mutex> lock(mutex_);
    CloseFiles();
    bool ok = true;
    for (bool crash : {false, true}) {
      for (const auto& file : Files(fs::path(directory_) / L"native", crash)) {
        if (!DeleteFileW(file.path().c_str())) ok = false;
      }
    }
    // Windows owns its Application log; clearing our logs only advances our
    // local cutoff so an export does not silently reimport the cleared history.
    history_after_ = Now();
    const auto cutoff = std::to_string(history_after_);
    HANDLE file = CreateFileW((fs::path(directory_) / L"native-history-after").c_str(),
        GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr);
    if (!Write(file, cutoff.data(), cutoff.size())) ok = false;
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (was_enabled) { OpenCrash(); OpenTrace(); }
    enabled_ = was_enabled;
    return ok;
  } catch (...) { enabled_ = was_enabled; return false; }
}

NativeDiagnosticSnapshot NativeDiagnostics::Snapshot() {
  NativeDiagnosticSnapshot result;
  if (directory_.empty()) return result;
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    Prune();
    for (bool crash : {true, false}) {
      for (const auto& file : Files(fs::path(directory_) / L"native", crash)) {
        auto& destination = crash ? result.reports : result.traces;
        auto text = ReadBounded(file.path(), crash ? kCrashBytes : kTraceBytes);
        if (!text.empty()) destination.push_back(std::move(text));
        if (destination.size() == kFilesPerKind) break;
      }
    }
  }
  // Fail-fast/driver faults may bypass all in-process handlers. Ask Windows
  // for this application's Event 1000 records when the user requests a report.
  if (enabled_) CollectSystemCrashes(result, history_after_);
  return result;
}
void NativeDiagnostics::Shutdown() noexcept {
  Record("windows.session_finished", 0, 0, 0);
  enabled_ = false;
  const std::lock_guard<std::mutex> lock(mutex_);
  CloseFiles();
  if (!crashing_ && !crash_path_.empty()) DeleteFileW(crash_path_.c_str());
}
extern "C" void __cdecl AsterLinkRecordNativeDiagnostic(
    const char* event, int64_t a, int64_t b, int64_t c) noexcept {
  if (recorder) recorder->Record(event, a, b, c);
}
