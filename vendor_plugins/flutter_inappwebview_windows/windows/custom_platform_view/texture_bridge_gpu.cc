#include "texture_bridge_gpu.h"

#include <iostream>

#include "util/direct3d11.interop.h"
#include "../utils/gpu_surface_frame.h"
#include "../utils/log.h"

namespace flutter_inappwebview_plugin
{
  TextureBridgeGpu::TextureBridgeGpu(
    GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : TextureBridge(graphics_context, visual)
  {
    surface_descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    surface_descriptor_.format =
      kFlutterDesktopPixelFormatNone;  // no format required for DXGI surfaces
  }

  bool TextureBridgeGpu::ProcessFrame(
    winrt::com_ptr<ID3D11Texture2D> src_texture)
  {
    const std::lock_guard<std::mutex> context_lock(graphics_context_->context_mutex());
    D3D11_TEXTURE2D_DESC desc;
    src_texture->GetDesc(&desc);

    const auto width = desc.Width;
    const auto height = desc.Height;

    if (!EnsureSurface(width, height)) {
      return false;
    }

    auto device_context = graphics_context_->d3d_device_context();

    device_context->CopyResource(surface_.get(), src_texture.get());
    device_context->Flush();
    return true;
  }

  bool TextureBridgeGpu::EnsureSurface(uint32_t width, uint32_t height)
  {
    if (width == 0 || height == 0) {
      return false;
    }

    if (!surface_ || surface_size_.width != width ||
      surface_size_.height != height) {
      D3D11_TEXTURE2D_DESC dstDesc = {};
      dstDesc.ArraySize = 1;
      dstDesc.MipLevels = 1;
      dstDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      dstDesc.CPUAccessFlags = 0;
      dstDesc.Format = static_cast<DXGI_FORMAT>(kPixelFormat);
      dstDesc.Width = width;
      dstDesc.Height = height;
      dstDesc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
      dstDesc.SampleDesc.Count = 1;
      dstDesc.SampleDesc.Quality = 0;
      dstDesc.Usage = D3D11_USAGE_DEFAULT;

      // Publish a replacement only after its texture and shared handle are valid.
      winrt::com_ptr<ID3D11Texture2D> surface;
      if (!succeededOrLog(graphics_context_->d3d_device()->CreateTexture2D(
        &dstDesc, nullptr, surface.put()))) {
        std::cerr << "Creating intermediate texture failed" << std::endl;
        return false;
      }

      auto dxgi_surface = surface.try_as<IDXGIResource>();
      HANDLE shared_handle = nullptr;
      if (!dxgi_surface || !succeededOrLog(dxgi_surface->GetSharedHandle(&shared_handle)) ||
        !shared_handle) {
        std::cerr << "Getting intermediate texture shared handle failed" << std::endl;
        return false;
      }

      surface_ = std::move(surface);
      dxgi_surface_ = std::move(dxgi_surface);

      surface_descriptor_.handle = shared_handle;
      surface_descriptor_.width = surface_descriptor_.visible_width = width;
      surface_descriptor_.height = surface_descriptor_.visible_height = height;
      surface_size_ = { width, height };
    }
    return true;
  }

  const FlutterDesktopGpuSurfaceDescriptor*
    TextureBridgeGpu::GetSurfaceDescriptor(size_t width, size_t height)
  {
    const std::lock_guard<std::mutex> lock(mutex_);

    if (!is_running_) {
      return nullptr;
    }

    if (last_frame_ && !ProcessFrame(last_frame_)) {
      return nullptr;
    }

    if (!surface_ || !surface_descriptor_.handle) {
      return nullptr;
    }

    return retainGpuSurfaceFrame(published_descriptor_, surface_descriptor_, surface_.get());
  }

  void TextureBridgeGpu::StopInternal()
  {
    TextureBridge::StopInternal();

    // For some reason, the destination surface needs to be recreated upon
    // resuming. Force |EnsureSurface| to create a new one by resetting it here.
    surface_descriptor_ = {};
    surface_descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    surface_descriptor_.format = kFlutterDesktopPixelFormatNone;
    surface_size_ = { 0, 0 };
    dxgi_surface_ = nullptr;
    surface_ = nullptr;
  }
}
