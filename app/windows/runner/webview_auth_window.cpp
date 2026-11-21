#include "webview_auth_window.h"

#include <dwmapi.h>
#include <objbase.h>
#include <shlobj.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cwchar>
#include <utility>

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
#include <WebView2.h>
#endif

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

namespace {

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int len = WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
      nullptr, 0, nullptr, nullptr);
  if (len <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(len), '\0');
  const int written = WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
      utf8.data(), len, nullptr, nullptr);
  if (written <= 0) {
    return std::string();
  }
  return utf8;
}

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2

constexpr wchar_t kAuthWindowClassName[] = L"LUMINA_WEBVIEW2_AUTH_WINDOW";
constexpr UINT_PTR kCookiePollTimerId = 1001;
constexpr UINT kCookiePollIntervalMs = 700;
constexpr int kAuthWindowWidth = 960;
constexpr int kAuthWindowHeight = 720;
constexpr wchar_t kChromeUserAgent[] =
    L"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    L"(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

std::string ToLowerAscii(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char ch) {
    return static_cast<char>(std::tolower(ch));
  });
  return s;
}

std::string UrlDecodeComponent(const std::string& raw) {
  std::string out;
  out.reserve(raw.size());
  for (size_t i = 0; i < raw.size(); ++i) {
    if (raw[i] == '+') {
      out.push_back(' ');
    } else if (raw[i] == '%' && i + 2 < raw.size()) {
      auto hex_val = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
      };
      const int hi = hex_val(raw[i + 1]);
      const int lo = hex_val(raw[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.push_back(static_cast<char>((hi << 4) | lo));
        i += 2;
      } else {
        out.push_back(raw[i]);
      }
    } else {
      out.push_back(raw[i]);
    }
  }
  return out;
}

std::wstring GetAuthUserDataFolder() {
  wchar_t local_app_data[MAX_PATH] = {};
  std::wstring base;
  if (SUCCEEDED(::SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0,
                                 local_app_data))) {
    base = local_app_data;
  } else {
    wchar_t env_buf[MAX_PATH] = {};
    const DWORD env_len =
        ::GetEnvironmentVariableW(L"LOCALAPPDATA", env_buf, MAX_PATH);
    if (env_len > 0 && env_len < MAX_PATH) {
      base.assign(env_buf, env_len);
    }
  }
  if (base.empty()) {
    wchar_t temp_buf[MAX_PATH] = {};
    const DWORD temp_len = ::GetTempPathW(MAX_PATH, temp_buf);
    if (temp_len > 0 && temp_len < MAX_PATH) {
      base.assign(temp_buf, temp_len);
    }
  }
  if (!base.empty() && base.back() != L'\\') {
    base.push_back(L'\\');
  }
  return base + L"LuminaAudio\\WebView2Auth";
}

HMODULE LoadWebView2LoaderModule() {
  static HMODULE cached_module = nullptr;
  if (cached_module != nullptr) {
    return cached_module;
  }

  wchar_t exe_path[MAX_PATH] = {};
  const DWORD len = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (len > 0 && len < MAX_PATH) {
    std::wstring dir(exe_path, len);
    const size_t sep = dir.find_last_of(L"\\/");
    if (sep != std::wstring::npos) {
      const std::wstring candidate =
          dir.substr(0, sep + 1) + L"WebView2Loader.dll";
      cached_module = ::LoadLibraryW(candidate.c_str());
    }
  }
  if (cached_module == nullptr) {
    cached_module = ::LoadLibraryW(L"WebView2Loader.dll");
  }
  return cached_module;
}

using CreateCoreWebView2EnvironmentWithOptionsFn = HRESULT(STDAPICALLTYPE*)(
    PCWSTR browserExecutableFolder,
    PCWSTR userDataFolder,
    ICoreWebView2EnvironmentOptions* environmentOptions,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* handler);

using GetAvailableCoreWebView2BrowserVersionStringFn =
    HRESULT(STDAPICALLTYPE*)(PCWSTR browserExecutableFolder, LPWSTR* version);

