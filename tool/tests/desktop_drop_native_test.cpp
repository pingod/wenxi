#include "../../vendor_plugins/desktop_drop/windows/desktop_drop_plugin.cpp"
#include <shlobj.h>

#include <cstring>
#include <stdexcept>
#include <vector>

void Check(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

class TestMessenger final : public flutter::BinaryMessenger {
 public:
  mutable std::vector<std::unique_ptr<flutter::MethodCall<flutter::EncodableValue>>> calls;
  void Send(const std::string& channel, const uint8_t* data, size_t size,
            flutter::BinaryReply reply) const override {
    Check(channel == "desktop_drop", "Unexpected native channel");
    calls.push_back(flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(data, size));
    Check(calls.back() != nullptr, "Invalid method payload");
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler) override {}
};

class MediumOwner final : public IUnknown {
 public:
  MediumOwner(HGLOBAL memory, int* releases) : memory_(memory), releases_(releases) {}
  HRESULT QueryInterface(REFIID iid, void** value) override {
    if (value == nullptr) return E_POINTER;
    *value = nullptr;
    if (iid != IID_IUnknown) return E_NOINTERFACE;
    *value = static_cast<IUnknown*>(this);
    AddRef();
    return S_OK;
  }
  ULONG AddRef() override { return ++references_; }
  ULONG Release() override {
    const auto count = --references_;
    if (count == 0) {
      GlobalFree(memory_);
      ++*releases_;
      delete this;
    }
    return count;
  }
 private:
  ULONG references_ = 1;
  HGLOBAL memory_;
  int* releases_;
};

class FileData final : public IDataObject {
 public:
  std::vector<std::wstring> paths;
  bool supported = true;
  int reads = 0, releases = 0;
  HRESULT QueryInterface(REFIID iid, void** value) override {
    if (value == nullptr) return E_POINTER;
    *value = nullptr;
    if (iid != IID_IUnknown && iid != IID_IDataObject) return E_NOINTERFACE;
    *value = static_cast<IDataObject*>(this);
    AddRef();
    return S_OK;
  }
  ULONG AddRef() override { return ++references_; }
  ULONG Release() override { return --references_; }
  HRESULT QueryGetData(FORMATETC* format) override {
    return supported && format != nullptr && format->cfFormat == CF_HDROP &&
        (format->tymed & TYMED_HGLOBAL) != 0 ? S_OK : DV_E_FORMATETC;
  }
  HRESULT GetData(FORMATETC* format, STGMEDIUM* output) override {
    ++reads;
    if (QueryGetData(format) != S_OK) return DV_E_FORMATETC;
    std::wstring payload;
    for (const auto& path : paths) { payload += path; payload.push_back(L'\0'); }
    payload.push_back(L'\0');
    if (paths.empty()) payload.push_back(L'\0');
    const auto bytes = payload.size() * sizeof(wchar_t);
    const auto memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + bytes);
    if (memory == nullptr) return E_OUTOFMEMORY;
    const auto data = static_cast<DROPFILES*>(GlobalLock(memory));
    if (data == nullptr) { GlobalFree(memory); return E_OUTOFMEMORY; }
    data->pFiles = sizeof(DROPFILES);
    data->fWide = TRUE;
    std::memcpy(reinterpret_cast<unsigned char*>(data) + sizeof(DROPFILES), payload.data(), bytes);
    GlobalUnlock(memory);
    output->tymed = TYMED_HGLOBAL;
    output->hGlobal = memory;
    output->pUnkForRelease = new MediumOwner(memory, &releases);
    return S_OK;
  }
  HRESULT GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override { return E_NOTIMPL; }
  HRESULT SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  HRESULT EnumFormatEtc(DWORD, IEnumFORMATETC**) override { return E_NOTIMPL; }
  HRESULT DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
 private:
  ULONG references_ = 1;
};

