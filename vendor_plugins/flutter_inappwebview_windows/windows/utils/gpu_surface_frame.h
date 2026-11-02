#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_GPU_SURFACE_FRAME_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_GPU_SURFACE_FRAME_H_

#include <flutter_texture_registrar.h>

namespace flutter_inappwebview_plugin {
// `published` belongs exclusively to the raster callback and stays alive until
// texture unregistration completes. Flutter still reads visible_width/height
// AFTER release_callback in ExternalTextureD3d::PopulateTexture, so that callback
// releases only the COM texture, never the descriptor itself. The UI thread may
// meanwhile stop/resize capture and rewrite `source` without touching this copy.
template <typename Texture>
const FlutterDesktopGpuSurfaceDescriptor* retainGpuSurfaceFrame(
    FlutterDesktopGpuSurfaceDescriptor& published,
    const FlutterDesktopGpuSurfaceDescriptor& source, Texture* texture) noexcept {
  if (!texture || !source.handle) return nullptr;
  texture->AddRef();
  published = source;
  published.release_context = texture;
  published.release_callback = [](void* context) {
    static_cast<Texture*>(context)->Release();
  };
  return &published;
}
}  // namespace flutter_inappwebview_plugin

#endif