template <typename InvokeFn>
class EnvironmentCompletedHandler final
    : public ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler {
 public:
  explicit EnvironmentCompletedHandler(InvokeFn fn)
      : ref_count_(1), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == __uuidof(
            ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)) {
      *ppv = static_cast<
          ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1) + 1);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG next = static_cast<ULONG>(ref_count_.fetch_sub(1) - 1);
    if (next == 0) delete this;
    return next;
  }
  HRESULT STDMETHODCALLTYPE
  Invoke(HRESULT error_code, ICoreWebView2Environment* env) override {
    return fn_(error_code, env);
  }

 private:
  ~EnvironmentCompletedHandler() = default;
  std::atomic<LONG> ref_count_;
  InvokeFn fn_;
};

template <typename InvokeFn>
class ControllerCompletedHandler final
    : public ICoreWebView2CreateCoreWebView2ControllerCompletedHandler {
 public:
  explicit ControllerCompletedHandler(InvokeFn fn)
      : ref_count_(1), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == __uuidof(
            ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)) {
      *ppv = static_cast<
          ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1) + 1);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG next = static_cast<ULONG>(ref_count_.fetch_sub(1) - 1);
    if (next == 0) delete this;
    return next;
  }
  HRESULT STDMETHODCALLTYPE
  Invoke(HRESULT error_code, ICoreWebView2Controller* controller) override {
    return fn_(error_code, controller);
  }

 private:
  ~ControllerCompletedHandler() = default;
  std::atomic<LONG> ref_count_;
  InvokeFn fn_;
};

template <typename InvokeFn>
class NavigationCompletedHandler final
    : public ICoreWebView2NavigationCompletedEventHandler {
 public:
  explicit NavigationCompletedHandler(InvokeFn fn)
      : ref_count_(1), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == __uuidof(ICoreWebView2NavigationCompletedEventHandler)) {
      *ppv = static_cast<ICoreWebView2NavigationCompletedEventHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1) + 1);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG next = static_cast<ULONG>(ref_count_.fetch_sub(1) - 1);
    if (next == 0) delete this;
    return next;
  }
  HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2* sender,
         ICoreWebView2NavigationCompletedEventArgs* args) override {
    return fn_(sender, args);
  }

 private:
  ~NavigationCompletedHandler() = default;
  std::atomic<LONG> ref_count_;
  InvokeFn fn_;
};

template <typename InvokeFn>
class WebResourceRequestedHandler final
    : public ICoreWebView2WebResourceRequestedEventHandler {
 public:
  explicit WebResourceRequestedHandler(InvokeFn fn)
      : ref_count_(1), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == __uuidof(ICoreWebView2WebResourceRequestedEventHandler)) {
      *ppv = static_cast<ICoreWebView2WebResourceRequestedEventHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1) + 1);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG next = static_cast<ULONG>(ref_count_.fetch_sub(1) - 1);
    if (next == 0) delete this;
    return next;
  }
  HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2* sender,
         ICoreWebView2WebResourceRequestedEventArgs* args) override {
    return fn_(sender, args);
  }

 private:
  ~WebResourceRequestedHandler() = default;
  std::atomic<LONG> ref_count_;
  InvokeFn fn_;
};

template <typename InvokeFn>
class GetCookiesCompletedHandler final
    : public ICoreWebView2GetCookiesCompletedHandler {
 public:
  explicit GetCookiesCompletedHandler(InvokeFn fn)
      : ref_count_(1), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == __uuidof(ICoreWebView2GetCookiesCompletedHandler)) {
      *ppv = static_cast<ICoreWebView2GetCookiesCompletedHandler*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(ref_count_.fetch_add(1) + 1);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG next = static_cast<ULONG>(ref_count_.fetch_sub(1) - 1);
    if (next == 0) delete this;
    return next;
  }
  HRESULT STDMETHODCALLTYPE
  Invoke(HRESULT result, ICoreWebView2CookieList* cookie_list) override {
    return fn_(result, cookie_list);
  }

 private:
  ~GetCookiesCompletedHandler() = default;
  std::atomic<LONG> ref_count_;
  InvokeFn fn_;
};

#endif  // LUMINA_HAS_WEBVIEW2

}  // namespace

