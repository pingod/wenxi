#include <nlohmann/json.hpp>
#include <wil/wrl.h>

#include "../utils/log.h"
#include "../utils/string.h"
#include "../utils/vector.h"
#include "../utils/webview_json.h"
#include "in_app_webview.h"
#include "user_content_controller.h"

namespace flutter_inappwebview_plugin
{
  using namespace Microsoft::WRL;

  UserContentController::UserContentController(InAppWebView* webView)
    : webView_(webView)
  {}

  void UserContentController::registerEventHandlers()
  {
    if (!webView_ || !(webView_->webView)) {
      return;
    }

    if (executionContextReceiver_) {
      executionContextReceiver_->remove_DevToolsProtocolEventReceived(executionContextToken_);
      executionContextReceiver_ = nullptr;
    }
    const auto lifetime = std::weak_ptr<int>(lifetime_);
    if (succeededOrLog(webView_->webView->GetDevToolsProtocolEventReceiver(L"Runtime.executionContextCreated", &executionContextReceiver_))) {
      auto hr = executionContextReceiver_->add_DevToolsProtocolEventReceived(
        Callback<ICoreWebView2DevToolsProtocolEventReceivedEventHandler>(
          [this, lifetime](
            ICoreWebView2* sender,
            ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args) -> HRESULT
          {
            if (lifetime.expired() || !webView_ || !args) {
              return S_OK;
            }
            wil::unique_cotaskmem_string json;
            if (succeededOrLog(args->get_ParameterObjectAsJson(&json)) && json) {
              const auto context = readWebViewExecutionContext(parseWebViewJson(wide_to_utf8(json.get())));
              if (context && string_equals(webView_->pageFrameId(), context->frameId)) {
                if (context->isDefault) {
                  contentWorlds_.insert_or_assign(ContentWorld::page()->name, context->id);
                }
                else {
                  contentWorlds_.insert_or_assign(context->name, context->id);
                  addPluginScriptsIfRequired(std::make_shared<ContentWorld>(context->name));
                }
              }
            }

            return S_OK;
          })
        .Get(), &executionContextToken_);

      failedLog(hr);
    }

    /*
    wil::com_ptr<ICoreWebView2DevToolsProtocolEventReceiver> executionContextDestroyed;
    if (succeededOrLog(webView_->webView->GetDevToolsProtocolEventReceiver(L"Runtime.executionContextDestroyed ", &executionContextDestroyed))) {
      failedLog(executionContextDestroyed->add_DevToolsProtocolEventReceived(
        Callback<ICoreWebView2DevToolsProtocolEventReceivedEventHandler>(
          [this](
            ICoreWebView2* sender,
            ICoreWebView2DevToolsProtocolEventReceivedEventArgs* args) -> HRESULT
          {
            wil::unique_cotaskmem_string json;
            if (succeededOrLog(args->get_ParameterObjectAsJson(&json))) {
              debugLog("executionContextDestroyed: " + wide_to_utf8(json.get()));
            }

            return S_OK;
          })
        .Get(), nullptr));
    }
    */
  }

  std::vector<std::shared_ptr<UserScript>> UserContentController::getUserOnlyScriptsAt(const UserScriptInjectionTime& injectionTime) const
  {
    return userOnlyScripts_.at(injectionTime);
  }

  void UserContentController::addUserOnlyScript(std::shared_ptr<UserScript> userScript)
  {
    if (!userScript) {
      return;
    }

    addPluginScriptsIfRequired(userScript->contentWorld);
    addScriptToWebView(userScript, nullptr);
    userOnlyScripts_.at(userScript->injectionTime).push_back(std::move(userScript));
  }

  void UserContentController::addUserOnlyScripts(std::vector<std::shared_ptr<UserScript>> userScripts)
  {
    for (auto& userScript : userScripts) {
      addUserOnlyScript(std::move(userScript));
    }
  }

  void UserContentController::removeUserOnlyScript(std::shared_ptr<UserScript> userScript)
  {
    if (!userScript) {
      return;
    }

    if (webView_) {
      removeScriptFromWebView(userScript, nullptr);
    }

    vector_remove_erase(userOnlyScripts_.at(userScript->injectionTime), std::move(userScript));
  }

