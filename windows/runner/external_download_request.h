#ifndef RUNNER_EXTERNAL_DOWNLOAD_REQUEST_H_
#define RUNNER_EXTERNAL_DOWNLOAD_REQUEST_H_

#include <string>
#include <vector>

constexpr unsigned long long kExternalDownloadMessage = 0x574E5844;
constexpr size_t kExternalDownloadMaxBytes = 16384;

inline bool IsDownloadLaunch(const std::string& value) {
  if (value.empty() || value.size() > kExternalDownloadMaxBytes) return false;
  for (const unsigned char ch : value) {
    if (ch <= 0x20 || ch == 0x7f) return false;
  }
  return value.rfind("https://", 0) == 0 || value.rfind("http://", 0) == 0 ||
         value.rfind("wenxi://download?", 0) == 0 ||
         value.rfind("wenxi://download/?", 0) == 0 ||
         value.rfind("wenxi://resolve?", 0) == 0 ||
         value.rfind("wenxi://resolve/?", 0) == 0;
}

inline std::string DownloadLaunchArgument(const std::vector<std::string>& args) {
  if (args.size() == 1 && IsDownloadLaunch(args[0])) return args[0];
  if (args.size() == 2 && (args[0] == "--download" || args[0] == "--open") &&
      IsDownloadLaunch(args[1])) {
    return args[1];
  }
  return {};
}

#endif