struct WebViewAuthWindow::Impl
    : public std::enable_shared_from_this<WebViewAuthWindow::Impl> {
  HWND parent_hwnd = nullptr;
  HWND hwnd = nullptr;
  UINT closed_notify_msg = 0;
  WebViewAuthRequest request;
  CompletionCallback on_complete;
  bool closing = false;
  bool completed = false;
  HBRUSH bg_brush = nullptr;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  ICoreWebView2Controller* controller = nullptr;
  ICoreWebView2* webview = nullptr;
  ICoreWebView2CookieManager* cookie_manager = nullptr;
  EventRegistrationToken nav_completed_token{};
  EventRegistrationToken web_resource_token{};
  bool has_nav_token = false;
  bool has_resource_token = false;
  bool cookie_poll_in_flight = false;

  std::string current_url;
  std::string cookie_header;
  std::map<std::string, std::string> cookies;
  std::map<std::string, std::string> headers;
  std::map<std::string, std::string> query_params;
#endif

  ~Impl() {
    CleanupWebView();
    if (bg_brush != nullptr) {
      ::DeleteObject(bg_brush);
      bg_brush = nullptr;
    }
  }

  void FinishWithResult(const WebViewAuthResult& res) {
    if (completed) {
      return;
    }
    completed = true;
    closing = true;
    if (hwnd != nullptr && ::IsWindow(hwnd)) {
      ::KillTimer(hwnd, 1001);
    }
    auto cb = std::move(on_complete);
    on_complete = nullptr;
    if (cb) {
      cb(res);
    }
    CleanupWebView();
    if (hwnd != nullptr && ::IsWindow(hwnd)) {
      ::DestroyWindow(hwnd);
    }
    if (parent_hwnd != nullptr && ::IsWindow(parent_hwnd)) {
      ::SetForegroundWindow(parent_hwnd);
    }
  }

  void CleanupWebView() {
#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
    if (webview != nullptr) {
      if (has_nav_token) {
        webview->remove_NavigationCompleted(nav_completed_token);
        has_nav_token = false;
      }
      if (has_resource_token) {
        webview->remove_WebResourceRequested(web_resource_token);
        has_resource_token = false;
      }
      webview->Release();
      webview = nullptr;
    }
    if (cookie_manager != nullptr) {
      cookie_manager->Release();
      cookie_manager = nullptr;
    }
    if (controller != nullptr) {
      controller->Close();
      controller->Release();
      controller = nullptr;
    }
#endif
  }

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  void UpdateBounds() {
    if (closing || controller == nullptr || hwnd == nullptr) {
      return;
    }
    RECT rect{};
    ::GetClientRect(hwnd, &rect);
    controller->put_Bounds(rect);
  }

  void RefreshCurrentUrl() {
    if (webview == nullptr) return;
    LPWSTR src = nullptr;
    if (SUCCEEDED(webview->get_Source(&src)) && src != nullptr) {
      current_url = WideToUtf8(src);
      ::CoTaskMemFree(src);
    }
  }

  bool MatchesUrlGuard(const std::string& url_utf8) const {
    if (url_utf8.empty()) {
      return false;
    }
    const std::string lower_url = ToLowerAscii(url_utf8);
    if (!request.required_host_substring.empty()) {
      const std::string host_needle =
          ToLowerAscii(WideToUtf8(request.required_host_substring));
      if (lower_url.find(host_needle) == std::string::npos) {
        return false;
      }
    }
    for (const auto& excl : request.excluded_url_substrings) {
      const std::string needle = ToLowerAscii(WideToUtf8(excl));
      if (!needle.empty() && lower_url.find(needle) != std::string::npos) {
        return false;
      }
    }
    return true;
  }

  bool HasNonEmptyValue(const std::map<std::string, std::string>& m,
                        const std::string& key) const {
    auto it = m.find(key);
    return it != m.end() && !it->second.empty();
  }

  bool EvaluateCaptureReady() {
    if (closing) {
      return false;
    }
    RefreshCurrentUrl();
    if (!MatchesUrlGuard(current_url)) {
      return false;
    }

    bool has_any_rule = false;

    if (!request.required_any_cookies.empty()) {
      has_any_rule = true;
      bool matched = false;
      for (const auto& req_cookie : request.required_any_cookies) {
        if (HasNonEmptyValue(cookies, WideToUtf8(req_cookie))) {
          matched = true;
          break;
        }
      }
      if (!matched) {
        return false;
      }
    }

    if (!request.required_all_cookies.empty()) {
      has_any_rule = true;
      for (const auto& req_cookie : request.required_all_cookies) {
        if (!HasNonEmptyValue(cookies, WideToUtf8(req_cookie))) {
          return false;
        }
      }
    }

    if (!request.required_headers.empty()) {
      has_any_rule = true;
      for (const auto& req_hdr : request.required_headers) {
        const std::string key = ToLowerAscii(WideToUtf8(req_hdr));
        if (!HasNonEmptyValue(headers, key) &&
            !HasNonEmptyValue(query_params, key)) {
          return false;
        }
      }
    }

    if (!request.required_groups.empty()) {
      has_any_rule = true;
      for (const auto& group : request.required_groups) {
        bool group_ok = false;
        for (const auto& item_wide : group) {
          const std::string item = WideToUtf8(item_wide);
          if (item.rfind("cookie:", 0) == 0) {
            if (HasNonEmptyValue(cookies, item.substr(7))) {
              group_ok = true;
              break;
            }
          } else if (item.rfind("header:", 0) == 0) {
            if (HasNonEmptyValue(headers, ToLowerAscii(item.substr(7)))) {
              group_ok = true;
              break;
            }
          } else if (item.rfind("query:", 0) == 0) {
            if (HasNonEmptyValue(query_params, ToLowerAscii(item.substr(6)))) {
              group_ok = true;
              break;
            }
          }
        }
        if (!group_ok) {
          return false;
        }
      }
    }

    if (!has_any_rule) {
      return false;
    }

    WebViewAuthResult res;
    res.captured = true;
    res.cancelled = false;
    res.cookie_header = cookie_header;
    res.cookies = cookies;
    res.headers = headers;
    res.query_params = query_params;
    res.captured_url = current_url;
    FinishWithResult(res);
    return true;
  }

  void PollCookies() {
    if (closing || webview == nullptr) {
      return;
    }
    RefreshCurrentUrl();
    if (!MatchesUrlGuard(current_url)) {
      return;
    }
    if (cookie_manager == nullptr || request.cookie_domain.empty()) {
      EvaluateCaptureReady();
      return;
    }
    if (cookie_poll_in_flight) {
      return;
    }
    cookie_poll_in_flight = true;
    auto self = shared_from_this();
    auto* handler = new (std::nothrow) GetCookiesCompletedHandler(
        [self](HRESULT hr, ICoreWebView2CookieList* list) -> HRESULT {
          self->cookie_poll_in_flight = false;
          if (self->closing || FAILED(hr) || list == nullptr) {
            return S_OK;
          }
          UINT count = 0;
          if (SUCCEEDED(list->get_Count(&count))) {
            self->cookies.clear();
            std::string assembled;
            for (UINT i = 0; i < count; ++i) {
              ICoreWebView2Cookie* cookie = nullptr;
              if (SUCCEEDED(list->GetValueAtIndex(i, &cookie)) &&
                  cookie != nullptr) {
                LPWSTR raw_name = nullptr;
                LPWSTR raw_val = nullptr;
                if (SUCCEEDED(cookie->get_Name(&raw_name)) &&
                    SUCCEEDED(cookie->get_Value(&raw_val)) &&
                    raw_name != nullptr && raw_val != nullptr) {
                  const std::string name = WideToUtf8(raw_name);
                  const std::string val = WideToUtf8(raw_val);
                  if (!name.empty() && !val.empty()) {
                    self->cookies[name] = val;
                    if (!assembled.empty()) {
                      assembled.append("; ");
                    }
                    assembled.append(name);
                    assembled.push_back('=');
                    assembled.append(val);
                  }
                }
                if (raw_name != nullptr) ::CoTaskMemFree(raw_name);
                if (raw_val != nullptr) ::CoTaskMemFree(raw_val);
                cookie->Release();
              }
            }
            self->cookie_header = std::move(assembled);
          }
          self->EvaluateCaptureReady();
          return S_OK;
        });
    if (handler == nullptr) {
      cookie_poll_in_flight = false;
      return;
    }
    const HRESULT hr =
        cookie_manager->GetCookies(request.cookie_domain.c_str(), handler);
    handler->Release();
    if (FAILED(hr)) {
      cookie_poll_in_flight = false;
    }
  }

  void HandleWebResourceRequested(
      ICoreWebView2WebResourceRequestedEventArgs* args) {
    if (closing || args == nullptr || request.header_url_substrings.empty()) {
      return;
    }
    ICoreWebView2WebResourceRequest* req = nullptr;
    if (FAILED(args->get_Request(&req)) || req == nullptr) {
      return;
    }

    LPWSTR raw_uri = nullptr;
    bool uri_matches = false;
    std::string req_uri_utf8;
    if (SUCCEEDED(req->get_Uri(&raw_uri)) && raw_uri != nullptr) {
      req_uri_utf8 = WideToUtf8(raw_uri);
      ::CoTaskMemFree(raw_uri);
      const std::string lower_uri = ToLowerAscii(req_uri_utf8);
      for (const auto& sub : request.header_url_substrings) {
        const std::string needle = ToLowerAscii(WideToUtf8(sub));
        if (!needle.empty() && lower_uri.find(needle) != std::string::npos) {
          uri_matches = true;
          break;
        }
      }
    }

    if (!uri_matches) {
      req->Release();
      return;
    }

    bool updated = false;

    // Extract matching query parameters when configured.
    if (!request.capture_query_params.empty()) {
      const size_t q_pos = req_uri_utf8.find('?');
      if (q_pos != std::string::npos) {
        size_t end_pos = req_uri_utf8.find('#', q_pos);
        if (end_pos == std::string::npos) end_pos = req_uri_utf8.size();
        const std::string query_str =
            req_uri_utf8.substr(q_pos + 1, end_pos - q_pos - 1);
        size_t start = 0;
        while (start < query_str.size()) {
          size_t amp = query_str.find('&', start);
          if (amp == std::string::npos) amp = query_str.size();
          const std::string pair = query_str.substr(start, amp - start);
          const size_t eq = pair.find('=');
          if (eq != std::string::npos) {
            const std::string key =
                ToLowerAscii(UrlDecodeComponent(pair.substr(0, eq)));
            const std::string val = UrlDecodeComponent(pair.substr(eq + 1));
            if (!val.empty()) {
              for (const auto& want : request.capture_query_params) {
                if (key == ToLowerAscii(WideToUtf8(want))) {
                  query_params[key] = val;
                  updated = true;
                  break;
                }
              }
            }
          }
          start = amp + 1;
        }
      }
    }

    // Extract matching request headers (case-insensitive).
    if (!request.capture_header_names.empty()) {
      ICoreWebView2HttpRequestHeaders* req_headers = nullptr;
      if (SUCCEEDED(req->get_Headers(&req_headers)) && req_headers != nullptr) {
        ICoreWebView2HttpHeadersCollectionIterator* it = nullptr;
        if (SUCCEEDED(req_headers->GetIterator(&it)) && it != nullptr) {
          BOOL has_current = FALSE;
          while (SUCCEEDED(it->get_HasCurrentHeader(&has_current)) &&
                 has_current) {
            LPWSTR h_name = nullptr;
            LPWSTR h_val = nullptr;
            if (SUCCEEDED(it->GetCurrentHeader(&h_name, &h_val)) &&
                h_name != nullptr && h_val != nullptr) {
              const std::string lower_name = ToLowerAscii(WideToUtf8(h_name));
              const std::string val = WideToUtf8(h_val);
              if (!val.empty()) {
                for (const auto& want : request.capture_header_names) {
                  if (lower_name == ToLowerAscii(WideToUtf8(want))) {
                    headers[lower_name] = val;
                    updated = true;
                    break;
                  }
                }
              }
            }
            if (h_name != nullptr) ::CoTaskMemFree(h_name);
            if (h_val != nullptr) ::CoTaskMemFree(h_val);

            BOOL moved = FALSE;
            if (FAILED(it->MoveNext(&moved)) || !moved) {
              break;
            }
          }
          it->Release();
        }
        req_headers->Release();
      }
    }

    req->Release();

    if (updated) {
      if (cookie_manager != nullptr && !request.cookie_domain.empty()) {
        PollCookies();
      } else {
        EvaluateCaptureReady();
      }
    }
  }

  void StartWebView2() {
    HMODULE loader = LoadWebView2LoaderModule();
    if (loader == nullptr) {
      WebViewAuthResult res;
      res.error = "WebView2Loader.dll not available";
      FinishWithResult(res);
      return;
    }

    auto create_env_fn =
        reinterpret_cast<CreateCoreWebView2EnvironmentWithOptionsFn>(
            ::GetProcAddress(loader,
                             "CreateCoreWebView2EnvironmentWithOptions"));
    if (create_env_fn == nullptr) {
      WebViewAuthResult res;
      res.error =
          "CreateCoreWebView2EnvironmentWithOptions export missing in "
          "WebView2Loader.dll";
      FinishWithResult(res);
      return;
    }

    const std::wstring user_data_dir = GetAuthUserDataFolder();
    auto self = shared_from_this();
    auto* env_handler = new (std::nothrow) EnvironmentCompletedHandler(
        [self](HRESULT hr, ICoreWebView2Environment* env) -> HRESULT {
          if (self->closing) {
            return S_OK;
          }
          if (FAILED(hr) || env == nullptr) {
            WebViewAuthResult res;
            res.error = "Failed to initialize WebView2 runtime (HRESULT=" +
                        std::to_string(static_cast<long>(hr)) + ")";
            self->FinishWithResult(res);
            return S_OK;
          }

          auto* ctrl_handler = new (std::nothrow) ControllerCompletedHandler(
              [self](HRESULT ctrl_hr,
                     ICoreWebView2Controller* ctrl) -> HRESULT {
                if (self->closing) {
                  if (ctrl != nullptr) ctrl->Close();
                  return S_OK;
                }
                if (FAILED(ctrl_hr) || ctrl == nullptr) {
                  WebViewAuthResult res;
                  res.error = "Failed to create WebView2 controller";
                  self->FinishWithResult(res);
                  return S_OK;
                }

                self->controller = ctrl;
                self->controller->AddRef();
                self->UpdateBounds();
                self->controller->put_IsVisible(TRUE);

                ICoreWebView2Controller2* ctrl2 = nullptr;
                if (SUCCEEDED(self->controller->QueryInterface(
                        __uuidof(ICoreWebView2Controller2),
                        reinterpret_cast<void**>(&ctrl2))) &&
                    ctrl2 != nullptr) {
                  COREWEBVIEW2_COLOR dark_bg{255, 17, 19, 24};
                  ctrl2->put_DefaultBackgroundColor(dark_bg);
                  ctrl2->Release();
                }

                if (FAILED(self->controller->get_CoreWebView2(&self->webview)) ||
                    self->webview == nullptr) {
                  WebViewAuthResult res;
                  res.error = "Failed to acquire CoreWebView2 instance";
                  self->FinishWithResult(res);
                  return S_OK;
                }

                ICoreWebView2Settings* settings = nullptr;
                if (SUCCEEDED(self->webview->get_Settings(&settings)) &&
                    settings != nullptr) {
                  settings->put_AreDefaultScriptDialogsEnabled(TRUE);
                  settings->put_IsStatusBarEnabled(FALSE);
                  settings->put_AreDevToolsEnabled(FALSE);
                  ICoreWebView2Settings2* settings2 = nullptr;
                  if (SUCCEEDED(settings->QueryInterface(
                          __uuidof(ICoreWebView2Settings2),
                          reinterpret_cast<void**>(&settings2))) &&
                      settings2 != nullptr) {
                    settings2->put_UserAgent(kChromeUserAgent);
                    settings2->Release();
                  }
                  settings->Release();
                }

                ICoreWebView2_2* webview2 = nullptr;
                if (SUCCEEDED(self->webview->QueryInterface(
                        __uuidof(ICoreWebView2_2),
                        reinterpret_cast<void**>(&webview2))) &&
                    webview2 != nullptr) {
                  webview2->get_CookieManager(&self->cookie_manager);
                  webview2->Release();
                }

                if (self->request.clear_session &&
                    self->cookie_manager != nullptr) {
                  self->cookie_manager->DeleteAllCookies();
                }

                if (!self->request.header_url_substrings.empty()) {
                  self->webview->AddWebResourceRequestedFilter(
                      L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
                  auto* res_handler =
                      new (std::nothrow) WebResourceRequestedHandler(
                          [self](ICoreWebView2* /*sender*/,
                                 ICoreWebView2WebResourceRequestedEventArgs*
                                     args) -> HRESULT {
                            self->HandleWebResourceRequested(args);
                            return S_OK;
                          });
                  if (res_handler != nullptr) {
                    if (SUCCEEDED(self->webview->add_WebResourceRequested(
                            res_handler, &self->web_resource_token))) {
                      self->has_resource_token = true;
                    }
                    res_handler->Release();
                  }
                }

                auto* nav_handler =
                    new (std::nothrow) NavigationCompletedHandler(
                        [self](ICoreWebView2* /*sender*/,
                               ICoreWebView2NavigationCompletedEventArgs*
                               /*args*/) -> HRESULT {
                          self->PollCookies();
                          return S_OK;
                        });
                if (nav_handler != nullptr) {
                  if (SUCCEEDED(self->webview->add_NavigationCompleted(
                          nav_handler, &self->nav_completed_token))) {
                    self->has_nav_token = true;
                  }
                  nav_handler->Release();
                }

                ::SetTimer(self->hwnd, kCookiePollTimerId,
                           kCookiePollIntervalMs, nullptr);

                const HRESULT nav_hr =
                    self->webview->Navigate(self->request.initial_url.c_str());
                if (FAILED(nav_hr)) {
                  WebViewAuthResult res;
                  res.error = "Failed to navigate to login URL";
                  self->FinishWithResult(res);
                }
                return S_OK;
              });
          if (ctrl_handler == nullptr) {
            WebViewAuthResult res;
            res.error = "Out of memory creating WebView2 controller handler";
            self->FinishWithResult(res);
            return S_OK;
          }
          const HRESULT ch_hr =
              env->CreateCoreWebView2Controller(self->hwnd, ctrl_handler);
          ctrl_handler->Release();
          if (FAILED(ch_hr)) {
            WebViewAuthResult res;
            res.error = "CreateCoreWebView2Controller call failed";
            self->FinishWithResult(res);
          }
          return S_OK;
        });

    if (env_handler == nullptr) {
      WebViewAuthResult res;
      res.error = "Out of memory creating WebView2 environment handler";
      FinishWithResult(res);
      return;
    }

    const HRESULT env_hr = create_env_fn(
        nullptr, user_data_dir.c_str(), nullptr, env_handler);
    env_handler->Release();
    if (FAILED(env_hr)) {
      WebViewAuthResult res;
      res.error = "CreateCoreWebView2EnvironmentWithOptions failed";
      FinishWithResult(res);
    }
  }

  static LRESULT CALLBACK WndProc(HWND window,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam) noexcept {
    if (message == WM_NCCREATE) {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      auto* self = static_cast<Impl*>(cs->lpCreateParams);
      ::SetWindowLongPtrW(window, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(self));
      return ::DefWindowProcW(window, message, wparam, lparam);
    }

    auto* self = reinterpret_cast<Impl*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self == nullptr) {
      return ::DefWindowProcW(window, message, wparam, lparam);
    }

    switch (message) {
      case WM_SIZE:
        self->UpdateBounds();
        return 0;
      case WM_TIMER:
        if (wparam == kCookiePollTimerId) {
          self->PollCookies();
          return 0;
        }
        break;
      case WM_CLOSE: {
        WebViewAuthResult cancelled;
        cancelled.cancelled = true;
        cancelled.captured = false;
        self->FinishWithResult(cancelled);
        return 0;
      }
      case WM_NCDESTROY: {
        ::SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        const HWND parent = self->parent_hwnd;
        const UINT notify_msg = self->closed_notify_msg;
        self->hwnd = nullptr;
        if (!self->completed) {
          WebViewAuthResult cancelled;
          cancelled.cancelled = true;
          cancelled.captured = false;
          self->FinishWithResult(cancelled);
        }
        if (parent != nullptr && ::IsWindow(parent) && notify_msg != 0) {
          ::PostMessageW(parent, notify_msg, 0, 0);
        }
        return 0;
      }
      default:
        break;
    }
    return ::DefWindowProcW(window, message, wparam, lparam);
  }
#endif
};

