#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_REPLY_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_JAVASCRIPT_REPLY_H_

#include <functional>
#include <string>
#include <utility>

namespace flutter_inappwebview_plugin
{
  // WebView2 can discard an outstanding script callback when its controller
  // closes. Flutter must still receive exactly one reply on that method call.
  class JavaScriptReply final {
  public:
    explicit JavaScriptReply(std::function<void(std::string)> callback)
      : callback_(std::move(callback)) {}
    JavaScriptReply(const JavaScriptReply&) = delete;
    JavaScriptReply& operator=(const JavaScriptReply&) = delete;
    ~JavaScriptReply() { complete("null"); }

    void complete(std::string value)
    {
      auto callback = std::exchange(callback_, nullptr);
      if (callback) callback(std::move(value));
    }

  private:
    std::function<void(std::string)> callback_;
  };
}

#endif