int main() {
  HWND window = nullptr;
  try {
    Check(SUCCEEDED(OleInitialize(nullptr)), "OLE initialization failed");
    window = CreateWindowExW(0, L"STATIC", L"Drop test", WS_OVERLAPPED,
        20, 30, 640, 480, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    Check(window != nullptr, "Hidden test window creation failed");
    TestMessenger messenger;
    auto channel = std::make_unique<Channel>(&messenger, "desktop_drop",
        &flutter::StandardMethodCodec::GetInstance());
    auto target = new DesktopDropTarget(std::move(channel), window);

    FileData files;
    std::wstring long_path = L"C:\\";
    std::string long_utf8 = "C:\\";
    for (int directory = 0; directory < 12; ++directory) {
      for (int character = 0; character < 40; ++character) {
        long_path += L"深";
        long_utf8 += u8"深";
      }
      long_path += L"\\";
      long_utf8 += "\\";
    }
    long_path += L"最后的文件.txt";
    long_utf8 += u8"最后的文件.txt";
    files.paths = {L"C:\\上传资料\\中文 文件.txt", long_path};
    DWORD effect = DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK;
    Check(target->DragEnter(&files, 0, {90, 110}, &effect) == S_OK &&
        effect == DROPEFFECT_COPY, "Drag must advertise copying");
    effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
    Check(target->Drop(&files, 0, {170, 210}, &effect) == S_OK &&
        effect == DROPEFFECT_COPY, "Drop must never advertise moving");
    Check(files.reads == 1 && files.releases == 1, "Drop medium must be released exactly once");
    Check(messenger.calls.size() == 3, "Enter, release position and files expected");
    Check(messenger.calls[1]->method_name() == "updated", "Missing release position");
    POINT release = {170, 210};
    ScreenToClient(window, &release);
    const auto point = std::get<flutter::EncodableList>(*messenger.calls[1]->arguments());
    Check(std::get<double>(point[0]) == release.x && std::get<double>(point[1]) == release.y,
        "Release position must be converted to client coordinates");
    Check(messenger.calls.back()->method_name() == "performOperation", "Missing file event");
    const auto paths = std::get<flutter::EncodableList>(*messenger.calls.back()->arguments());
    Check(paths.size() == 2, "All selected files must be delivered");
    Check(std::get<std::string>(paths[0]) == u8"C:\\上传资料\\中文 文件.txt", "Unicode path changed");
    Check(std::get<std::string>(paths[1]) == long_utf8, "Path longer than MAX_PATH was truncated");
    std::cout << "PASS Unicode, long paths, copy effect, release position and medium cleanup\n";

    messenger.calls.clear();
    effect = DROPEFFECT_MOVE;
    target->DragEnter(&files, 0, {100, 100}, &effect);
    Check(effect == DROPEFFECT_NONE, "Move-only source must be rejected");
    effect = DROPEFFECT_MOVE;
    target->Drop(&files, 0, {100, 100}, &effect);
    Check(effect == DROPEFFECT_NONE && files.reads == 1, "Rejected move must not read or upload data");
    std::cout << "PASS Move-only source rejected\n";

    FileData unsupported;
    unsupported.supported = false;
    effect = DROPEFFECT_COPY;
    target->DragEnter(&unsupported, 0, {100, 100}, &effect);
    Check(effect == DROPEFFECT_NONE, "Non-file data must be rejected");
    FileData empty;
    effect = DROPEFFECT_COPY;
    target->Drop(&empty, 0, {100, 100}, &effect);
    Check(effect == DROPEFFECT_NONE && empty.releases == 1, "Empty drop must release its data without copying");
    std::cout << "PASS Non-file and empty drops rejected\n";

    target->Shutdown();
    target->Shutdown();
    Check(RegisterDragDrop(window, target) == S_OK, "Shutdown must release the window registration");
    Check(RevokeDragDrop(window) == S_OK, "Test registration cleanup failed");
    Check(target->Release() == 0, "Shutdown leaked an OLE target reference");
    std::cout << "PASS Drop registration and references cleaned up\n";
    DestroyWindow(window);
    OleUninitialize();
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    if (window != nullptr) DestroyWindow(window);
    OleUninitialize();
    return 1;
  }
}
