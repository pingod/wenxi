#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_TEXTURE_RELEASE_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_TEXTURE_RELEASE_H_

#include <flutter/texture_registrar.h>
#include <memory>
#include <utility>

namespace flutter_inappwebview_plugin
{
  template <typename Bridge>
  void releaseWebViewTexture(flutter::TextureRegistrar* registrar, int64_t id,
    std::unique_ptr<flutter::TextureVariant> texture, std::unique_ptr<Bridge> bridge)
  {
    if (bridge) bridge->Stop();
    if (id < 0) return;

    // UnregisterTexture is asynchronous: the raster thread may still hold the
    // texture callback and a borrowed pointer to its bridge until completion.
    struct Resources {
      std::unique_ptr<Bridge> bridge;
      std::unique_ptr<flutter::TextureVariant> texture;
    };
    auto resources = std::make_shared<Resources>();
    resources->bridge = std::move(bridge);
    resources->texture = std::move(texture);
    registrar->UnregisterTexture(id, [resources] {});
  }
}

#endif