WebViewAuthWindow::WebViewAuthWindow(std::shared_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

WebViewAuthWindow::~WebViewAuthWindow() {
  CloseCancelled();
}

bool WebViewAuthWindow::IsWebView2Available() {
#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  HMODULE loader = LoadWebView2LoaderModule();
  if (loader == nullptr) {
    return false;
  }
  auto version_fn =
      reinterpret_cast<GetAvailableCoreWebView2BrowserVersionStringFn>(
          ::GetProcAddress(
              loader, "GetAvailableCoreWebView2BrowserVersionString"));
  if (version_fn == nullptr) {
    return false;
  }
  LPWSTR version = nullptr;
  const HRESULT hr = version_fn(nullptr, &version);
  const bool ok =
      SUCCEEDED(hr) && version != nullptr && version[0] != L'\0';
  if (version != nullptr) {
    ::CoTaskMemFree(version);
  }
  return ok;
#else
  return false;
#endif
}

std::unique_ptr<WebViewAuthWindow> WebViewAuthWindow::Open(
    HWND parent_hwnd,
    const WebViewAuthRequest& request,
    CompletionCallback on_complete,
    UINT closed_notify_msg) {
#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  auto impl = std::make_shared<Impl>();
  impl->parent_hwnd = parent_hwnd;
  impl->request = request;
  impl->on_complete = std::move(on_complete);
  impl->closed_notify_msg = closed_notify_msg;
  impl->bg_brush = ::CreateSolidBrush(RGB(17, 19, 24));

  const HINSTANCE hinst = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = Impl::WndProc;
  wc.hInstance = hinst;
  wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = impl->bg_brush;
  wc.lpszClassName = kAuthWindowClassName;
  ::RegisterClassExW(&wc);

  int x = CW_USEDEFAULT;
  int y = CW_USEDEFAULT;
  RECT parent_rect{};
  if (parent_hwnd != nullptr && ::GetWindowRect(parent_hwnd, &parent_rect)) {
    const int pw = parent_rect.right - parent_rect.left;
    const int ph = parent_rect.bottom - parent_rect.top;
    x = parent_rect.left + (pw - kAuthWindowWidth) / 2;
    y = parent_rect.top + (ph - kAuthWindowHeight) / 2;
  }

  const std::wstring title =
      request.title.empty() ? L"Lumina Audio \u767B\u5165" : request.title;
  HWND popup = ::CreateWindowExW(
      WS_EX_APPWINDOW,
      kAuthWindowClassName,
      title.c_str(),
      WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
      x,
      y,
      kAuthWindowWidth,
      kAuthWindowHeight,
      parent_hwnd,
      nullptr,
      hinst,
      impl.get());

  if (popup == nullptr) {
    WebViewAuthResult err;
    err.error = "Failed to create Win32 WebView2 auth window";
    impl->FinishWithResult(err);
    return nullptr;
  }

  impl->hwnd = popup;
  const BOOL dark_mode = TRUE;
  ::DwmSetWindowAttribute(
      popup, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_mode, sizeof(dark_mode));

  ::ShowWindow(popup, SW_SHOWNORMAL);
  ::UpdateWindow(popup);
  ::SetForegroundWindow(popup);

  impl->StartWebView2();
  return std::unique_ptr<WebViewAuthWindow>(new WebViewAuthWindow(impl));
#else
  (void)parent_hwnd;
  (void)request;
  (void)closed_notify_msg;
  if (on_complete) {
    WebViewAuthResult res;
    res.error = "WebView2 SDK not available in this build";
    on_complete(res);
  }
  return nullptr;
#endif
}

void WebViewAuthWindow::CloseCancelled() {
  if (!impl_) return;
  WebViewAuthResult cancelled;
  cancelled.cancelled = true;
  cancelled.captured = false;
  impl_->FinishWithResult(cancelled);
}

void WebViewAuthWindow::CloseWithError(const std::string& error_message) {
  if (!impl_) return;
  WebViewAuthResult res;
  res.error = error_message;
  impl_->FinishWithResult(res);
}

HWND WebViewAuthWindow::Handle() const {
  return impl_ ? impl_->hwnd : nullptr;
}
