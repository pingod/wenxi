#include <cstdlib>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

#include "../../vendor_plugins/flutter_inappwebview_windows/windows/utils/gpu_surface_frame.h"
#include "../../vendor_plugins/flutter_inappwebview_windows/windows/utils/texture_release.h"
#include "../../vendor_plugins/flutter_inappwebview_windows/windows/utils/webview_lifetime.h"

using namespace flutter_inappwebview_plugin;

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

  struct Bridge {
    explicit Bridge(std::shared_ptr<int> destructionCount)
      : destructionCount(std::move(destructionCount)) {}
    ~Bridge() { ++*destructionCount; }
    void Stop() { stopped = true; }
    std::shared_ptr<int> destructionCount;
    bool stopped = false;
  };

  class Registrar : public flutter::TextureRegistrar {
  public:
    int64_t RegisterTexture(flutter::TextureVariant* value) override
    {
      texture = value;
      return 17;
    }
    bool MarkTextureFrameAvailable(int64_t) override { return true; }
    void UnregisterTexture(int64_t id, std::function<void()> callback) override
    {
      check(id == 17, "Wrong texture was unregistered");
      ++unregisterCalls;
      pending = std::move(callback);
      if (synchronous) complete();
    }
    bool UnregisterTexture(int64_t id) override
    {
      UnregisterTexture(id, nullptr);
      return true;
    }
    void complete()
    {
      texture = nullptr;
      auto callback = std::exchange(pending, nullptr);
      if (callback) callback();
    }
    flutter::TextureVariant* texture = nullptr;
    std::function<void()> pending;
    int unregisterCalls = 0;
    bool synchronous = false;
  };

  struct EventArguments {
    int state = 0;
  };

  struct Surface {
    explicit Surface(int& released) : released(released) {}
    void AddRef() { ++refs; }
    void Release() {
      if (--refs == 0) { ++released; delete this; }
    }
    int refs = 1;
    int& released;
  };

  void pendingGpuFrames()
  {
    int released = 0;
    auto* first = new Surface(released);
    FlutterDesktopGpuSurfaceDescriptor source{};
    source.struct_size = sizeof(source);
    source.handle = reinterpret_cast<void*>(17);
    source.width = source.visible_width = 800;
    source.height = source.visible_height = 600;
    FlutterDesktopGpuSurfaceDescriptor published{};
    const auto* pending = retainGpuSurfaceFrame(published, source, first);
    check(pending && pending != &source, "GPU descriptor still aliases mutable bridge state");
    check(first->refs == 2, "Pending GPU handle did not retain its texture");

    // Resize publishes a different shared handle before Flutter opens the old
    // one; stopping then clears the bridge's descriptor and both COM owners.
    auto* second = new Surface(released);
    source.handle = reinterpret_cast<void*>(23);
    source.width = source.visible_width = 1024;
    FlutterDesktopGpuSurfaceDescriptor other_published{};
    const auto* resized = retainGpuSurfaceFrame(other_published, source, second);
    source = {};
    first->Release();
    second->Release();
    check(released == 0, "Closing the bridge freed textures still pending in Flutter");
    check(pending->handle == reinterpret_cast<void*>(17) && pending->width == 800,
      "Resize or stop overwrote an in-flight GPU descriptor");
    check(resized->handle == reinterpret_cast<void*>(23) && resized->width == 1024,
      "New GPU frame has stale dimensions or handle");
    std::thread raster([&] {
      resized->release_callback(resized->release_context);
      pending->release_callback(pending->release_context);
      // Flutter releases the COM reference before reading visible dimensions.
      // The descriptor must still be owned by the registered texture callback.
      check(pending == &published && pending->visible_width == 800 && pending->visible_height == 600,
        "GPU descriptor was released before Flutter read its visible dimensions");
      check(resized == &other_published && resized->visible_width == 1024,
        "Released GPU handle invalidated its descriptor storage");
    });
    raster.join();
    check(released == 2, "Pending GPU frames leaked or released the wrong texture");
    auto* invalid = new Surface(released);
    check(!retainGpuSurfaceFrame(published, source, invalid), "Missing GPU handle was published");
    check(invalid->refs == 1, "Rejected GPU frame leaked a texture reference");
    invalid->Release();
  }

  struct Deferral {
    std::weak_ptr<EventArguments> arguments;
    int completions = 0;
    void Complete()
    {
      check(!arguments.expired(), "Event arguments released before completing the deferral");
      ++completions;
    }
  };

  void delayedEventReply(bool closeBeforeReply, bool dropReply, bool throwInReply)
  {
    auto view = std::make_shared<int>(0);
    auto arguments = std::make_shared<EventArguments>();
    const std::weak_ptr<EventArguments> alive = arguments;
    auto deferral = std::make_shared<Deferral>();
    deferral->arguments = arguments;
    auto event = pendingWebViewEvent(std::weak_ptr<int>(view), arguments, deferral);
    // Returning from the native handler releases its reference before Dart can
    // answer. Only the pending reply may keep these arguments alive.
    arguments.reset();
    check(!alive.expired(), "Asynchronous callback retained only a borrowed argument pointer");
    if (closeBeforeReply) view.reset();
    check(event->active() == !closeBeforeReply, "Reply has the wrong view lifetime");
    int updates = 0;
    if (!dropReply) {
      try {
        event->complete([&](auto* args) {
          ++updates;
          args->state = 1;
          // A nested/default reply must not finish the same deferral twice.
          event->complete();
          if (throwInReply) throw std::runtime_error("Fixture response failure");
        });
      }
      catch (const std::runtime_error&) {}
      check(updates == (closeBeforeReply ? 0 : 1), "Late reply accessed the closed page");
      check(!event->active(), "Completed request stayed active");
      event->complete();
    }
    event.reset();
    check(deferral->completions == 1, "Deferred event did not complete exactly once");
    check(alive.expired(), "Deferred event leaked its arguments");
  }

  void textureRelease(bool gpu, bool synchronous)
  {
    Registrar registrar;
    registrar.synchronous = synchronous;
    auto destroyed = std::make_shared<int>(0);
    auto bridge = std::make_unique<Bridge>(destroyed);
    auto* borrowed = bridge.get();
    auto marker = std::make_shared<int>(0);
    std::weak_ptr<int> textureAlive = marker;
    std::unique_ptr<flutter::TextureVariant> texture;
    if (gpu) {
      texture = std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
        kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
        [borrowed, marker](size_t, size_t) -> const FlutterDesktopGpuSurfaceDescriptor* {
          check(borrowed->stopped, "Capture was still running after view disposal");
          return nullptr;
        }));
    }
    else {
      texture = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [borrowed, marker](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
          check(borrowed->stopped, "Capture was still running after view disposal");
          return nullptr;
        }));
    }
    marker.reset();
    const auto id = registrar.RegisterTexture(texture.get());
    releaseWebViewTexture(&registrar, id, std::move(texture), std::move(bridge));
    check(registrar.unregisterCalls == 1, "Texture must unregister exactly once");
    if (!synchronous) {
      check(*destroyed == 0, "WebView bridge freed before renderer finished unregistering");
      check(!textureAlive.expired(), "Texture callback freed while renderer could still call it");
      // The engine is allowed to finish a frame on its raster thread after
      // disposal was requested on the platform thread.
      std::thread raster([&] {
        if (gpu) {
          std::get<flutter::GpuSurfaceTexture>(*registrar.texture).ObtainDescriptor(100, 100);
        }
        else {
          std::get<flutter::PixelBufferTexture>(*registrar.texture).CopyPixelBuffer(100, 100);
        }
        registrar.complete();
      });
      raster.join();
    }
    check(*destroyed == 1, "Retired WebView bridge leaked");
    check(textureAlive.expired(), "Retired texture callback leaked");
    registrar.complete();
    check(*destroyed == 1, "Retired WebView bridge was destroyed twice");
  }
}

int main()
{
  pendingGpuFrames();
  delayedEventReply(false, false, false);
  delayedEventReply(true, false, false);
  delayedEventReply(false, true, false);
  delayedEventReply(true, true, false);
  delayedEventReply(false, false, true);
  for (bool gpu : {false, true}) {
    textureRelease(gpu, false);
    textureRelease(gpu, true);
  }

  auto firstView = std::make_shared<int>(0);
  auto otherView = std::make_shared<int>(0);
  int allowed = 0, cancelled = 0, other = 0;
  auto allow = guardedWebViewCallback(firstView, [&] { ++allowed; });
  auto cancel = guardedWebViewCallback(firstView, [&] { ++cancelled; });
  auto liveOther = guardedWebViewCallback(otherView, [&] { ++other; });
  allow();
  cancel();
  check(allowed == 1 && cancelled == 1, "Live view navigation decision was lost");
  firstView.reset();
  allow();
  cancel();
  liveOther();
  check(allowed == 1 && cancelled == 1, "Late navigation decision accessed a closed view");
  check(other == 1, "Closing one login window disabled a different window");

  std::cout << checks << " WebView lifecycle checks passed" << std::endl;
}