  void UserContentController::removeUserOnlyScriptAt(const int64_t& index, const UserScriptInjectionTime& injectionTime)
  {
    auto& vec = userOnlyScripts_.at(injectionTime);
    int64_t size = vec.size();
    if (index >= size) {
      return;
    }

    auto& userScript = vec.at(index);
    if (userScript) {
      removeScriptFromWebView(userScript, nullptr);
      vec.erase(vec.begin() + index);
    }
  }

  void UserContentController::removeAllUserOnlyScripts()
  {
    auto& userScriptsAtStart = userOnlyScripts_.at(UserScriptInjectionTime::atDocumentStart);
    auto& userScriptsAtEnd = userOnlyScripts_.at(UserScriptInjectionTime::atDocumentEnd);

    if (webView_) {
      for (auto& userScript : userScriptsAtStart) {
        removeScriptFromWebView(userScript, nullptr);
      }
      for (auto& userScript : userScriptsAtEnd) {
        removeScriptFromWebView(userScript, nullptr);
      }
    }

    userScriptsAtStart.clear();
    userScriptsAtEnd.clear();
  }

  void UserContentController::removeUserOnlyScriptsByGroupName(const std::string& groupName)
  {
    std::vector<std::shared_ptr<UserScript>> userScriptsAtStart = userOnlyScripts_.at(UserScriptInjectionTime::atDocumentStart);
    std::vector<std::shared_ptr<UserScript>> userScriptsAtEnd = userOnlyScripts_.at(UserScriptInjectionTime::atDocumentEnd);

    for (auto& userScript : userScriptsAtStart) {
      if (string_equals(groupName, userScript->groupName)) {
        removeUserOnlyScript(userScript);
      }
    }

    for (auto& userScript : userScriptsAtEnd) {
      if (string_equals(groupName, userScript->groupName)) {
        removeUserOnlyScript(userScript);
      }
    }
  }

  std::vector<std::shared_ptr<PluginScript>> UserContentController::getPluginScriptsAt(const UserScriptInjectionTime& injectionTime) const
  {
    return pluginScripts_.at(injectionTime);
  }

  bool UserContentController::containsUserOnlyScript(std::shared_ptr<UserScript> userScript) const
  {
    if (!userScript) {
      return false;
    }

    return vector_contains(userOnlyScripts_.at(userScript->injectionTime), std::move(userScript));
  }

  bool UserContentController::containsUserOnlyScriptByGroupName(const std::string& groupName) const
  {
    return vector_contains_if(userOnlyScripts_.at(UserScriptInjectionTime::atDocumentStart), [groupName](const std::shared_ptr<UserScript> userScript) { return string_equals(groupName, userScript->groupName); }) ||
      vector_contains_if(userOnlyScripts_.at(UserScriptInjectionTime::atDocumentEnd), [groupName](const std::shared_ptr<UserScript> userScript) { return string_equals(groupName, userScript->groupName); });
  }

  void UserContentController::addPluginScript(std::shared_ptr<PluginScript> pluginScript)
  {
    if (!pluginScript) {
      return;
    }

    addScriptToWebView(pluginScript, nullptr);
    pluginScripts_.at(pluginScript->injectionTime).push_back(std::move(pluginScript));
  }

  void UserContentController::addPluginScripts(std::vector<std::shared_ptr<PluginScript>> pluginScripts)
  {
    for (auto& pluginScript : pluginScripts) {
      addPluginScript(std::move(pluginScript));
    }
  }

  void UserContentController::removePluginScript(std::shared_ptr<PluginScript> pluginScript)
  {
    if (!pluginScript) {
      return;
    }

    if (webView_) {
      removeScriptFromWebView(pluginScript, nullptr);
    }

    vector_remove_erase(pluginScripts_.at(pluginScript->injectionTime), std::move(pluginScript));
  }

  void UserContentController::removeAllPluginScripts()
  {
    auto& pluginScriptsAtStart = pluginScripts_.at(UserScriptInjectionTime::atDocumentStart);
    auto& pluginScriptsAtEnd = pluginScripts_.at(UserScriptInjectionTime::atDocumentEnd);

    if (webView_) {
      for (auto& pluginScript : pluginScriptsAtStart) {
        removeScriptFromWebView(pluginScript, nullptr);
      }
      for (auto& pluginScript : pluginScriptsAtEnd) {
        removeScriptFromWebView(pluginScript, nullptr);
      }
    }

    pluginScriptsAtStart.clear();
    pluginScriptsAtEnd.clear();
  }

