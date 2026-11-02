#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "../../vendor_plugins/flutter_inappwebview_windows/windows/utils/webview_json.h"
#include "../../vendor_plugins/flutter_inappwebview_windows/windows/utils/javascript_reply.h"

using namespace flutter_inappwebview_plugin;
using nlohmann::json;

int checks = 0;
void check(bool condition, const char* message)
{
  ++checks;
  if (!condition) {
    std::cerr << message << std::endl;
    std::exit(1);
  }
}

int main()
{
  int replies = 0;
  std::string result;
  auto replied = [&](std::string value) { ++replies; result = std::move(value); };
  {
    JavaScriptReply reply(replied);
    reply.complete("42");
    reply.complete("99");
  }
  check(replies == 1 && result == "42", "A script replied twice");
  {
    JavaScriptReply discarded(replied);
  }
  check(replies == 2 && result == "null", "Disposed script left a pending Flutter reply");
  for (const auto& raw : std::vector<std::string>{"", "{", "null", "[]", "12", "false", "{}"}) {
    const auto value = parseWebViewJson(raw);
    check(!readWebViewExecutionContext(value), "Invalid execution context accepted");
    check(!readWebViewScriptMessage(value), "Invalid page message accepted");
    check(!readWebViewPausedRequest(value), "Invalid navigation event accepted");
    check(webViewScriptValue(value).is_null(), "Invalid evaluation response accepted");
  }
  json navigation = {
    {"requestId", "request-1"}, {"resourceType", "Document"}, {"frameId", "main"},
    {"request", {
      {"url", "https://example.test/disk/main"}, {"urlFragment", "#files"}, {"method", "POST"},
      {"headers", {{"Accept", "text/html"}, {"Content-Length", 3}}},
      {"hasPostData", true}, {"postDataEntries", {{{"bytes", "YWJj"}}}}
    }}
  };
  const auto paused = readWebViewPausedRequest(navigation);
  check(paused && paused->url == "https://example.test/disk/main#files" &&
    paused->frameId == "main" && paused->method == "POST", "Navigation metadata changed");
  check(paused->headers && paused->headers->at("Accept") == "text/html" &&
    paused->headers->at("Content-Length") == "3", "Mixed CDP header values were not normalized");
  check(paused->postDataEntries && paused->postDataEntries->at(0) == "YWJj", "POST entries were lost");
  for (const auto* key : {"resourceType", "frameId", "request"}) {
    auto sparse = navigation;
    sparse.erase(key);
    const auto request = readWebViewPausedRequest(sparse);
    check(request && request->id == "request-1", "Sparse navigation lost the ID needed to resume it");
  }
  for (const auto* key : {"url", "urlFragment", "method", "headers", "hasPostData", "postDataEntries"}) {
    auto sparse = navigation;
    sparse["request"].erase(key);
    check(readWebViewPausedRequest(sparse).has_value(), "Optional navigation field threw or lost the request");
    for (const auto& value : std::vector<json>{nullptr, false, 7, 1.5, "x", json::array(), json::object()}) {
      auto changed = navigation;
      changed["request"][key] = value;
      check(readWebViewPausedRequest(changed).has_value(), "Unexpected navigation field type lost the request");
    }
  }
  auto redirect = navigation;
  redirect["redirectedRequestId"] = "request-0";
  check(readWebViewPausedRequest(redirect)->redirectedRequestId == "request-0", "Redirect chain was lost");
  for (const auto* key : {"responseStatusCode", "responseErrorReason"}) {
    auto response = navigation;
    response[key] = key == std::string("responseStatusCode") ? json(302) : json("Aborted");
    check(readWebViewPausedRequest(response)->responseStage, "Response navigation was intercepted as a new request");
  }
  for (const auto& entry : std::vector<json>{nullptr, 3, "YWJj", json::object(), {{"bytes", 4}}}) {
    auto changed = navigation;
    changed["request"]["postDataEntries"].push_back(entry);
    check(!readWebViewPausedRequest(changed)->postDataEntries, "Incomplete POST body was forwarded as complete");
  }
  for (const auto& id : std::vector<json>{nullptr, false, 4, "", json::array(), json::object()}) {
    auto changed = navigation;
    changed["requestId"] = id;
    check(!readWebViewPausedRequest(changed), "Invalid request ID accepted");
  }
  json context = {{"context", {
    {"id", 17}, {"name", ""},
    {"auxData", {{"isDefault", true}, {"frameId", "frame"}}}
  }}};
  const auto parsed = readWebViewExecutionContext(context);
  check(parsed && parsed->id == 17 && parsed->isDefault && parsed->frameId == "frame", "Valid page context rejected");
  context["context"]["auxData"]["isDefault"] = false;
  context["context"]["name"] = "isolated";
  check(readWebViewExecutionContext(context)->name == "isolated", "Isolated world rejected");
  for (const auto& key : {"id", "name", "auxData"}) {
    auto incomplete = context;
    incomplete["context"].erase(key);
    check(!readWebViewExecutionContext(incomplete), "Missing context field accepted");
  }
  for (const auto& bad : std::vector<json>{nullptr, false, "1", 1.5, -1, 2147483648ULL}) {
    auto changed = context;
    changed["context"]["id"] = bad;
    check(!readWebViewExecutionContext(changed), "Invalid context ID accepted");
  }
  for (const auto& key : {"frameId", "isDefault"}) {
    auto changed = context;
    changed["context"]["auxData"].erase(key);
    check(!readWebViewExecutionContext(changed), "Incomplete auxData accepted");
    changed["context"]["auxData"][key] = 7;
    check(!readWebViewExecutionContext(changed), "Wrong auxData type accepted");
  }
  json message = {{"name", "callHandler"}, {"body", {
    {"handlerName", "login"}, {"_callHandlerID", 12}, {"args", "[{\"ok\":true}]"}
  }}};
  const auto call = readWebViewScriptMessage(message);
  check(call && call->handlerName == "login" && call->callHandlerId == 12, "Valid bridge message rejected");
  for (const auto& key : {"handlerName", "_callHandlerID", "args"}) {
    auto changed = message;
    changed["body"].erase(key);
    check(!readWebViewScriptMessage(changed), "Incomplete bridge message accepted");
    changed["body"][key] = nullptr;
    check(!readWebViewScriptMessage(changed), "Null bridge field accepted");
  }
  for (const auto& args : {"", "{", "{}", "null", "false"}) {
    auto changed = message;
    changed["body"]["args"] = args;
    check(!readWebViewScriptMessage(changed), "Invalid bridge arguments accepted");
  }
  message["body"]["_callHandlerID"] = 18446744073709551615ULL;
  check(!readWebViewScriptMessage(message), "Overflowed bridge ID accepted");
  json response = {{"result", {{"type", "number"}, {"value", 42}}}};
  check(webViewScriptValue(response) == 42, "Primitive JS result changed");
  response["result"]["value"] = {{"ok", true}};
  check(webViewScriptValue(response)["ok"] == true, "Object JS result changed");
  response["exceptionDetails"] = {{"text", "Uncaught"}};
  check(webViewScriptValue(response).is_null(), "Exception produced a success value");
  check(webViewScriptError(response) == "Uncaught", "Exception text was lost");
  response["exceptionDetails"] = {{"exception", {{"description", "Error: failed"}}}};
  check(webViewScriptError(response) == "Error: failed", "Exception description was lost");
  response["exceptionDetails"] = {{"exception", {{"value", "custom error"}}}};
  check(webViewScriptError(response).has_value(), "Thrown primitive was lost");
  response["exceptionDetails"] = json::object();
  check(webViewScriptError(response) == "JavaScript evaluation failed", "Missing exception fields were not handled");
  // Optional CDP fields change across Edge versions; every JSON type should
  // remain safe to inspect even when the callback cannot use the result.
  for (const auto& value : std::vector<json>{nullptr, false, 4, 0.5, "x", json::array(), json::object()}) {
    check(!readWebViewExecutionContext({{"context", value}}), "Invalid context shape accepted");
    check(!readWebViewScriptMessage({{"name", "callHandler"}, {"body", value}}), "Invalid body shape accepted");
    check(webViewScriptValue({{"result", value}}).is_null(), "Invalid result shape accepted");
    webViewScriptError({{"exceptionDetails", value}});
  }
  std::cout << checks << " native WebView JSON checks passed" << std::endl;
  return 0;
}
