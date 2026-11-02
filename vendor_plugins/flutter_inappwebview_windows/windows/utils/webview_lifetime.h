#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_WEBVIEW_LIFETIME_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_WEBVIEW_LIFETIME_H_

#include <functional>
#include <memory>
#include <utility>

namespace flutter_inappwebview_plugin
{
  // Navigation decisions can return from Dart after the originating view closes.
  // WebView callbacks and view destruction run on the platform thread.
  inline std::function<void()> guardedWebViewCallback(
    std::weak_ptr<int> lifetime, std::function<void()> callback)
  {
    return [lifetime = std::move(lifetime), callback = std::move(callback)] {
      if (!lifetime.expired()) callback();
    };
  }

  // A deferral does not replace ownership of its COM event arguments. Retain
  // both until Dart replies, and finish once even if the reply is discarded.
  // Like WebView2 event handlers, this object is used on the platform thread.
  template <typename Arguments, typename Deferral>
  class PendingWebViewEvent final {
  public:
    PendingWebViewEvent(std::weak_ptr<int> lifetime, Arguments arguments, Deferral deferral)
      : lifetime_(std::move(lifetime)), arguments_(std::move(arguments)), deferral_(std::move(deferral)) {}
    PendingWebViewEvent(const PendingWebViewEvent&) = delete;
    PendingWebViewEvent& operator=(const PendingWebViewEvent&) = delete;
    ~PendingWebViewEvent() { complete(); }

    bool active() const { return deferral_ && !lifetime_.expired(); }

    template <typename Callback>
    void complete(Callback callback)
    {
      if (!deferral_) return;
      auto arguments = std::move(arguments_);
      struct Completion {
        Deferral deferral;
        ~Completion() { deferral->Complete(); }
      } completion{ std::move(deferral_) };
      // Mark complete before invoking code which can dispatch further events.
      // The event arguments outlive Complete(), including during unwinding.
      if (!lifetime_.expired()) callback(arguments.get());
    }

    void complete() { complete([](auto*) {}); }

  private:
    std::weak_ptr<int> lifetime_;
    Arguments arguments_;
    Deferral deferral_;
  };

  template <typename Arguments, typename Deferral>
  auto pendingWebViewEvent(std::weak_ptr<int> lifetime, Arguments arguments, Deferral deferral)
  {
    return std::make_shared<PendingWebViewEvent<Arguments, Deferral>>(
      std::move(lifetime), std::move(arguments), std::move(deferral));
  }
}

#endif