  bool UserContentController::containsPluginScript(std::shared_ptr<PluginScript> pluginScript) const
  {
    if (!pluginScript) {
      return false;
    }

    auto injectionTime = pluginScript->injectionTime;
    return vector_contains(pluginScripts_.at(injectionTime), std::move(pluginScript));
  }


  bool UserContentController::containsPluginScript(std::shared_ptr<PluginScript> pluginScript, const std::shared_ptr<ContentWorld> contentWorld) const
  {
    if (!pluginScript || !map_contains(pluginScriptsInContentWorlds_, contentWorld->name)) {
      return false;
    }

    return vector_contains(pluginScriptsInContentWorlds_.at(contentWorld->name), std::move(pluginScript));
  }

  bool UserContentController::containsPluginScriptByGroupName(const std::string& groupName) const
  {
    return vector_contains_if(pluginScripts_.at(UserScriptInjectionTime::atDocumentStart), [groupName](const std::shared_ptr<PluginScript> pluginScript) { return string_equals(groupName, pluginScript->groupName); }) ||
      vector_contains_if(pluginScripts_.at(UserScriptInjectionTime::atDocumentEnd), [groupName](const std::shared_ptr<PluginScript> pluginScript) { return string_equals(groupName, pluginScript->groupName); });
  }

  void UserContentController::removePluginScriptsByGroupName(const std::string& groupName)
  {
    std::vector<std::shared_ptr<PluginScript>> pluginScriptsAtStart = pluginScripts_.at(UserScriptInjectionTime::atDocumentStart);
    std::vector<std::shared_ptr<PluginScript>> pluginScriptsAtEnd = pluginScripts_.at(UserScriptInjectionTime::atDocumentEnd);

    for (auto& pluginScript : pluginScriptsAtStart) {
      if (string_equals(groupName, pluginScript->groupName)) {
        removePluginScript(pluginScript);
      }
    }

    for (auto& pluginScript : pluginScriptsAtEnd) {
      if (string_equals(groupName, pluginScript->groupName)) {
        removePluginScript(pluginScript);
      }
    }
  }


  std::vector<std::shared_ptr<PluginScript>> UserContentController::getPluginScriptsRequiredInAllContentWorlds() const
  {
    std::vector<std::shared_ptr<PluginScript>> res;

    std::vector<std::shared_ptr<PluginScript>> pluginScriptsAtStart = pluginScripts_.at(UserScriptInjectionTime::atDocumentStart);
    std::vector<std::shared_ptr<PluginScript>> pluginScriptsAtEnd = pluginScripts_.at(UserScriptInjectionTime::atDocumentEnd);

    for (auto& pluginScript : pluginScriptsAtStart) {
      if (!pluginScript->contentWorld && pluginScript->isRequiredInAllContentWorlds()) {
        res.push_back(pluginScript);
      }
    }

    for (auto& pluginScript : pluginScriptsAtEnd) {
      if (!pluginScript->contentWorld && pluginScript->isRequiredInAllContentWorlds()) {
        res.push_back(pluginScript);
      }
    }

    return res;
  }

