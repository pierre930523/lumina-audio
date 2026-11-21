#include "flutter_window.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cwchar>
#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

const UINT WM_TASKBARCREATED = RegisterWindowMessageW(L"TaskbarCreated");
constexpr wchar_t kDefaultNowPlayingLabel[] =
    L"Lumina Audio \u2014 \u5F85\u6A5F\u4E2D";

std::wstring Utf8ToUtf16(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int wide_len = MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (wide_len <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(wide_len), L'\0');
  int converted = MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
      wide.data(), wide_len);
  if (converted <= 0) {
    return std::wstring();
  }
  return wide;
}

void CopyTrayTooltip(wchar_t (&dest)[128], const std::wstring& src) {
  constexpr size_t kMaxChars = 127;
  size_t len = std::min(src.size(), kMaxChars);
  if (len == kMaxChars && IS_HIGH_SURROGATE(src[len - 1])) {
    --len;
  }
  if (len > 0) {
    wmemcpy(dest, src.data(), len);
  }
  dest[len] = L'\0';
}

bool IsHttpOrHttpsUrl(const std::string& url) {
  if (url.empty()) {
    return false;
  }
  for (unsigned char ch : url) {
    if (ch == '\0' || ch == '\r' || ch == '\n' || ch < 0x20) {
      return false;
    }
  }
  auto equals_ci = [](char a, char b) {
    return std::tolower(static_cast<unsigned char>(a)) ==
           std::tolower(static_cast<unsigned char>(b));
  };
  auto starts_with_ci = [&](const char* prefix, size_t prefix_len) {
    if (url.size() <= prefix_len) {
      return false;
    }
    for (size_t i = 0; i < prefix_len; ++i) {
      if (!equals_ci(url[i], prefix[i])) {
        return false;
      }
    }
    return true;
  };
  return starts_with_ci("http://", 7) || starts_with_ci("https://", 8);
}

std::string Base64Encode(const BYTE* data, DWORD len) {
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((static_cast<size_t>(len) + 2) / 3) * 4);
  for (DWORD i = 0; i < len; i += 3) {
    const uint32_t b0 = data[i];
    const uint32_t b1 = (i + 1 < len) ? data[i + 1] : 0;
    const uint32_t b2 = (i + 2 < len) ? data[i + 2] : 0;
    const uint32_t triple = (b0 << 16) | (b1 << 8) | b2;
    out.push_back(kAlphabet[(triple >> 18) & 0x3F]);
    out.push_back(kAlphabet[(triple >> 12) & 0x3F]);
    out.push_back((i + 1 < len) ? kAlphabet[(triple >> 6) & 0x3F] : '=');
    out.push_back((i + 2 < len) ? kAlphabet[triple & 0x3F] : '=');
  }
  return out;
}

bool Base64Decode(const std::string& input, std::vector<BYTE>* out) {
  if (out == nullptr) {
    return false;
  }
  out->clear();
  std::string clean;
  clean.reserve(input.size());
  for (unsigned char ch : input) {
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
      continue;
    }
    clean.push_back(static_cast<char>(ch));
  }
  if (clean.empty() || (clean.size() % 4) != 0) {
    return false;
  }

  auto decode_char = [](unsigned char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };

  out->reserve((clean.size() / 4) * 3);
  for (size_t i = 0; i < clean.size(); i += 4) {
    const char c0 = clean[i];
    const char c1 = clean[i + 1];
    const char c2 = clean[i + 2];
    const char c3 = clean[i + 3];
    if (c0 == '=' || c1 == '=') {
      return false;
    }
    const int v0 = decode_char(static_cast<unsigned char>(c0));
    const int v1 = decode_char(static_cast<unsigned char>(c1));
    if (v0 < 0 || v1 < 0) {
      return false;
    }
    const bool pad2 = (c2 == '=');
    const bool pad3 = (c3 == '=');
    if (pad2 && !pad3) {
      return false;
    }
    if ((pad2 || pad3) && (i + 4 != clean.size())) {
      return false;
    }
    const int v2 = pad2 ? 0 : decode_char(static_cast<unsigned char>(c2));
    const int v3 = pad3 ? 0 : decode_char(static_cast<unsigned char>(c3));
    if (v2 < 0 || v3 < 0) {
      return false;
    }

    const uint32_t triple = (static_cast<uint32_t>(v0) << 18) |
                            (static_cast<uint32_t>(v1) << 12) |
                            (static_cast<uint32_t>(v2) << 6) |
                            static_cast<uint32_t>(v3);
    out->push_back(static_cast<BYTE>((triple >> 16) & 0xFF));
    if (!pad2) {
      out->push_back(static_cast<BYTE>((triple >> 8) & 0xFF));
    }
    if (!pad3) {
      out->push_back(static_cast<BYTE>(triple & 0xFF));
    }
  }
  return true;
}

