#include "../external_download_request.h"
#include <iostream>

int main() {
  const std::string signed_url = "https://example.test/app.apk?token=a%2Bb&x=2";
  if (DownloadLaunchArgument({"--download", signed_url}) != signed_url ||
      DownloadLaunchArgument({signed_url}) != signed_url ||
      DownloadLaunchArgument({"wenxi://download?url=https%3A%2F%2Fexample.test"}).empty() ||
      DownloadLaunchArgument({"wenxi://resolve?url=https%3A%2F%2Fpan.quark.cn%2Fs%2Fabc&pwd=1234"}).empty() ||
      DownloadLaunchArgument({"--open", "wenxi://resolve/?url=https%3A%2F%2Fpan.baidu.com%2Fs%2F1abc"}).empty()) {
    std::cerr << "valid download invocation was lost\n";
    return 1;
  }
  if (!DownloadLaunchArgument({"--download", signed_url, "extra"}).empty() ||
      !DownloadLaunchArgument({"--delete", signed_url}).empty() ||
      IsDownloadLaunch("file:///C:/private") ||
      IsDownloadLaunch("wenxi://delete?url=x") ||
      IsDownloadLaunch("https://example.test/\nwrong") ||
      IsDownloadLaunch(std::string("https://x/") + std::string(16384, 'a')) ||
      IsDownloadLaunch(std::string("https://x/\0wrong", 16))) {
    std::cerr << "invalid invocation was accepted\n";
    return 1;
  }
  return 0;
}
