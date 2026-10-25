#include <windows.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <thread>
#include <nlohmann/json.hpp>
#include "../../windows/runner/native_diagnostics.h"

namespace fs = std::filesystem;
using nlohmann::json;
int checks = 0;
LPTOP_LEVEL_EXCEPTION_FILTER earlier_filter = nullptr;
LONG WINAPI chainedFilter(EXCEPTION_POINTERS* info) {
  return earlier_filter ? earlier_filter(info) : EXCEPTION_CONTINUE_SEARCH;
}
void check(bool value, const char* message) {
  ++checks;
  if (!value) { std::cerr << message << std::endl; std::exit(1); }
}
DWORD child(const fs::path& directory, const wchar_t* mode) {
  wchar_t executable[32768]{};
  GetModuleFileNameW(nullptr, executable, 32768);
  std::wstring command = L"\"" + std::wstring(executable) + L"\" --child \"" + directory.wstring() + L"\" " + mode;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  check(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process), "Could not start isolated diagnostic child");
  check(WaitForSingleObject(process.hProcess, 15000) == WAIT_OBJECT_0, "Diagnostic child timed out");
  DWORD code = 0;
  GetExitCodeProcess(process.hProcess, &code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return code;
}
std::vector<fs::path> files(const fs::path& root, const char* extension) {
  std::vector<fs::path> result;
  for (const auto& entry : fs::directory_iterator(root / "native")) {
    if (entry.path().extension() == extension) result.push_back(entry.path());
  }
  return result;
}
std::string read(const fs::path& path) {
  std::ifstream file(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
int wmain(int argc, wchar_t** argv) {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  auto& recorder = NativeDiagnostics::Instance();
  if (argc == 4) {
    check(recorder.Initialize(argv[2]), "Native diagnostics failed to initialize");
    if (std::wstring(argv[3]) == L"event_snapshot") {
      const auto snapshot = recorder.Snapshot();
      json exits = json::array();
      for (const auto& event : snapshot.exits) {
        exits.push_back({{"time", event.time}, {"module", event.module}, {"code", event.code},
                        {"offset", event.offset}, {"version", event.version}});
      }
      std::cout << json{{"eventLogError", snapshot.event_log_error}, {"exits", exits}}.dump(2) << std::endl;
      recorder.Shutdown();
      return snapshot.event_log_error == ERROR_SUCCESS ? 0 : 1;
    }
    if (std::wstring(argv[3]) == L"chain") {
      earlier_filter = SetUnhandledExceptionFilter(chainedFilter);
      recorder.InstallExceptionHandler();
    }
    if (std::wstring(argv[3]) == L"disable") {
      check(recorder.SetEnabled(false), "Cannot persist opt-out");
    } else if (std::wstring(argv[3]) == L"clear") {
      check(recorder.Clear(), "Cannot clear native diagnostics");
      check(recorder.Snapshot().exits.empty(), "Clear reimported old system crashes");
      recorder.Shutdown();
      return 0;
    } else if (std::wstring(argv[3]) == L"rotate") {
      std::vector<std::thread> writers;
      for (int t = 0; t < 4; ++t) {
        writers.emplace_back([&recorder, t] {
          for (int i = 0; i < 4000; ++i) recorder.Record("fixture.parallel", t, i, 0);
        });
      }
      for (auto& writer : writers) writer.join();
      recorder.Record("https://private.invalid/?cookie=private", 0, 0, 0);
      const auto snapshot = recorder.Snapshot();
      check(snapshot.event_log_error == ERROR_SUCCESS, "Windows Event Log query failed");
      check(snapshot.traces.size() <= 8, "Snapshot did not bound trace count");
      recorder.Shutdown();
      return 0;
    }
    recorder.Record("webview.cookie_read_started", 1, 2, 0);
    // Exercise the actual OS unhandled-exception path in a separate process.
    RaiseException(0xE00000AA, EXCEPTION_NONCONTINUABLE, 0, nullptr);
    return 2;
  }
  wchar_t temporary[MAX_PATH]{};
  GetTempPathW(MAX_PATH, temporary);
  const auto root = fs::path(temporary) / (L"asterlink-native-diagnostic-test-" +
      std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
  fs::create_directories(root);
  check(child(root, L"crash") == 0xE00000AA, "Handler changed the original crash behavior");
  auto reports = files(root, ".json");
  check(reports.size() == 1, "Crash did not persist exactly one report");
  const auto crash = json::parse(read(reports.front()));
  check(crash.at("exceptionCode") == "0xe00000aa", "Persisted exception code is wrong");
  check(!crash.at("faultModule").get<std::string>().empty(), "Fault module is missing");
  check(!crash.at("frames").empty(), "Fault stack locations were not saved");
  check(crash.at("frames").size() <= 24, "Fault stack is unbounded");
  check(read(reports.front()).find("\\\\") == std::string::npos, "Crash report contains a full path");
  check(read(files(root, ".jsonl").front()).find("webview.cookie_read_started") != std::string::npos,
      "Last browser operation was lost on hard crash");
  const auto chained = root / "chained";
  check(child(chained, L"chain") == 0xE00000AA, "Exception filter chain recursed or swallowed the crash");
  check(files(chained, ".json").size() == 1, "Reinstalled exception filter lost the crash report");
  const auto opted_out = root / "opted-out";
  fs::create_directories(opted_out);
  check(child(opted_out, L"disable") == 0xE00000AA, "Opt-out changed crash behavior");
  check(files(opted_out, ".json").size() == 1 &&
      fs::file_size(files(opted_out, ".json").front()) == 0, "Opt-out still wrote a crash report");
  const auto trace_count = files(opted_out, ".jsonl").size();
  check(child(opted_out, L"crash") == 0xE00000AA, "Restarted opt-out child failed");
  check(files(opted_out, ".jsonl").size() == trace_count, "Restart ignored persisted opt-out");
  const auto rotated = root / "rotated";
  fs::create_directories(rotated);
  check(child(rotated, L"rotate") == 0, "Parallel recording or system event collection failed");
  const auto traces = files(rotated, ".jsonl");
  check(traces.size() <= 8 && traces.size() > 1, "Native log rotation failed");
  for (const auto& trace : traces) {
    check(fs::file_size(trace) <= 256 * 1024, "Native trace exceeded its byte cap");
    const auto text = read(trace);
    check(text.find("private") == std::string::npos, "Native ABI accepted a sensitive event identifier");
    std::istringstream lines(text);
    for (std::string line; std::getline(lines, line);) {
      check(json::parse(line).is_object(), "Concurrent records interleaved");
    }
  }
  // Keep unrelated files, prune expired owned files, and persist the clear cutoff.
  std::ofstream(rotated / "native" / "keep.txt") << "unrelated";
  check(child(rotated, L"clear") == 0, "Native clear failed");
  check(files(rotated, ".json").empty(), "Clear left crash reports");
  check(fs::exists(rotated / "native" / "keep.txt"), "Clear removed unrelated files");
  check(fs::exists(rotated / "native-history-after"), "System history cutoff was not saved");
  check(child(root, L"clear") == 0 && files(root, ".json").empty(), "Saved hard crash could not be cleared");
  // The test owns this freshly generated absolute directory and all children.
  fs::remove_all(root);
  std::cout << checks << " native diagnostic checks passed" << std::endl;
}