  void UserContentController::createContentWorld(const std::shared_ptr<ContentWorld> contentWorld, const std::function<void(int)> completionHandler)
  {
    if (!webView_ || !(webView_->webView) || ContentWorld::isPage(contentWorld)) {
      if (completionHandler) {
        completionHandler(-1);
      }
      return;
    }

    auto& worldName = contentWorld->name;
    if (!map_contains(contentWorlds_, worldName)) {
      nlohmann::json parameters = {
        {"frameId", webView_->pageFrameId()},
        {"worldName", worldName}
      };
      auto hr = webView_->webView->CallDevToolsProtocolMethod(L"Page.createIsolatedWorld", utf8_to_wide(parameters.dump()).c_str(), Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
        [this, lifetime = std::weak_ptr<int>(lifetime_), completionHandler, worldName](HRESULT errorCode, LPCWSTR returnObjectAsJson)
        {
          int id = -1;
          if (!lifetime.expired() && succeededOrLog(errorCode) && returnObjectAsJson) {
            const auto data = parseWebViewJson(wide_to_utf8(returnObjectAsJson));
            if (data.is_object() && data.contains("executionContextId") &&
              data["executionContextId"].is_number_integer() && data["executionContextId"] >= 0 &&
              data["executionContextId"] <= (std::numeric_limits<int>::max)()) {
              id = data["executionContextId"].get<int>();
              addPluginScriptsIfRequired(std::make_shared<ContentWorld>(worldName));
            }
          }
          if (completionHandler) {
            completionHandler(id);
          }
          return S_OK;
        }
      ).Get());
      if (failedAndLog(hr) && completionHandler) {
        completionHandler(-1);
      }
    }
    else if (completionHandler) {
      completionHandler(contentWorlds_.at(worldName));
    }
  }

  void UserContentController::addScriptToWebView(std::shared_ptr<UserScript> userScript, const std::function<void(std::string)> completionHandler) const
  {
    if (!webView_ || !(webView_->webView)) {
      if (completionHandler) {
        completionHandler(userScript->id);
      }
      return;
    }

    std::string source = userScript->source;
    if (userScript->injectionTime == UserScriptInjectionTime::atDocumentEnd) {
      source = replace_all_copy(USER_SCRIPTS_AT_DOCUMENT_END_WRAPPER_JS_SOURCE, VAR_PLACEHOLDER_VALUE, source);
      std::ostringstream address;
      address << std::addressof(userScript);
      replace_all(source, VAR_PLACEHOLDER_MEMORY_ADDRESS_VALUE, address.str());
    }

    nlohmann::json parameters = {
      {"source", source}
    };

    if (userScript->contentWorld && !ContentWorld::isPage(userScript->contentWorld)) {
      parameters["worldName"] = userScript->contentWorld->name;
    }

    auto hr = webView_->webView->CallDevToolsProtocolMethod(L"Page.addScriptToEvaluateOnNewDocument", utf8_to_wide(parameters.dump()).c_str(), Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
      [userScript, completionHandler](HRESULT errorCode, LPCWSTR returnObjectAsJson)
      {
        if (succeededOrLog(errorCode) && returnObjectAsJson) {
          const auto json = parseWebViewJson(wide_to_utf8(returnObjectAsJson));
          if (json.is_object() && json.contains("identifier") && json["identifier"].is_string()) {
            userScript->id = json["identifier"].get<std::string>();
          }
        }
        if (completionHandler) {
          completionHandler(userScript->id);
        }
        return S_OK;
      }
    ).Get());

    if (failedAndLog(hr) && completionHandler) {
      completionHandler(userScript->id);
    }
  }

  void UserContentController::removeScriptFromWebView(std::shared_ptr<UserScript> userScript, const std::function<void()> completionHandler) const
  {
    if (!webView_ || !(webView_->webView)) {
      if (completionHandler) {
        completionHandler();
      }
      return;
    }

    nlohmann::json parameters = {
      {"identifier", userScript->id}
    };

    auto hr = webView_->webView->CallDevToolsProtocolMethod(L"Page.removeScriptToEvaluateOnNewDocument", utf8_to_wide(parameters.dump()).c_str(), Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
      [userScript, completionHandler](HRESULT errorCode, LPCWSTR returnObjectAsJson)
      {
        failedLog(errorCode);
        if (completionHandler) {
          completionHandler();
        }
        return S_OK;
      }
    ).Get());

    if (failedAndLog(hr) && completionHandler) {
      completionHandler();
    }
  }

  void UserContentController::addPluginScriptsIfRequired(const std::shared_ptr<ContentWorld> contentWorld)
  {
    if (contentWorld && !ContentWorld::isPage(contentWorld)) {
      std::vector<std::shared_ptr<PluginScript>> pluginScriptsRequiredInAllContentWorlds = getPluginScriptsRequiredInAllContentWorlds();
      for (auto& pluginScript : pluginScriptsRequiredInAllContentWorlds) {
        if (!containsPluginScript(pluginScript, contentWorld)) {
          if (!map_contains(pluginScriptsInContentWorlds_, contentWorld->name)) {
            pluginScriptsInContentWorlds_.insert({ contentWorld->name, {} });
          }
          pluginScriptsInContentWorlds_.at(contentWorld->name).push_back(pluginScript);
          addPluginScript(pluginScript->copyAndSet(contentWorld));
        }
      }
    }
  }

  UserContentController::~UserContentController()
  {
    debugLog("dealloc UserContentController");
    lifetime_.reset();
    if (executionContextReceiver_) {
      executionContextReceiver_->remove_DevToolsProtocolEventReceived(executionContextToken_);
      executionContextReceiver_ = nullptr;
    }
    removeAllUserOnlyScripts();
    removeAllPluginScripts();
    contentWorlds_.clear();
    pluginScriptsInContentWorlds_.clear();
    webView_ = nullptr;
  }
}