std::optional<std::string> FindMapString(const flutter::EncodableMap& map,
                                         const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end()) {
    if (const auto* val = std::get_if<std::string>(&it->second)) {
      return *val;
    }
  }
  return std::nullopt;
}

std::optional<bool> FindMapBool(const flutter::EncodableMap& map,
                                const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end()) {
    if (const auto* val = std::get_if<bool>(&it->second)) {
      return *val;
    }
  }
  return std::nullopt;
}

std::optional<std::string> ExtractStringArg(
    const flutter::EncodableValue* args,
    const char* primary_key,
    const char* secondary_key = nullptr) {
  if (args == nullptr) {
    return std::nullopt;
  }
  if (const auto* val = std::get_if<std::string>(args)) {
    return *val;
  }
  if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
    if (primary_key != nullptr) {
      if (auto s = FindMapString(*map, primary_key)) {
        return s;
      }
    }
    if (secondary_key != nullptr) {
      if (auto s = FindMapString(*map, secondary_key)) {
        return s;
      }
    }
  }
  return std::nullopt;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "lumina/window",
          &flutter::StandardMethodCodec::GetInstance());

  HWND hwnd = GetHandle();

  window_channel_->SetMethodCallHandler(
      [this, hwnd](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        const std::string& method = call.method_name();
        if (method == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "maximize") {
          ShowWindow(hwnd, SW_MAXIMIZE);
          result->Success();
        } else if (method == "restore") {
          ShowWindow(hwnd, SW_RESTORE);
          result->Success();
        } else if (method == "unmaximize") {
          ShowWindow(hwnd, SW_RESTORE);
          result->Success();
        } else if (method == "toggleMaximize") {
          if (IsZoomed(hwnd)) {
            ShowWindow(hwnd, SW_RESTORE);
          } else {
            ShowWindow(hwnd, SW_MAXIMIZE);
          }
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else if (method == "isFullScreen") {
          result->Success(flutter::EncodableValue(IsFullScreen()));
        } else if (method == "setFullScreen") {
          bool target = false;
          if (call.arguments()) {
            if (const auto* val = std::get_if<bool>(call.arguments())) {
              target = *val;
            }
          }
          SetFullScreen(target);
          result->Success();
        } else if (method == "toggleFullScreen") {
          SetFullScreen(!IsFullScreen());
          result->Success();
        } else if (method == "getBounds") {
          RECT rect;
          GetWindowRect(hwnd, &rect);
          flutter::EncodableMap bounds_map;
          bounds_map[flutter::EncodableValue("x")] =
              flutter::EncodableValue(static_cast<double>(rect.left));
          bounds_map[flutter::EncodableValue("y")] =
              flutter::EncodableValue(static_cast<double>(rect.top));
          bounds_map[flutter::EncodableValue("width")] =
              flutter::EncodableValue(static_cast<double>(rect.right - rect.left));
          bounds_map[flutter::EncodableValue("height")] =
              flutter::EncodableValue(static_cast<double>(rect.bottom - rect.top));
          result->Success(flutter::EncodableValue(bounds_map));
        } else if (method == "setBounds") {
          if (call.arguments()) {
            if (const auto* map =
                    std::get_if<flutter::EncodableMap>(call.arguments())) {
              auto get_double = [map](const std::string& key) -> double {
                auto it = map->find(flutter::EncodableValue(key));
                if (it != map->end()) {
                  if (const auto* val = std::get_if<double>(&it->second)) {
                    return *val;
                  }
                  if (const auto* val = std::get_if<int32_t>(&it->second)) {
                    return static_cast<double>(*val);
                  }
                  if (const auto* val = std::get_if<int64_t>(&it->second)) {
                    return static_cast<double>(*val);
                  }
                }
                return 0.0;
              };
              int x = static_cast<int>(get_double("x"));
              int y = static_cast<int>(get_double("y"));
              int w = static_cast<int>(get_double("width"));
              int h = static_cast<int>(get_double("height"));
              if (w > 0 && h > 0) {
                SetWindowPos(hwnd, nullptr, x, y, w, h,
                             SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
              }
            }
          }
          result->Success();
        } else if (method == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "startDragging") {
          POINT pt;
          GetCursorPos(&pt);
          ReleaseCapture();
          SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(pt.x, pt.y));
          result->Success();
        } else if (method == "setPreventClose") {
          bool prevent = false;
          if (call.arguments()) {
            if (const auto* val = std::get_if<bool>(call.arguments())) {
              prevent = *val;
            }
          }
          SetPreventClose(prevent);
          result->Success();
        } else if (method == "hide") {
          Hide();
          result->Success();
        } else if (method == "show") {
          ShowAndFocus();
          result->Success();
        } else if (method == "focus") {
          if (IsIconic(hwnd)) {
            ShowWindow(hwnd, SW_RESTORE);
          }
          SetForegroundWindow(hwnd);
          SetActiveWindow(hwnd);
          result->Success();
        } else if (method == "destroy") {
          DestroyTray();
          result->Success();
          if (hwnd != nullptr && IsWindow(hwnd)) {
            PostMessage(hwnd, kForceDestroyMessage, 0, 0);
          } else {
            ForceDestroy();
          }
        } else if (method == "trayInit") {
          UpdateTrayFromArgs(call.arguments());
          InitTray();
          result->Success();
        } else if (method == "trayUpdate") {
          UpdateTrayFromArgs(call.arguments());
          result->Success();
        } else if (method == "trayDestroy") {
          DestroyTray();
          result->Success();
        } else if (method == "openUrl") {
          auto url_opt = ExtractStringArg(call.arguments(), "url");
          if (!url_opt.has_value() || !IsHttpOrHttpsUrl(*url_opt)) {
            result->Error("INVALID_URL",
                          "Only http:// and https:// URLs are allowed");
            return;
          }
          std::wstring wurl = Utf8ToUtf16(*url_opt);
          if (wurl.empty()) {
            result->Error("INVALID_URL", "Failed to convert URL to UTF-16");
            return;
          }
          HINSTANCE exec_res = ShellExecuteW(
              nullptr, L"open", wurl.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
          if (reinterpret_cast<INT_PTR>(exec_res) <= 32) {
            result->Error("OPEN_URL_FAILED", "ShellExecuteW failed");
            return;
          }
          result->Success(flutter::EncodableValue(true));
        } else if (method == "dpapiProtect") {
          auto plain_opt =
              ExtractStringArg(call.arguments(), "plaintext", "data");
          if (!plain_opt.has_value()) {
            result->Error("INVALID_ARGS", "Expected String plaintext");
            return;
          }
          BYTE empty_byte = 0;
          DATA_BLOB in_blob{};
          in_blob.cbData = static_cast<DWORD>(plain_opt->size());
          in_blob.pbData =
              plain_opt->empty()
                  ? &empty_byte
                  : reinterpret_cast<BYTE*>(const_cast<char*>(plain_opt->data()));
          DATA_BLOB out_blob{};
          if (!CryptProtectData(&in_blob, L"LuminaAudio", nullptr, nullptr,
                                nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out_blob)) {
            result->Error("DPAPI_PROTECT_FAILED",
                          "CryptProtectData failed: " +
                              std::to_string(GetLastError()));
            return;
          }
          std::string encoded = Base64Encode(out_blob.pbData, out_blob.cbData);
          if (out_blob.pbData != nullptr) {
            LocalFree(out_blob.pbData);
          }
          result->Success(flutter::EncodableValue(encoded));
        } else if (method == "dpapiUnprotect") {
          auto cipher_opt =
              ExtractStringArg(call.arguments(), "ciphertext", "data");
          if (!cipher_opt.has_value()) {
            result->Error("INVALID_ARGS",
                          "Expected Base64 ciphertext string");
            return;
          }
          std::vector<BYTE> cipher_bytes;
          if (!Base64Decode(*cipher_opt, &cipher_bytes) ||
              cipher_bytes.empty()) {
            result->Error("DPAPI_DECODE_FAILED", "Invalid Base64 ciphertext");
            return;
          }
          DATA_BLOB in_blob{};
          in_blob.cbData = static_cast<DWORD>(cipher_bytes.size());
          in_blob.pbData = cipher_bytes.data();
          DATA_BLOB out_blob{};
          if (!CryptUnprotectData(&in_blob, nullptr, nullptr, nullptr, nullptr,
                                  CRYPTPROTECT_UI_FORBIDDEN, &out_blob)) {
            result->Error("DPAPI_UNPROTECT_FAILED",
                          "CryptUnprotectData failed: " +
                              std::to_string(GetLastError()));
            return;
          }
          std::string plaintext;
          if (out_blob.pbData != nullptr) {
            if (out_blob.cbData > 0) {
              plaintext.assign(reinterpret_cast<const char*>(out_blob.pbData),
                               out_blob.cbData);
              SecureZeroMemory(out_blob.pbData, out_blob.cbData);
            }
            LocalFree(out_blob.pbData);
          }
          result->Success(flutter::EncodableValue(plaintext));
        } else if (method == "isWebView2Available") {
          result->Success(flutter::EncodableValue(
              WebViewAuthWindow::IsWebView2Available()));
        } else if (method == "closeWebViewAuth") {
          if (webview_auth_window_) {
            webview_auth_window_->CloseCancelled();
            webview_auth_window_.reset();
          }
          result->Success();
        } else if (method == "openWebViewAuth") {
          if (webview_auth_window_) {
            webview_auth_window_->CloseCancelled();
            webview_auth_window_.reset();
          }

          WebViewAuthRequest req;
          if (call.arguments()) {
            if (const auto* map =
                    std::get_if<flutter::EncodableMap>(call.arguments())) {
              auto get_str = [map](const char* key) -> std::string {
                auto it = map->find(flutter::EncodableValue(key));
                if (it != map->end()) {
                  if (const auto* s = std::get_if<std::string>(&it->second)) {
                    return *s;
                  }
                }
                return std::string();
              };
              auto get_bool = [map](const char* key) -> bool {
                auto it = map->find(flutter::EncodableValue(key));
                if (it != map->end()) {
                  if (const auto* b = std::get_if<bool>(&it->second)) {
                    return *b;
                  }
                }
                return false;
              };
              auto get_wlist = [map](const char* key)
                  -> std::vector<std::wstring> {
                std::vector<std::wstring> out;
                auto it = map->find(flutter::EncodableValue(key));
                if (it != map->end()) {
                  if (const auto* list =
                          std::get_if<flutter::EncodableList>(&it->second)) {
                    for (const auto& item : *list) {
                      if (const auto* s = std::get_if<std::string>(&item)) {
                        if (!s->empty()) {
                          out.push_back(Utf8ToUtf16(*s));
                        }
                      }
                    }
                  }
                }
                return out;
              };
              auto get_wgroups = [map](const char* key)
                  -> std::vector<std::vector<std::wstring>> {
                std::vector<std::vector<std::wstring>> out;
                auto it = map->find(flutter::EncodableValue(key));
                if (it != map->end()) {
                  if (const auto* outer =
                          std::get_if<flutter::EncodableList>(&it->second)) {
                    for (const auto& inner_val : *outer) {
                      if (const auto* inner =
                              std::get_if<flutter::EncodableList>(&inner_val)) {
                        std::vector<std::wstring> group;
                        for (const auto& item : *inner) {
                          if (const auto* s =
                                  std::get_if<std::string>(&item)) {
                            if (!s->empty()) {
                              group.push_back(Utf8ToUtf16(*s));
                            }
                          }
                        }
                        if (!group.empty()) {
                          out.push_back(std::move(group));
                        }
                      }
                    }
                  }
                }
                return out;
              };

              std::string url = get_str("initialUrl");
              if (url.empty()) {
                url = get_str("url");
              }
              if (!IsHttpOrHttpsUrl(url)) {
                flutter::EncodableMap err_map;
                err_map[flutter::EncodableValue("captured")] =
                    flutter::EncodableValue(false);
                err_map[flutter::EncodableValue("cancelled")] =
                    flutter::EncodableValue(false);
                err_map[flutter::EncodableValue("cookieHeader")] =
                    flutter::EncodableValue("");
                err_map[flutter::EncodableValue("cookies")] =
                    flutter::EncodableValue(flutter::EncodableMap());
                err_map[flutter::EncodableValue("headers")] =
                    flutter::EncodableValue(flutter::EncodableMap());
                err_map[flutter::EncodableValue("queryParams")] =
                    flutter::EncodableValue(flutter::EncodableMap());
                err_map[flutter::EncodableValue("capturedUrl")] =
                    flutter::EncodableValue("");
                err_map[flutter::EncodableValue("error")] =
                    flutter::EncodableValue("Invalid auth URL scheme");
                result->Success(flutter::EncodableValue(err_map));
                return;
              }
              req.initial_url = Utf8ToUtf16(url);
              req.title = Utf8ToUtf16(get_str("title"));
              req.cookie_domain = Utf8ToUtf16(get_str("cookieDomain"));
              req.required_host_substring =
                  Utf8ToUtf16(get_str("requiredHostSubstring"));
              req.excluded_url_substrings = get_wlist("excludedUrlSubstrings");
              req.required_any_cookies = get_wlist("requiredAnyCookies");
              req.required_all_cookies = get_wlist("requiredAllCookies");
              req.header_url_substrings = get_wlist("headerUrlSubstrings");
              req.capture_header_names = get_wlist("captureHeaderNames");
              req.capture_query_params = get_wlist("captureQueryParams");
              req.required_headers = get_wlist("requiredHeaders");
              req.required_groups = get_wgroups("requiredGroups");
              req.clear_session = get_bool("clearSession");
            }
          }

          if (req.initial_url.empty()) {
            flutter::EncodableMap err_map;
            err_map[flutter::EncodableValue("captured")] =
                flutter::EncodableValue(false);
            err_map[flutter::EncodableValue("cancelled")] =
                flutter::EncodableValue(false);
            err_map[flutter::EncodableValue("cookieHeader")] =
                flutter::EncodableValue("");
            err_map[flutter::EncodableValue("cookies")] =
                flutter::EncodableValue(flutter::EncodableMap());
            err_map[flutter::EncodableValue("headers")] =
                flutter::EncodableValue(flutter::EncodableMap());
            err_map[flutter::EncodableValue("queryParams")] =
                flutter::EncodableValue(flutter::EncodableMap());
            err_map[flutter::EncodableValue("capturedUrl")] =
                flutter::EncodableValue("");
            err_map[flutter::EncodableValue("error")] =
                flutter::EncodableValue("Missing initialUrl for openWebViewAuth");
            result->Success(flutter::EncodableValue(err_map));
            return;
          }

          std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>
              shared_result(std::move(result));
          webview_auth_window_ = WebViewAuthWindow::Open(
              hwnd, req,
              [shared_result](const WebViewAuthResult& res) {
                flutter::EncodableMap cookies_map;
                for (const auto& kv : res.cookies) {
                  cookies_map[flutter::EncodableValue(kv.first)] =
                      flutter::EncodableValue(kv.second);
                }
                flutter::EncodableMap headers_map;
                for (const auto& kv : res.headers) {
                  headers_map[flutter::EncodableValue(kv.first)] =
                      flutter::EncodableValue(kv.second);
                }
                flutter::EncodableMap query_map;
                for (const auto& kv : res.query_params) {
                  query_map[flutter::EncodableValue(kv.first)] =
                      flutter::EncodableValue(kv.second);
                }
                flutter::EncodableMap payload;
                payload[flutter::EncodableValue("captured")] =
                    flutter::EncodableValue(res.captured);
                payload[flutter::EncodableValue("cancelled")] =
                    flutter::EncodableValue(res.cancelled);
                payload[flutter::EncodableValue("cookieHeader")] =
                    flutter::EncodableValue(res.cookie_header);
                payload[flutter::EncodableValue("cookies")] =
                    flutter::EncodableValue(cookies_map);
                payload[flutter::EncodableValue("headers")] =
                    flutter::EncodableValue(headers_map);
                payload[flutter::EncodableValue("queryParams")] =
                    flutter::EncodableValue(query_map);
                payload[flutter::EncodableValue("capturedUrl")] =
                    flutter::EncodableValue(res.captured_url);
                payload[flutter::EncodableValue("error")] =
                    res.error.empty()
                        ? flutter::EncodableValue()
                        : flutter::EncodableValue(res.error);
                shared_result->Success(flutter::EncodableValue(payload));
              },
              kWebViewAuthClosedMessage);
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (webview_auth_window_) {
    webview_auth_window_->CloseCancelled();
    webview_auth_window_.reset();
  }
  DestroyTray();
  if (window_channel_) {
    window_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnDisplayOrDpiChanged() {
  if (flutter_controller_) {
    SyncChildContentBounds();
    flutter_controller_->ForceRedraw();
  }
}

bool FlutterWindow::OnWindowCloseRequested() {
  if (window_channel_) {
    window_channel_->InvokeMethod("onWindowClose", nullptr);
    return true;
  }
  return false;
}

void FlutterWindow::InitTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  if (tray_icon_ == nullptr) {
    tray_icon_ =
        LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  }

  ZeroMemory(&tray_nid_, sizeof(tray_nid_));
  tray_nid_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_nid_.hWnd = hwnd;
  tray_nid_.uID = 1;
  tray_nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_nid_.uCallbackMessage = kTrayCallbackMessage;
  tray_nid_.hIcon = tray_icon_;
  CopyTrayTooltip(tray_nid_.szTip,
                  tray_tooltip_.empty() ? L"Lumina Audio" : tray_tooltip_);

  if (tray_active_) {
    if (!Shell_NotifyIconW(NIM_MODIFY, &tray_nid_)) {
      Shell_NotifyIconW(NIM_ADD, &tray_nid_);
    }
    return;
  }

  if (Shell_NotifyIconW(NIM_ADD, &tray_nid_)) {
    tray_active_ = true;
  }
}

void FlutterWindow::UpdateTray(const std::string& tooltip_utf8,
                               const std::string& now_playing_label_utf8,
                               bool is_playing) {
  if (!tooltip_utf8.empty()) {
    std::wstring wtip = Utf8ToUtf16(tooltip_utf8);
    if (!wtip.empty()) {
      tray_tooltip_ = std::move(wtip);
    }
  }
  if (!now_playing_label_utf8.empty()) {
    std::wstring wlabel = Utf8ToUtf16(now_playing_label_utf8);
    if (!wlabel.empty()) {
      now_playing_label_ = std::move(wlabel);
    }
  }
  tray_is_playing_ = is_playing;

  if (tray_active_) {
    tray_nid_.uFlags = NIF_TIP;
    CopyTrayTooltip(tray_nid_.szTip,
                    tray_tooltip_.empty() ? L"Lumina Audio" : tray_tooltip_);
    if (!Shell_NotifyIconW(NIM_MODIFY, &tray_nid_)) {
      tray_nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
      Shell_NotifyIconW(NIM_ADD, &tray_nid_);
    }
  }
}

void FlutterWindow::UpdateTrayFromArgs(const flutter::EncodableValue* args) {
  std::string tooltip_utf8;
  std::string label_utf8;
  bool is_playing = tray_is_playing_;

  if (args != nullptr) {
    if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
      if (auto tip = FindMapString(*map, "tooltip")) {
        tooltip_utf8 = *tip;
      }
      if (auto label = FindMapString(*map, "nowPlayingLabel")) {
        if (label->empty()) {
          now_playing_label_ = kDefaultNowPlayingLabel;
        } else {
          label_utf8 = *label;
        }
      }
      if (auto playing = FindMapBool(*map, "isPlaying")) {
        is_playing = *playing;
      }
    }
  }

  UpdateTray(tooltip_utf8, label_utf8, is_playing);
}

void FlutterWindow::DestroyTray() {
  if (tray_active_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_nid_);
    tray_active_ = false;
  }
}

void FlutterWindow::ShowTrayContextMenu(HWND hwnd) {
  if (tray_menu_open_ || hwnd == nullptr) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  tray_menu_open_ = true;

  const std::wstring& status_label =
      now_playing_label_.empty() ? std::wstring(kDefaultNowPlayingLabel)
                                 : now_playing_label_;
  AppendMenuW(menu, MF_STRING | MF_GRAYED | MF_DISABLED, 0,
              status_label.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayMenuShow,
              L"\u986F\u793A Lumina Audio");
  AppendMenuW(menu, MF_STRING, kTrayMenuPlayPause,
              tray_is_playing_ ? L"\u66AB\u505C" : L"\u64AD\u653E");
  AppendMenuW(menu, MF_STRING, kTrayMenuPrev, L"\u4E0A\u4E00\u9996");
  AppendMenuW(menu, MF_STRING, kTrayMenuNext, L"\u4E0B\u4E00\u9996");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayMenuQuit,
              L"\u5B8C\u5168\u7D50\u675F Lumina Audio");

  SetForegroundWindow(hwnd);
  POINT pt{};
  GetCursorPos(&pt);
  UINT cmd = static_cast<UINT>(TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, hwnd,
      nullptr));
  PostMessage(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);

  tray_menu_open_ = false;

  if (cmd != 0 && window_channel_) {
    std::string action;
    switch (cmd) {
      case kTrayMenuShow:
        action = "show";
        break;
      case kTrayMenuPlayPause:
        action = "toggle_play_pause";
        break;
      case kTrayMenuPrev:
        action = "previous";
        break;
      case kTrayMenuNext:
        action = "next";
        break;
      case kTrayMenuQuit:
        action = "quit";
        break;
      default:
        break;
    }
    if (!action.empty()) {
      window_channel_->InvokeMethod(
          "onTrayMenuAction", std::make_unique<flutter::EncodableValue>(action));
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (WM_TASKBARCREATED != 0 && message == WM_TASKBARCREATED) {
    if (tray_active_) {
      tray_nid_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
      Shell_NotifyIconW(NIM_ADD, &tray_nid_);
    }
    return 0;
  }

  if (message == kForceDestroyMessage) {
    ForceDestroy();
    return 0;
  }

  if (message == kWebViewAuthClosedMessage) {
    webview_auth_window_.reset();
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;

    case kTrayCallbackMessage: {
      const UINT tray_event = LOWORD(static_cast<DWORD>(lparam));
      if (tray_event == WM_LBUTTONUP || tray_event == WM_LBUTTONDBLCLK) {
        if (window_channel_) {
          window_channel_->InvokeMethod("onTrayClick", nullptr);
        }
        return 0;
      }
      if (tray_event == WM_RBUTTONUP || tray_event == WM_CONTEXTMENU) {
        ShowTrayContextMenu(hwnd);
        return 0;
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
