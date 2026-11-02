#include <cstdlib>
#include <iostream>
#include <memory>
#include <optional>
#include <vector>

#include "../../vendor_plugins/flutter_inappwebview_windows/windows/in_app_webview/webview_channel_delegate.h"
#include "../../vendor_plugins/flutter_inappwebview_windows/windows/utils/webview_lifetime.h"

using namespace flutter_inappwebview_plugin;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Callback = WebViewChannelDelegate::PermissionRequestCallback;

namespace {
  int checks = 0;
  void check(bool condition, const char* message)
  {
    ++checks;
    if (!condition) {
      std::cerr << message << std::endl;
      std::exit(1);
    }
  }

  struct Reply {
    int defaults = 0;
    int nulls = 0;
    int decisions = 0;
    std::shared_ptr<PermissionResponse> response;
  };

  Reply deliver(const Value* value, bool throughCodec = true)
  {
    Reply reply;
    Callback callback;
    callback.nonNullSuccess = [&reply](const auto response) {
      ++reply.decisions;
      reply.response = response;
      return false;
    };
    callback.nullSuccess = [&reply] { ++reply.nulls; return true; };
    callback.defaultBehaviour = [&reply](const auto response) {
      check(!response.has_value(), "Invalid reply became a permission decision");
      ++reply.defaults;
    };
    if (throughCodec) {
      // This is the real StandardMethodCodec path from the user's native stack.
      // An encoded Dart null becomes MethodResult::Success(nullptr).
      const auto& codec = flutter::StandardMethodCodec::GetInstance();
      const auto bytes = codec.EncodeSuccessEnvelope(value);
      check(codec.DecodeAndProcessResponseEnvelope(bytes->data(), bytes->size(), &callback),
        "Permission reply could not be decoded by StandardMethodCodec");
    }
    else if (value) callback.Success(*value);
    else callback.Success();
    return reply;
  }

  void noDecision(const Value* value, bool throughCodec = true)
  {
    const auto reply = deliver(value, throughCodec);
    check(reply.nulls == 1 && reply.defaults == 1 && reply.decisions == 0,
      "Missing or malformed permission reply did not use the default exactly once");
  }

  void nullAndInvalidReplies()
  {
    noDecision(nullptr);  // No onPermissionRequest handler in the login page.
    noDecision(nullptr, false);
    const Value null;
    noDecision(&null);
    noDecision(&null, false);

    const std::vector<Value> invalid = {
      Value(false), Value(int32_t{1}), Value(1.0), Value("invalid"), Value(List{}),
      Value(Map{}), Value(Map{{"resources", List{}}}),
      Value(Map{{"action", "grant"}}), Value(Map{{"action", true}}),
      Value(Map{{"action", 1.0}}), Value(Map{{"action", List{}}}),
      Value(Map{{"action", int32_t{-1}}}), Value(Map{{"action", int64_t{3}}}),
      Value(Map{{"action", int64_t{0x100000001}}}),
      Value(Map{{"action", int32_t{1}}, {"resources", int32_t{4}}}),
      Value(Map{{"action", int32_t{1}}, {"resources", "notifications"}}),
      Value(Map{{"action", int32_t{1}}, {"resources", List{Value(int32_t{4}), Value()}}}),
      Value(Map{{"action", int32_t{1}}, {"resources", List{Value("4")}}}),
      Value(Map{{"action", int32_t{1}}, {"resources", List{Value(true)}}}),
      Value(Map{{"action", int32_t{1}}, {"resources", List{Value(4.0)}}}),
    };
    for (const auto& value : invalid) noDecision(&value);
  }

  void validReplies()
  {
    for (int64_t action = 0; action <= 2; ++action) {
      for (bool wide : {false, true}) {
        const Value value(Map{
          {"action", wide ? Value(action) : Value(static_cast<int32_t>(action))},
          {"resources", List{Value(int32_t{4}), Value(int64_t{2})}},
        });
        const auto reply = deliver(&value);
        check(reply.defaults == 0 && reply.decisions == 1 && reply.response &&
          reply.response->action == static_cast<PermissionResponseActionType>(action),
          "Valid grant, deny, or prompt action was changed");
        check(reply.response->resources == std::optional<std::vector<int64_t>>({4, 2}),
          "Mixed 32/64-bit resource values were rejected or padded with zeros");
        const Value encoded(reply.response->toEncodableMap());
        const auto roundTrip = deliver(&encoded);
        check(roundTrip.response && *roundTrip.response == *reply.response,
          "Permission response did not survive a second codec round trip");
      }
    }
    const std::vector<Map> optionalResources = {
      {{"action", int32_t{1}}},
      {{"action", int32_t{1}}, {"resources", Value()}},
      {{"action", int32_t{1}}, {"resources", List{}}},
      {{"action", int32_t{1}}, {"resources", List{}}, {"futureField", "ignored"}},
    };
    for (const auto& map : optionalResources) {
      const Value value(map);
      const auto reply = deliver(&value);
      check(reply.defaults == 0 && reply.response &&
        reply.response->action == PermissionResponseActionType::grant,
        "Optional resources or extra fields broke a valid permission decision");
    }
    const Value explicitPrompt(Map{{"action", Value()}, {"resources", List{}}});
    const auto reply = deliver(&explicitPrompt);
    check(reply.response && reply.response->action == PermissionResponseActionType::prompt,
      "Explicit action:null no longer preserves browser-prompt behavior");
  }

  struct Arguments { int writes = 0; };
  struct Deferral {
    explicit Deferral(int& completions) : completions(completions) {}
    void Complete() { ++completions; }
    int& completions;
  };

  void lateReplies()
  {
    for (bool closed : {false, true}) {
      for (int replyKind = 0; replyKind < 5; ++replyKind) {
        int completions = 0;
        auto lifetime = std::make_shared<int>(0);
        auto arguments = std::make_shared<Arguments>();
        {
          const auto event = pendingWebViewEvent(std::weak_ptr<int>(lifetime), arguments,
            std::make_shared<Deferral>(completions));
          Callback callback;
          callback.defaultBehaviour = [event](const auto) {
            event->complete([](auto* args) { ++args->writes; });
          };
          callback.nonNullSuccess = [event](const auto response) {
            check(response != nullptr, "A null pointer reached the decision handler");
            event->complete([](auto* args) { ++args->writes; });
            return false;
          };
          callback.error = [fallback = callback.defaultBehaviour](const auto&, const auto&, const auto*) {
            fallback(std::nullopt);
          };
          if (closed) lifetime.reset();
          switch (replyKind) {
          case 0: callback.Success(); break;
          case 1: callback.Success(Value(Map{{"action", int32_t{1}}})); break;
          case 2: callback.Error("fixture_failure"); break;
          case 3: callback.NotImplemented(); break;
          default: break;  // The channel drops a pending reply during disposal.
          }
        }
        check(completions == 1, "A permission deferral was lost or completed twice");
        check(arguments->writes == ((!closed && replyKind < 4) ? 1 : 0),
          "A late permission reply accessed a closed page");
      }
    }
  }
}

int main()
{
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  nullAndInvalidReplies();
  validReplies();
  lateReplies();
  std::cout << "Passed " << checks << " permission callback checks" << std::endl;
  return 0;
}
