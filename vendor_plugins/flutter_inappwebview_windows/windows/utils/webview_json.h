#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_WEBVIEW_JSON_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_WEBVIEW_JSON_H_

#include <limits>
#include <map>
#include <optional>
#include <string>
#include <vector>
#include <nlohmann/json.hpp>

namespace flutter_inappwebview_plugin
{
  // WebView2 callbacks cross a native boundary. Page messages and optional CDP
  // fields must not throw C++ exceptions out of that callback.
  inline nlohmann::json parseWebViewJson(const std::string& source)
  {
    return nlohmann::json::parse(source, nullptr, false);
  }

  inline std::optional<std::string> webViewJsonString(const nlohmann::json& object, const char* key)
  {
    if (!object.is_object()) return std::nullopt;
    const auto value = object.find(key);
    return value != object.end() && value->is_string()
      ? std::make_optional(value->get<std::string>()) : std::nullopt;
  }

  struct WebViewPausedRequest {
    std::string id;
    std::string resourceType;
    std::string frameId;
    bool responseStage;
    std::optional<std::string> url;
    std::optional<std::string> method;
    std::optional<std::string> redirectedRequestId;
    std::optional<std::map<std::string, std::string>> headers;
    std::optional<std::vector<std::string>> postDataEntries;
  };

  inline std::optional<WebViewPausedRequest> readWebViewPausedRequest(const nlohmann::json& event)
  {
    const auto id = webViewJsonString(event, "requestId");
    if (!id || id->empty()) return std::nullopt;
    WebViewPausedRequest result{
      *id,
      webViewJsonString(event, "resourceType").value_or(""),
      webViewJsonString(event, "frameId").value_or(""),
      event.contains("responseStatusCode") || event.contains("responseErrorReason"),
      std::nullopt, std::nullopt, webViewJsonString(event, "redirectedRequestId"),
      std::nullopt, std::nullopt
    };
    if (!event.contains("request") || !event["request"].is_object()) return result;
    const auto& request = event["request"];
    result.url = webViewJsonString(request, "url");
    if (const auto fragment = webViewJsonString(request, "urlFragment"); result.url && fragment) {
      result.url = *result.url + *fragment;
    }
    result.method = webViewJsonString(request, "method");
    if (request.contains("headers") && request["headers"].is_object()) {
      result.headers.emplace();
      for (const auto& header : request["headers"].items()) {
        if (header.value().is_string()) {
          result.headers->emplace(header.key(), header.value().get<std::string>());
        }
        else if (header.value().is_number() || header.value().is_boolean()) {
          result.headers->emplace(header.key(), header.value().dump());
        }
      }
    }
    if (request.contains("hasPostData") && request["hasPostData"] == true &&
      request.contains("postDataEntries") && request["postDataEntries"].is_array()) {
      result.postDataEntries.emplace();
      for (const auto& entry : request["postDataEntries"]) {
        const auto bytes = webViewJsonString(entry, "bytes");
        if (!bytes) {
          // Do not turn an incomplete upload into a different request body.
          result.postDataEntries.reset();
          break;
        }
        result.postDataEntries->push_back(*bytes);
      }
    }
    return result;
  }

  struct WebViewExecutionContext {
    int id;
    std::string name;
    std::string frameId;
    bool isDefault;
  };

  inline std::optional<WebViewExecutionContext> readWebViewExecutionContext(const nlohmann::json& event)
  {
    if (!event.is_object() || !event.contains("context") || !event["context"].is_object()) {
      return std::nullopt;
    }
    const auto& context = event["context"];
    if (!context.contains("id") || !context["id"].is_number_integer() ||
      context["id"] < 0 || context["id"] > (std::numeric_limits<int>::max)() ||
      !context.contains("name") || !context["name"].is_string() ||
      !context.contains("auxData") || !context["auxData"].is_object()) {
      return std::nullopt;
    }
    const auto& aux = context["auxData"];
    if (!aux.contains("isDefault") || !aux["isDefault"].is_boolean() ||
      !aux.contains("frameId") || !aux["frameId"].is_string()) {
      return std::nullopt;
    }
    return WebViewExecutionContext{
      context["id"].get<int>(), context["name"].get<std::string>(),
      aux["frameId"].get<std::string>(), aux["isDefault"].get<bool>()
    };
  }

  struct WebViewScriptMessage {
    std::string handlerName;
    int64_t callHandlerId;
    std::string arguments;
  };

  inline std::optional<WebViewScriptMessage> readWebViewScriptMessage(const nlohmann::json& message)
  {
    if (!message.is_object() || !message.contains("name") || message["name"] != "callHandler" ||
      !message.contains("body") || !message["body"].is_object()) {
      return std::nullopt;
    }
    const auto& body = message["body"];
    if (!body.contains("handlerName") || !body["handlerName"].is_string() ||
      !body.contains("_callHandlerID") || !body["_callHandlerID"].is_number_integer() ||
      body["_callHandlerID"] < 0 || body["_callHandlerID"] > (std::numeric_limits<int64_t>::max)() ||
      !body.contains("args") || !body["args"].is_string()) {
      return std::nullopt;
    }
    const auto arguments = body["args"].get<std::string>();
    if (!parseWebViewJson(arguments).is_array()) {
      return std::nullopt;
    }
    return WebViewScriptMessage{
      body["handlerName"].get<std::string>(), body["_callHandlerID"].get<int64_t>(), arguments
    };
  }

  inline std::optional<std::string> webViewScriptError(const nlohmann::json& response)
  {
    if (!response.is_object() || !response.contains("exceptionDetails") ||
      !response["exceptionDetails"].is_object()) {
      return std::nullopt;
    }
    const auto& details = response["exceptionDetails"];
    if (details.contains("exception") && details["exception"].is_object()) {
      const auto& exception = details["exception"];
      if (exception.contains("description") && exception["description"].is_string()) {
        return exception["description"].get<std::string>();
      }
      if (exception.contains("value")) {
        return exception["value"].dump();
      }
    }
    return details.contains("text") && details["text"].is_string()
      ? details["text"].get<std::string>() : "JavaScript evaluation failed";
  }

  inline nlohmann::json webViewScriptValue(const nlohmann::json& response)
  {
    if (!response.is_object() || webViewScriptError(response) ||
      !response.contains("result") || !response["result"].is_object() ||
      !response["result"].contains("value")) {
      return nullptr;
    }
    return response["result"]["value"];
  }
}

#endif
