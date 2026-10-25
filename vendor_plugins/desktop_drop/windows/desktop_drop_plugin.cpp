// Adapted from desktop_drop 0.8.4 (Mixin, Apache-2.0).
// See ../ASTERLINK_PATCHES.md for the Windows changes.
#include "include/desktop_drop/desktop_drop_plugin.h"

#include <windows.h>
#include <shellapi.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <iostream>
#include <memory>
#include <string>
#include <utility>

namespace {
using Channel = flutter::MethodChannel<flutter::EncodableValue>;

std::string ToUtf8(const std::wstring& text) {
  if (text.empty()) return {};
  const auto length = static_cast<int>(text.size());
  const auto size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      text.data(), length, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(size, '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), length,
          result.data(), size, nullptr, nullptr) != size) return {};
  return result;
}

class DropMedium {
 public:
  STGMEDIUM value{};
  ~DropMedium() { ReleaseStgMedium(&value); }
};

class DesktopDropTarget : public IDropTarget {
 public:
  DesktopDropTarget(std::unique_ptr<Channel> channel, HWND window)
      : channel_(std::move(channel)), window_(window) {
    auto result = RegisterDragDrop(window_, this);
    if (result == E_OUTOFMEMORY && SUCCEEDED(OleInitialize(nullptr))) {
      initialized_ole_ = true;
      result = RegisterDragDrop(window_, this);
    }
    registered_ = SUCCEEDED(result);
    if (!registered_) std::cout << "RegisterDragDrop failed: " << result << std::endl;
  }

  void Shutdown() {
    // Revoke while the plugin still owns its initial reference. OLE releases
    // its registration reference here, before the Flutter messenger is gone.
    if (registered_) {
      registered_ = false;
      RevokeDragDrop(window_);
    }
    if (initialized_ole_) {
      initialized_ole_ = false;
      OleUninitialize();
    }
  }

  HRESULT DragEnter(IDataObject* data, DWORD, POINTL point, DWORD* effect) override {
    if (effect == nullptr) return E_POINTER;
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    accepts_files_ = data != nullptr && data->QueryGetData(&format) == S_OK;
    *effect = accepts_files_ ? (*effect & DROPEFFECT_COPY) : DROPEFFECT_NONE;
    if (*effect != DROPEFFECT_NONE) Position("entered", point);
    return S_OK;
  }

  HRESULT DragOver(DWORD, POINTL point, DWORD* effect) override {
    if (effect == nullptr) return E_POINTER;
    *effect = accepts_files_ ? (*effect & DROPEFFECT_COPY) : DROPEFFECT_NONE;
    if (*effect != DROPEFFECT_NONE) Position("updated", point);
    return S_OK;
  }

  HRESULT DragLeave() override {
    accepts_files_ = false;
    channel_->InvokeMethod("exited", std::make_unique<flutter::EncodableValue>());
    return S_OK;
  }

  HRESULT Drop(IDataObject* data, DWORD, POINTL point, DWORD* effect) override {
    if (effect == nullptr) return E_POINTER;
    const auto allowed = *effect;
    *effect = DROPEFFECT_NONE;
    accepts_files_ = false;
    if (data == nullptr || (allowed & DROPEFFECT_COPY) == 0) return DragLeave();
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    DropMedium medium;
    if (FAILED(data->GetData(&format, &medium.value)) ||
        medium.value.tymed != TYMED_HGLOBAL || medium.value.hGlobal == nullptr) {
      return DragLeave();
    }
    try {
      flutter::EncodableList paths;
      const auto drop = reinterpret_cast<HDROP>(medium.value.hGlobal);
      const auto count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT index = 0; index < count; ++index) {
        // cch counts WCHARs, not bytes. Allocate for the entire Unicode path.
        const auto length = DragQueryFileW(drop, index, nullptr, 0);
        if (length == 0 || length > 32767) return DragLeave();
        std::wstring wide(length + 1, L'\0');
        if (DragQueryFileW(drop, index, wide.data(), length + 1) != length) {
          return DragLeave();
        }
        wide.resize(length);
        auto path = ToUtf8(wide);
        if (path.empty()) return DragLeave();
        paths.emplace_back(std::move(path));
      }
      if (paths.empty()) return DragLeave();
      // Use the release position even when the last DragOver was skipped.
      Position("updated", point);
      channel_->InvokeMethod("performOperation",
          std::make_unique<flutter::EncodableValue>(std::move(paths)));
      // Uploads copy their source; never instruct Explorer to remove files.
      *effect = DROPEFFECT_COPY;
      return S_OK;
    } catch (...) {
      DragLeave();
      return E_FAIL;
    }
  }

  HRESULT QueryInterface(const IID& iid, void** object) override {
    if (object == nullptr) return E_POINTER;
    *object = nullptr;
    if (iid != IID_IDropTarget && iid != IID_IUnknown) return E_NOINTERFACE;
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }

  ULONG AddRef() override { return InterlockedIncrement(&references_); }
  ULONG Release() override {
    const auto count = InterlockedDecrement(&references_);
    if (count == 0) delete this;
    return count;
  }

 private:
  ~DesktopDropTarget() { Shutdown(); }
  void Position(const char* method, POINTL location) {
    POINT point = {location.x, location.y};
    ScreenToClient(window_, &point);
    channel_->InvokeMethod(method, std::make_unique<flutter::EncodableValue>(
        flutter::EncodableList{flutter::EncodableValue(double(point.x)),
            flutter::EncodableValue(double(point.y))}));
  }

  std::unique_ptr<Channel> channel_;
  HWND window_;
  LONG references_ = 1;
  bool registered_ = false;
  bool initialized_ole_ = false;
  bool accepts_files_ = false;
};

class DesktopDropPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    const auto view = registrar->GetView();
    if (view == nullptr) return;
    auto channel = std::make_unique<Channel>(registrar->messenger(), "desktop_drop",
        &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([](const auto&, auto result) {
      result->NotImplemented();
    });
    auto target = new DesktopDropTarget(std::move(channel), view->GetNativeWindow());
    registrar->AddPlugin(std::make_unique<DesktopDropPlugin>(target));
  }

  explicit DesktopDropPlugin(DesktopDropTarget* target) : target_(target) {}
  ~DesktopDropPlugin() override {
    target_->Shutdown();
    target_->Release();
  }

 private:
  DesktopDropTarget* target_;
};
}  // namespace

void DesktopDropPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  DesktopDropPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
