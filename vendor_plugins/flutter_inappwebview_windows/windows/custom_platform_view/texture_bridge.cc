#include "texture_bridge.h"

#include <windows.foundation.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <iostream>

#include "util/direct3d11.interop.h"
#include "../utils/log.h"

namespace flutter_inappwebview_plugin
{
  const int kNumBuffers = 1;

  TextureBridge::TextureBridge(GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : graphics_context_(graphics_context)
  {
    if (graphics_context_ && visual) {
      capture_item_ = graphics_context_->CreateGraphicsCaptureItemFromVisual(visual);
    }
    if (!capture_item_) {
      nativeDiagnostic("texture.capture_item_unavailable");
      return;
    }

    capture_item_->add_Closed(
      Microsoft::WRL::Callback<ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::GraphicsCaptureItem*,
      IInspectable*>>(
        [](ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* item,
          IInspectable* args) -> HRESULT
        {
          nativeDiagnostic("texture.capture_item_closed");
          return S_OK;
        })
      .Get(),
          &on_closed_token_);
  }

  TextureBridge::~TextureBridge()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
    if (capture_item_) {
      capture_item_->remove_Closed(on_closed_token_);
    }
  }

  bool TextureBridge::Start()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (is_running_ || !capture_item_) {
      return false;
    }

    // A previous failed Start can leave a pool/session behind even though
    // is_running_ is false. Retire that partial state before retrying.
    StopInternal();
    ABI::Windows::Graphics::SizeInt32 size{};
    if (!succeededOrLog(capture_item_->get_Size(&size)) || size.Width <= 0 || size.Height <= 0) return false;

    frame_pool_ = graphics_context_->CreateCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    if (!frame_pool_) {
      nativeDiagnostic("texture.frame_pool_unavailable", size.Width, size.Height);
      return false;
    }

    capture_lifetime_ = std::make_shared<int>(0);
    const auto eventResult = frame_pool_->add_FrameArrived(
      Microsoft::WRL::Callback<ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::Direct3D11CaptureFramePool*,
      IInspectable*>>(
        [this, lifetime = std::weak_ptr<int>(capture_lifetime_)](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*
          pool,
          IInspectable* args) -> HRESULT
        {
          // This pool dispatches on the platform thread. Stop invalidates any
          // already queued frame events before the retained bridge is released.
          if (lifetime.expired()) return S_OK;
          try {
            OnFrameArrived();
          } catch (const winrt::hresult_error& error) {
            nativeDiagnostic("texture.frame_callback_failed", error.code());
            Stop();
          } catch (const std::exception&) {
            nativeDiagnostic("texture.frame_callback_failed", E_UNEXPECTED);
            Stop();
          }
          return S_OK;
        })
      .Get(),
          &on_frame_arrived_token_);
    if (failedAndLog(eventResult)) { StopInternal(); return false; }

    if (!succeededOrLog(frame_pool_->CreateCaptureSession(capture_item_.get(),
      capture_session_.put())) || !capture_session_) {
      StopInternal();
      return false;
    }

    if (succeededOrLog(capture_session_->StartCapture())) {
      is_running_ = true;
      nativeDiagnostic("texture.capture_started", size.Width, size.Height);
      return true;
    }

    StopInternal();
    return false;
  }

  void TextureBridge::Stop()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    StopInternal();
  }

  void TextureBridge::StopInternal()
  {
    capture_lifetime_.reset();
    if (is_running_) nativeDiagnostic("texture.capture_stopped");
    is_running_ = false;
    last_frame_ = nullptr;
    if (frame_pool_) frame_pool_->remove_FrameArrived(on_frame_arrived_token_);
    if (capture_session_) {
      if (auto closable = capture_session_.try_as<ABI::Windows::Foundation::IClosable>()) {
        failedLog(closable->Close());
      }
      capture_session_ = nullptr;
    }
    if (frame_pool_) {
      if (auto closable = frame_pool_.try_as<ABI::Windows::Foundation::IClosable>()) {
        failedLog(closable->Close());
      }
      frame_pool_ = nullptr;
    }
    needs_update_ = false;
    last_frame_timestamp_.reset();
  }

  void TextureBridge::OnFrameArrived()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (!is_running_ || !frame_pool_) {
      return;
    }

    bool has_frame = false;

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
      frame;
    auto hr = frame_pool_->TryGetNextFrame(frame.put());
    if (succeededOrLog(hr) && frame) {
      winrt::com_ptr<
        ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface>
        frame_surface;

      if (succeededOrLog(frame->get_Surface(frame_surface.put())) && frame_surface) {
        const auto source = TryGetDXGIInterfaceFromObject<ID3D11Texture2D>(frame_surface);
        if (source && !ShouldDropFrame()) {
          D3D11_TEXTURE2D_DESC source_desc{}, owned_desc{};
          source->GetDesc(&source_desc);
          if (last_frame_) last_frame_->GetDesc(&owned_desc);
          if (!last_frame_ || source_desc.Width != owned_desc.Width || source_desc.Height != owned_desc.Height) {
            auto desc = source_desc;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = 0;
            desc.MiscFlags = 0;
            last_frame_ = nullptr;
            failedLog(graphics_context_->d3d_device()->CreateTexture2D(&desc, nullptr, last_frame_.put()));
          }
          if (last_frame_) {
            // Capture owns source only until this frame is returned to its pool.
            // Copy now: retaining the surface alone does not retain frame ownership.
            const std::lock_guard<std::mutex> context_lock(graphics_context_->context_mutex());
            auto context = graphics_context_->d3d_device_context();
            context->CopyResource(last_frame_.get(), source.get());
            context->Flush();
            has_frame = true;
          }
        }
      }
      if (auto closable = frame.try_as<ABI::Windows::Foundation::IClosable>()) failedLog(closable->Close());
      frame = nullptr;
    }

    if (needs_update_) {
      ABI::Windows::Graphics::SizeInt32 size{};
      if (!succeededOrLog(capture_item_->get_Size(&size)) || size.Width <= 0 || size.Height <= 0) return;
      const auto resize_result = frame_pool_->Recreate(
        graphics_context_->device(),
        static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
          kPixelFormat),
        kNumBuffers, size);
      needs_update_ = failedAndLog(resize_result);
      nativeDiagnostic("texture.capture_resized", size.Width, size.Height, resize_result);
    }

    if (has_frame && frame_available_) {
      frame_available_();
    }
  }

  bool TextureBridge::ShouldDropFrame()
  {
    if (!frame_duration_.has_value()) {
      return false;
    }
    auto now = std::chrono::high_resolution_clock::now();

    bool should_drop_frame = false;
    if (last_frame_timestamp_.has_value()) {
      auto diff = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - last_frame_timestamp_.value());
      should_drop_frame = diff < frame_duration_.value();
    }

    if (!should_drop_frame) {
      last_frame_timestamp_ = now;
    }
    return should_drop_frame;
  }

  void TextureBridge::NotifySurfaceSizeChanged()
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    needs_update_ = true;
  }

  void TextureBridge::SetFpsLimit(std::optional<int> max_fps)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    auto value = max_fps.value_or(0);
    if (value != 0) {
      frame_duration_ = FrameDuration(1000.0 / value);
    }
    else {
      frame_duration_.reset();
      last_frame_timestamp_.reset();
    }
  }
}
