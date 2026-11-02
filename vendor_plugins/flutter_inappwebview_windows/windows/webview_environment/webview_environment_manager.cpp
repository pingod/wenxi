#include <DispatcherQueue.h>
#include <cstdint>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "../in_app_webview/in_app_webview_settings.h"
#include "../utils/flutter.h"
#include "../utils/log.h"
#include "../utils/string.h"
#include "../utils/vector.h"
#include "webview_environment_manager.h"

namespace flutter_inappwebview_plugin
{
  WebViewEnvironmentManager::WebViewEnvironmentManager(const FlutterInappwebviewWindowsPlugin* plugin)
    : plugin(plugin),
    ChannelDelegate(plugin->registrar->messenger(), WebViewEnvironmentManager::METHOD_CHANNEL_NAME)
  {
    windowClass_.lpszClassName = WebViewEnvironmentManager::CLASS_NAME;
    windowClass_.lpfnWndProc = &DefWindowProc;

    RegisterClass(&windowClass_);

    hwnd_ = CreateWindowEx(0, windowClass_.lpszClassName, L"", 0, 0,
      0, 0, 0,
      plugin->registrar->GetView()->GetNativeWindow(),
      nullptr,
      windowClass_.hInstance, nullptr);
  }

  void WebViewEnvironmentManager::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    auto& methodName = method_call.method_name();

    if (string_equals(methodName, "create")) {
      auto id = get_fl_map_value<std::string>(*arguments, "id");
      auto settingsMap = get_optional_fl_map_value<flutter::EncodableMap>(*arguments, "settings");
      auto settings = settingsMap.has_value() ? std::make_unique<WebViewEnvironmentSettings>(settingsMap.value()) : nullptr;
      createWebViewEnvironment(id, std::move(settings), std::move(result));
    }
    else if (string_equals(methodName, "getAvailableVersion")) {
      auto browserExecutableFolder = get_optional_fl_map_value<std::string>(*arguments, "browserExecutableFolder");
      result->Success(make_fl_value(getAvailableVersion(browserExecutableFolder)));
    }
    else if (string_equals(methodName, "compareBrowserVersions")) {
      auto version1 = get_fl_map_value<std::string>(*arguments, "version1");
      auto version2 = get_fl_map_value<std::string>(*arguments, "version2");
      result->Success(make_fl_value(compareBrowserVersions(version1, version2)));
    }
    else {
      result->NotImplemented();
    }
  }

  void WebViewEnvironmentManager::createWebViewEnvironment(const std::string& id, std::unique_ptr<WebViewEnvironmentSettings> settings, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    auto result_ = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));

    if (map_contains(webViewEnvironments, id)) {
      result_->Error("webview_environment_exists", "WebViewEnvironment already exists");
      return;
    }
    auto webViewEnvironment = std::make_unique<WebViewEnvironment>(plugin, id);
    auto* pendingEnvironment = webViewEnvironment.get();
    // Creation can fail synchronously. Register first so its failure callback
    // can remove the failed environment instead of leaving it in the map.
    webViewEnvironments.insert({ id, std::move(webViewEnvironment) });
    pendingEnvironment->create(std::move(settings),
      [this, id, result_](HRESULT errorCode)
      {
        if (succeededOrLog(errorCode)) {
          result_->Success(true);
        }
        else {
          result_->Error("webview_environment_create", "Cannot create WebViewEnvironment: " + getHRMessage(errorCode),
            flutter::EncodableValue(flutter::EncodableMap{
              { flutter::EncodableValue("hresult"), flutter::EncodableValue(static_cast<int64_t>(static_cast<uint32_t>(errorCode))) }
            }));
          if (map_contains(webViewEnvironments, id)) {
            webViewEnvironments.erase(id);
          }
        }
      });
  }

  void WebViewEnvironmentManager::createOrGetDefaultWebViewEnvironment(const std::function<void(WebViewEnvironment*)> completionHandler)
  {
    if (defaultEnvironment_) {
      if (completionHandler) {
        completionHandler(defaultEnvironment_.get());
      }
      return;
    }

    defaultEnvironment_ = std::make_unique<WebViewEnvironment>(plugin, "-1");
    defaultEnvironment_->create(nullptr, [this, completionHandler](HRESULT errorCode)
      {
        if (succeededOrLog(errorCode)) {
          if (completionHandler) {
            completionHandler(defaultEnvironment_.get());
          }
        }
        else if (completionHandler) {
          defaultEnvironment_ = nullptr;
          completionHandler(nullptr);
        }
      });
  }

  std::optional<std::string> WebViewEnvironmentManager::getAvailableVersion(std::optional<std::string> browserExecutableFolder)
  {
    wil::unique_cotaskmem_string versionInfo;
    if (succeededOrLog(GetAvailableCoreWebView2BrowserVersionString(browserExecutableFolder.has_value() ? utf8_to_wide(browserExecutableFolder.value()).c_str() : nullptr, &versionInfo))) {
      return wide_to_utf8(versionInfo.get());
    }
    return std::nullopt;
  }

  std::optional<int> WebViewEnvironmentManager::compareBrowserVersions(std::string version1, std::string version2)
  {
    int result = 0;
    if (succeededOrLog(CompareBrowserVersions(utf8_to_wide(version1).c_str(), utf8_to_wide(version2).c_str(), &result))) {
      return result;
    }
    return std::nullopt;
  }

  WebViewEnvironmentManager::~WebViewEnvironmentManager()
  {
    debugLog("dealloc WebViewEnvironmentManager");
    webViewEnvironments.clear();
    plugin = nullptr;
    defaultEnvironment_ = nullptr;
    if (hwnd_) {
      DestroyWindow(hwnd_);
    }
  }
}
