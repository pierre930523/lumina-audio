#include "external_music_host.h"

#include <objbase.h>
#include <shlobj.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <deque>
#include <map>
#include <mutex>
#include <new>
#include <utility>

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
#include <WebView2.h>
#endif

namespace {

constexpr UINT kDispatchUiQueueMessage = WM_APP + 11;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int len = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
      nullptr, 0, nullptr, nullptr);
  if (len <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(len), '\0');
  const int written = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
      utf8.data(), len, nullptr, nullptr);
  if (written <= 0) {
    return std::string();
  }
  return utf8;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int len = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(len), L'\0');
  const int written = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
      wide.data(), len);
  if (written <= 0) {
    return std::wstring();
  }
  return wide;
}

constexpr wchar_t kHostWindowClassName[] =
    L"LUMINA_WEBVIEW2_EXTERNAL_MUSIC_HOST";
constexpr wchar_t kBridgeUrl[] =
    L"https://lumina-external.music.apple.local/player.html";
constexpr char kBridgeOriginPrefix[] =
    "https://lumina-external.music.apple.local/";
constexpr wchar_t kChromeUserAgent[] =
    L"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    L"(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

bool IsTerminalOrSupportedStatus(const std::string& status) {
  return status == "loading" || status == "playing" || status == "paused" ||
         status == "stopped" || status == "ended" || status == "error";
}

std::string ToLowerAscii(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char ch) {
    return static_cast<char>(std::tolower(ch));
  });
  return s;
}

bool StartsWithCaseInsensitive(const std::string& text, const char* prefix) {
  if (prefix == nullptr) {
    return false;
  }
  const size_t prefix_len = std::strlen(prefix);
  if (text.size() < prefix_len) {
    return false;
  }
  for (size_t i = 0; i < prefix_len; ++i) {
    if (std::tolower(static_cast<unsigned char>(text[i])) !=
        std::tolower(static_cast<unsigned char>(prefix[i]))) {
      return false;
    }
  }
  return true;
}

std::string JsonEscape(const std::string& input) {
  std::string out;
  out.reserve(input.size() + 8);
  for (unsigned char ch : input) {
    switch (ch) {
      case '"':
        out.append("\\\"");
        break;
      case '\\':
        out.append("\\\\");
        break;
      case '\b':
        out.append("\\b");
        break;
      case '\f':
        out.append("\\f");
        break;
      case '\n':
        out.append("\\n");
        break;
      case '\r':
        out.append("\\r");
        break;
      case '\t':
        out.append("\\t");
        break;
      default:
        if (ch < 0x20) {
          char hex_buf[8] = {};
          std::snprintf(hex_buf, sizeof(hex_buf), "\\u%04x",
                        static_cast<unsigned int>(ch));
          out.append(hex_buf);
        } else {
          out.push_back(static_cast<char>(ch));
        }
        break;
    }
  }
  return out;
}

std::string FormatDoubleJson(double val) {
  if (!std::isfinite(val)) {
    return "0";
  }
  char buf[32] = {};
  std::snprintf(buf, sizeof(buf), "%.4f", val);
  std::string out(buf);
  for (char& ch : out) {
    if (ch == ',') {
      ch = '.';
    }
  }
  return out;
}

struct JsonFlatValue {
  enum class Kind {
    kNull,
    kBool,
    kNumber,
    kString,
  };

  Kind kind = Kind::kNull;
  bool bool_val = false;
  int64_t int_val = 0;
  double number_val = 0.0;
  std::string string_val;
};

void AppendUtf8CodePoint(uint32_t cp, std::string* out) {
  if (out == nullptr) {
    return;
  }
  if (cp <= 0x7F) {
    out->push_back(static_cast<char>(cp));
  } else if (cp <= 0x7FF) {
    out->push_back(static_cast<char>(0xC0 | ((cp >> 6) & 0x1F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp <= 0xFFFF) {
    out->push_back(static_cast<char>(0xE0 | ((cp >> 12) & 0x0F)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp <= 0x10FFFF) {
    out->push_back(static_cast<char>(0xF0 | ((cp >> 18) & 0x07)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

bool ParseHex4(const std::string& src, size_t pos, uint32_t* out_val) {
  if (out_val == nullptr || pos + 4 > src.size()) {
    return false;
  }
  uint32_t acc = 0;
  for (size_t i = 0; i < 4; ++i) {
    const unsigned char c = static_cast<unsigned char>(src[pos + i]);
    uint32_t nibble = 0;
    if (c >= '0' && c <= '9') {
      nibble = static_cast<uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      nibble = static_cast<uint32_t>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      nibble = static_cast<uint32_t>(c - 'A' + 10);
    } else {
      return false;
    }
    acc = (acc << 4) | nibble;
  }
  *out_val = acc;
  return true;
}

void SkipJsonWhitespace(const std::string& src, size_t* pos) {
  while (*pos < src.size()) {
    const unsigned char ch = static_cast<unsigned char>(src[*pos]);
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
      ++(*pos);
    } else {
      break;
    }
  }
}

bool ParseJsonString(const std::string& src, size_t* pos, std::string* out) {
  if (*pos >= src.size() || src[*pos] != '"') {
    return false;
  }
  ++(*pos);
  out->clear();
  while (*pos < src.size()) {
    const char ch = src[*pos];
    ++(*pos);
    if (ch == '"') {
      return true;
    }
    if (ch != '\\') {
      out->push_back(ch);
      continue;
    }
    if (*pos >= src.size()) {
      return false;
    }
    const char esc = src[*pos];
    ++(*pos);
    switch (esc) {
      case '"':
        out->push_back('"');
        break;
      case '\\':
        out->push_back('\\');
        break;
      case '/':
        out->push_back('/');
        break;
      case 'b':
        out->push_back('\b');
        break;
      case 'f':
        out->push_back('\f');
        break;
      case 'n':
        out->push_back('\n');
        break;
      case 'r':
        out->push_back('\r');
        break;
      case 't':
        out->push_back('\t');
        break;
      case 'u': {
        uint32_t cp = 0;
        if (!ParseHex4(src, *pos, &cp)) {
          return false;
        }
        *pos += 4;
        if (cp >= 0xD800 && cp <= 0xDBFF && *pos + 6 <= src.size() &&
            src[*pos] == '\\' && src[*pos + 1] == 'u') {
          uint32_t low = 0;
          if (ParseHex4(src, *pos + 2, &low) && low >= 0xDC00 &&
              low <= 0xDFFF) {
            cp = 0x10000 + (((cp - 0xD800) << 10) | (low - 0xDC00));
            *pos += 6;
          }
        }
        AppendUtf8CodePoint(cp, out);
        break;
      }
      default:
        return false;
    }
  }
  return false;
}

bool SkipNestedJsonValue(const std::string& src, size_t* pos, int depth) {
  if (depth > 16) {
    return false;
  }
  SkipJsonWhitespace(src, pos);
  if (*pos >= src.size()) {
    return false;
  }
  const char open = src[*pos];
  if (open == '"') {
    std::string ignored;
    return ParseJsonString(src, pos, &ignored);
  }
  if (open != '{' && open != '[') {
    while (*pos < src.size()) {
      const char ch = src[*pos];
      if (ch == ',' || ch == '}' || ch == ']' || ch == ' ' || ch == '\t' ||
          ch == '\r' || ch == '\n') {
        return true;
      }
      ++(*pos);
    }
    return true;
  }
  const char close = (open == '{') ? '}' : ']';
  ++(*pos);
  SkipJsonWhitespace(src, pos);
  if (*pos < src.size() && src[*pos] == close) {
    ++(*pos);
    return true;
  }
  for (;;) {
    if (open == '{') {
      SkipJsonWhitespace(src, pos);
      std::string ignored_key;
      if (!ParseJsonString(src, pos, &ignored_key)) {
        return false;
      }
      SkipJsonWhitespace(src, pos);
      if (*pos >= src.size() || src[*pos] != ':') {
        return false;
      }
      ++(*pos);
    }
    if (!SkipNestedJsonValue(src, pos, depth + 1)) {
      return false;
    }
    SkipJsonWhitespace(src, pos);
    if (*pos >= src.size()) {
      return false;
    }
    if (src[*pos] == close) {
      ++(*pos);
      return true;
    }
    if (src[*pos] != ',') {
      return false;
    }
    ++(*pos);
  }
}

bool ParseFlatJsonObject(const std::string& src,
                         std::map<std::string, JsonFlatValue>* out) {
  if (out == nullptr) {
    return false;
  }
  out->clear();
  size_t pos = 0;
  SkipJsonWhitespace(src, &pos);
  if (pos >= src.size() || src[pos] != '{') {
    return false;
  }
  ++pos;
  SkipJsonWhitespace(src, &pos);
  if (pos < src.size() && src[pos] == '}') {
    return true;
  }

  for (;;) {
    SkipJsonWhitespace(src, &pos);
    std::string key;
    if (!ParseJsonString(src, &pos, &key)) {
      return false;
    }
    SkipJsonWhitespace(src, &pos);
    if (pos >= src.size() || src[pos] != ':') {
      return false;
    }
    ++pos;
    SkipJsonWhitespace(src, &pos);
    if (pos >= src.size()) {
      return false;
    }

    JsonFlatValue val;
    const char ch = src[pos];
    if (ch == '"') {
      val.kind = JsonFlatValue::Kind::kString;
      if (!ParseJsonString(src, &pos, &val.string_val)) {
        return false;
      }
    } else if (src.compare(pos, 4, "true") == 0) {
      val.kind = JsonFlatValue::Kind::kBool;
      val.bool_val = true;
      pos += 4;
    } else if (src.compare(pos, 5, "false") == 0) {
      val.kind = JsonFlatValue::Kind::kBool;
      val.bool_val = false;
      pos += 5;
    } else if (src.compare(pos, 4, "null") == 0) {
      val.kind = JsonFlatValue::Kind::kNull;
      pos += 4;
    } else if (ch == '{' || ch == '[') {
      if (!SkipNestedJsonValue(src, &pos, 0)) {
        return false;
      }
    } else if (ch == '-' || (ch >= '0' && ch <= '9')) {
      const size_t start = pos;
      while (pos < src.size()) {
        const char nc = src[pos];
        if ((nc >= '0' && nc <= '9') || nc == '-' || nc == '+' || nc == '.' ||
            nc == 'e' || nc == 'E') {
          ++pos;
        } else {
          break;
        }
      }
      const std::string token = src.substr(start, pos - start);
      char* end_ptr = nullptr;
      const double d = std::strtod(token.c_str(), &end_ptr);
      if (end_ptr == token.c_str() || !std::isfinite(d)) {
        return false;
      }
      val.kind = JsonFlatValue::Kind::kNumber;
      val.number_val = d;
      if (token.find('.') == std::string::npos &&
          token.find('e') == std::string::npos &&
          token.find('E') == std::string::npos) {
        char* int_end = nullptr;
        const long long parsed_ll = std::strtoll(token.c_str(), &int_end, 10);
        if (int_end != token.c_str() && *int_end == '\0') {
          val.int_val = static_cast<int64_t>(parsed_ll);
        } else {
          val.int_val = static_cast<int64_t>(std::llround(d));
        }
      } else {
        val.int_val = static_cast<int64_t>(std::llround(d));
      }
    } else {
      return false;
    }

    (*out)[key] = std::move(val);
    SkipJsonWhitespace(src, &pos);
    if (pos >= src.size()) {
      return false;
    }
    if (src[pos] == '}') {
      return true;
    }
    if (src[pos] != ',') {
      return false;
    }
    ++pos;
  }
}

std::wstring GetExternalPlaybackUserDataFolder() {
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
  return base + L"LuminaAudio\\WebView2ExternalPlayback";
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

LPWSTR AllocCoTaskWideString(const wchar_t* src) {
  if (src == nullptr) {
    return nullptr;
  }
  const size_t len = std::wcslen(src);
  const size_t bytes = (len + 1) * sizeof(wchar_t);
  auto* mem = static_cast<LPWSTR>(::CoTaskMemAlloc(bytes));
  if (mem != nullptr) {
    std::memcpy(mem, src, bytes);
  }
  return mem;
}

class ExternalPlaybackEnvironmentOptions final
    : public ICoreWebView2EnvironmentOptions {
 public:
  explicit ExternalPlaybackEnvironmentOptions(const wchar_t* additional_args)
      : ref_count_(1),
        additional_args_(additional_args != nullptr ? additional_args : L"") {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown ||
        riid == __uuidof(ICoreWebView2EnvironmentOptions)) {
      *ppv = static_cast<ICoreWebView2EnvironmentOptions*>(this);
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
    if (next == 0) {
      delete this;
    }
    return next;
  }

  HRESULT STDMETHODCALLTYPE
  get_AdditionalBrowserArguments(LPWSTR* value) override {
    if (value == nullptr) {
      return E_POINTER;
    }
    if (additional_args_.empty()) {
      *value = nullptr;
      return S_OK;
    }
    *value = AllocCoTaskWideString(additional_args_.c_str());
    return (*value != nullptr) ? S_OK : E_OUTOFMEMORY;
  }

  HRESULT STDMETHODCALLTYPE
  put_AdditionalBrowserArguments(LPCWSTR value) override {
    additional_args_ = (value != nullptr) ? value : L"";
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_Language(LPWSTR* value) override {
    if (value == nullptr) {
      return E_POINTER;
    }
    *value = nullptr;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE put_Language(LPCWSTR /*value*/) override {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE
  get_TargetCompatibleBrowserVersion(LPWSTR* value) override {
    if (value == nullptr) {
      return E_POINTER;
    }
    *value = AllocCoTaskWideString(target_browser_version_.c_str());
    return (*value != nullptr) ? S_OK : E_OUTOFMEMORY;
  }

  HRESULT STDMETHODCALLTYPE
  put_TargetCompatibleBrowserVersion(LPCWSTR value) override {
    target_browser_version_ = (value != nullptr) ? value : L"";
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE
  get_AllowSingleSignOnUsingOSPrimaryAccount(BOOL* allow) override {
    if (allow == nullptr) {
      return E_POINTER;
    }
    *allow = FALSE;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE
  put_AllowSingleSignOnUsingOSPrimaryAccount(BOOL /*allow*/) override {
    return S_OK;
  }

 private:
  ~ExternalPlaybackEnvironmentOptions() = default;
  std::atomic<LONG> ref_count_;
  std::wstring additional_args_;
  std::wstring target_browser_version_{L"131.0.2903.40"};
};

template <typename InterfaceT, typename Arg1, typename Arg2, typename InvokeFn>
class ComCallback2 final : public InterfaceT {
 public:
  explicit ComCallback2(InvokeFn fn) : ref_count_(1), fn_(std::move(fn)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (ppv == nullptr) {
      return E_POINTER;
    }
    if (riid == IID_IUnknown || riid == __uuidof(InterfaceT)) {
      *ppv = static_cast<InterfaceT*>(this);
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
    if (next == 0) {
      delete this;
    }
    return next;
  }

  HRESULT STDMETHODCALLTYPE Invoke(Arg1 arg1, Arg2 arg2) override {
    return fn_(arg1, arg2);
  }

 private:
  ~ComCallback2() = default;
  std::atomic<LONG> ref_count_;
  InvokeFn fn_;
};

template <typename InterfaceT, typename Arg1, typename Arg2, typename InvokeFn>
ComCallback2<InterfaceT, Arg1, Arg2, InvokeFn>* MakeComCallback2(InvokeFn fn) {
  return new (std::nothrow)
      ComCallback2<InterfaceT, Arg1, Arg2, InvokeFn>(std::move(fn));
}

IStream* CreateMemoryStreamFromUtf8(const std::string& data) {
  const size_t size = data.size();
  HGLOBAL hmem = ::GlobalAlloc(GMEM_MOVEABLE, size > 0 ? size : 1);
  if (hmem == nullptr) {
    return nullptr;
  }
  if (size > 0) {
    void* locked = ::GlobalLock(hmem);
    if (locked == nullptr) {
      ::GlobalFree(hmem);
      return nullptr;
    }
    std::memcpy(locked, data.data(), size);
    ::GlobalUnlock(hmem);
  }
  IStream* stream = nullptr;
  if (FAILED(::CreateStreamOnHGlobal(hmem, TRUE, &stream)) ||
      stream == nullptr) {
    ::GlobalFree(hmem);
    return nullptr;
  }
  return stream;
}

// Keep individual string literals well below MSVC's 16,380-byte C2026 limit.
constexpr char kBridgeHtmlPart1[] = R"HTML(<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Lumina External Apple Music Host</title>
  <script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js" async id="mk-script"></script>
</head>
<body>
  <audio id="lumina-audio" preload="auto"></audio>
  <script>
    (function () {
      const audioEl = document.getElementById('lumina-audio');
      const mkScript = document.getElementById('mk-script');
      let mkScriptFailed = false;
      if (mkScript) {
        mkScript.addEventListener('error', function () {
          mkScriptFailed = true;
        });
      }

      const config = { developerToken: '', musicUserToken: '', storefront: 'us' };
      let activeEpoch = 0;
      let activeMode = 'none'; // 'none' | 'musickit' | 'audio'
      let currentStatus = 'stopped';
      let currentVolume = 1.0;
      let musicKitConfigured = false;
      let configuredDevToken = '';
      let musicKitConfigPromise = null;
      let musicKitInstance = null;
      let musicKitListenersBound = false;
      let progressTimer = null;
      let suppressAudioPauseEvent = false;
      let lastExternalWebUrl = '';

      function postNative(payload) {
        if (window.chrome && window.chrome.webview) {
          window.chrome.webview.postMessage(payload);
        }
      }

      function emitState(epoch, status, positionMs, durationMs, error) {
        if (epoch !== activeEpoch) return;
        currentStatus = status;
        postNative({
          type: 'state',
          epoch: Number(epoch) || 0,
          status: String(status || 'stopped'),
          positionMs: Math.max(0, Math.round(Number(positionMs) || 0)),
          durationMs: Math.max(0, Math.round(Number(durationMs) || 0)),
          error: error ? String(error) : null
        });
      }

      function stopProgressTimer() {
        if (progressTimer !== null) {
          clearInterval(progressTimer);
          progressTimer = null;
        }
      }

      function getCurrentMetrics() {
        if (activeMode === 'musickit' && musicKitInstance) {
          const posSec = Number(musicKitInstance.currentPlaybackTime) || 0;
          const durSec = Number(musicKitInstance.currentPlaybackDuration) || 0;
          return {
            positionMs: Math.max(0, Math.round(posSec * 1000)),
            durationMs: Math.max(0, Math.round(durSec * 1000))
          };
        }
        if (activeMode === 'audio') {
          const posSec = Number(audioEl.currentTime) || 0;
          const durSec = Number.isFinite(audioEl.duration) ? audioEl.duration : 0;
          return {
            positionMs: Math.max(0, Math.round(posSec * 1000)),
            durationMs: Math.max(0, Math.round(durSec * 1000))
          };
        }
        return { positionMs: 0, durationMs: 0 };
      }

      function startProgressTimer() {
        stopProgressTimer();
        progressTimer = setInterval(function () {
          if (currentStatus !== 'playing' || activeMode === 'none') {
            return;
          }
          const m = getCurrentMetrics();
          emitState(activeEpoch, 'playing', m.positionMs, m.durationMs, null);
        }, 250);
      }

      function extractAppleSongId(trackUri) {
        const raw = String(trackUri || '').trim();
        if (!raw) return '';
        if (raw.startsWith('apple:')) {
          return raw.slice(6).trim();
        }
        if (raw.startsWith('http://') || raw.startsWith('https://') ||
            raw.startsWith('music://')) {
          try {
            const parsed = new URL(raw.replace(/^music:\/\//i, 'https://'));
            const trackParam = parsed.searchParams.get('i');
            if (trackParam) return trackParam.trim();
            const parts = parsed.pathname.split('/').filter(Boolean);
            if (parts.length > 0) return parts[parts.length - 1].trim();
          } catch (_) {}
        }
        return raw;
      }
)HTML";

constexpr char kBridgeHtmlPart2[] = R"HTML(
      function waitForMusicKitGlobal(timeoutMs) {
        if (window.MusicKit) return Promise.resolve(window.MusicKit);
        if (mkScriptFailed) return Promise.resolve(null);
        return new Promise(function (resolve) {
          let settled = false;
          const finish = function (val) {
            if (settled) return;
            settled = true;
            document.removeEventListener('musickitloaded', onLoaded);
            clearTimeout(timer);
            resolve(val);
          };
          const onLoaded = function () { finish(window.MusicKit || null); };
          const timer = setTimeout(function () {
            finish(window.MusicKit || null);
          }, timeoutMs);
          document.addEventListener('musickitloaded', onLoaded, { once: true });
        });
      }

      function bindMusicKitEvents(music) {
        if (!music || musicKitListenersBound) return;
        musicKitListenersBound = true;
        const States = (window.MusicKit && window.MusicKit.PlaybackStates) || {};
        music.addEventListener('playbackStateDidChange', function (ev) {
          if (activeMode !== 'musickit') return;
          const st = ev && ev.state;
          const m = getCurrentMetrics();
          if (st === States.loading || st === States.waiting ||
              st === States.stalled || st === States.seeking) {
            emitState(activeEpoch, 'loading', m.positionMs, m.durationMs, null);
          } else if (st === States.playing) {
            emitState(activeEpoch, 'playing', m.positionMs, m.durationMs, null);
            startProgressTimer();
          } else if (st === States.paused) {
            stopProgressTimer();
            emitState(activeEpoch, 'paused', m.positionMs, m.durationMs, null);
          } else if (st === States.stopped) {
            stopProgressTimer();
            emitState(activeEpoch, 'stopped', 0, 0, null);
          } else if (st === States.ended || st === States.completed) {
            stopProgressTimer();
            emitState(activeEpoch, 'ended', m.durationMs, m.durationMs, null);
          }
        });
        music.addEventListener('playbackTimeDidChange', function (ev) {
          if (activeMode !== 'musickit') return;
          const posMs = Math.max(0, Math.round(
            (Number(ev && ev.currentPlaybackTime) || 0) * 1000));
          const durMs = Math.max(0, Math.round(
            (Number(ev && ev.currentPlaybackDuration) || 0) * 1000));
          if (currentStatus === 'playing') {
            emitState(activeEpoch, 'playing', posMs, durMs, null);
          }
        });
        music.addEventListener('mediaPlaybackError', function (ev) {
          if (activeMode !== 'musickit') return;
          stopProgressTimer();
          const msg = (ev && (ev.errorMessage || ev.message)) ||
            'MusicKit playback error';
          emitState(activeEpoch, 'error', 0, 0, msg);
        });
      }

      async function ensureMusicKitConfigured() {
        if (!config.developerToken || !config.musicUserToken) {
          return null;
        }
        if (musicKitConfigPromise) {
          return musicKitConfigPromise;
        }
        musicKitConfigPromise = (async function () {
          const mk = await waitForMusicKitGlobal(2500);
          if (!mk) return null;
          if (!musicKitConfigured || configuredDevToken !== config.developerToken) {
            await mk.configure({
              developerToken: config.developerToken,
              storefrontId: config.storefront || 'us',
              app: { name: 'Lumina Audio', build: '0.2.4' }
            });
            musicKitConfigured = true;
            configuredDevToken = config.developerToken;
          }
          musicKitInstance = mk.getInstance();
          if (musicKitInstance) {
            try {
              musicKitInstance.musicUserToken = config.musicUserToken;
            } catch (_) {}
            try {
              if (config.storefront) {
                musicKitInstance.storefrontId = config.storefront;
              }
            } catch (_) {}
            musicKitInstance.volume = currentVolume;
            bindMusicKitEvents(musicKitInstance);
          }
          return musicKitInstance;
        })();
        try {
          return await musicKitConfigPromise;
        } catch (err) {
          musicKitConfigPromise = null;
          throw err;
        }
      }

      async function silenceAllInternal() {
        stopProgressTimer();
        activeMode = 'none';
        suppressAudioPauseEvent = true;
        try {
          audioEl.pause();
          audioEl.removeAttribute('src');
          audioEl.load();
        } catch (_) {}
        suppressAudioPauseEvent = false;
        if (musicKitInstance) {
          try {
            await musicKitInstance.stop();
          } catch (_) {}
        }
      }
)HTML";

constexpr char kBridgeHtmlPart3[] = R"HTML(
      audioEl.addEventListener('playing', function () {
        if (activeMode !== 'audio') return;
        const m = getCurrentMetrics();
        emitState(activeEpoch, 'playing', m.positionMs, m.durationMs, null);
        startProgressTimer();
      });
      audioEl.addEventListener('waiting', function () {
        if (activeMode !== 'audio') return;
        const m = getCurrentMetrics();
        emitState(activeEpoch, 'loading', m.positionMs, m.durationMs, null);
      });
      audioEl.addEventListener('pause', function () {
        if (activeMode !== 'audio' || suppressAudioPauseEvent) return;
        if (audioEl.ended) return;
        stopProgressTimer();
        const m = getCurrentMetrics();
        emitState(activeEpoch, 'paused', m.positionMs, m.durationMs, null);
      });
      audioEl.addEventListener('ended', function () {
        if (activeMode !== 'audio') return;
        stopProgressTimer();
        const m = getCurrentMetrics();
        emitState(activeEpoch, 'ended', m.durationMs, m.durationMs, null);
      });
      audioEl.addEventListener('error', function () {
        if (activeMode !== 'audio') return;
        stopProgressTimer();
        const errObj = audioEl.error;
        const code = errObj ? errObj.code : 0;
        emitState(activeEpoch, 'error', 0, 0,
          'HTML5 audio playback failed (code ' + code + ')');
      });

      async function startAudioPreview(epoch, previewUrl) {
        if (epoch !== activeEpoch) return;
        activeMode = 'audio';
        audioEl.volume = currentVolume;
        audioEl.src = previewUrl;
        await audioEl.play();
        if (epoch !== activeEpoch) return;
        const m = getCurrentMetrics();
        emitState(epoch, 'playing', m.positionMs, m.durationMs, null);
        startProgressTimer();
      }

      async function handlePlay(cmd) {
        const epoch = Number(cmd.epoch) || 0;
        activeEpoch = epoch;
        lastExternalWebUrl = String(cmd.externalWebUrl || '').trim();
        const previewUrl = String(cmd.previewUrl || '').trim();
        const songId = extractAppleSongId(cmd.trackUri);

        await silenceAllInternal();
        if (epoch !== activeEpoch) return;

        emitState(epoch, 'loading', 0, 0, null);

        let mkError = '';
        if (songId && config.developerToken && config.musicUserToken) {
          try {
            const music = await ensureMusicKitConfigured();
            if (epoch !== activeEpoch) return;
            if (music) {
              activeMode = 'musickit';
              music.volume = currentVolume;
              await music.setQueue({ song: songId, startPlaying: true });
              if (epoch !== activeEpoch) return;
              const m = getCurrentMetrics();
              emitState(epoch, 'playing', m.positionMs, m.durationMs, null);
              startProgressTimer();
              return;
            }
          } catch (err) {
            mkError = (err && err.message) ? err.message : String(err);
            activeMode = 'none';
            if (musicKitInstance) {
              try { await musicKitInstance.stop(); } catch (_) {}
            }
          }
        }

        if (epoch !== activeEpoch) return;

        if (previewUrl) {
          try {
            await startAudioPreview(epoch, previewUrl);
            return;
          } catch (audioErr) {
            const msg = (audioErr && audioErr.message)
              ? audioErr.message
              : String(audioErr);
            emitState(epoch, 'error', 0, 0, msg);
            return;
          }
        }

        const fallbackMsg = mkError ||
          (lastExternalWebUrl
            ? 'Apple Music full stream unavailable in WebView2 and no previewUrl provided (' + lastExternalWebUrl + ')'
            : 'Apple Music playback requires MusicKit credentials or a previewUrl');
        emitState(epoch, 'error', 0, 0, fallbackMsg);
      }

      async function handleCommand(cmd) {
        if (!cmd || typeof cmd !== 'object') return;
        const type = cmd.type;
        if (type === 'configure') {
          config.developerToken = String(cmd.developerToken || '').trim();
          config.musicUserToken = String(cmd.musicUserToken || '').trim();
          config.storefront = String(cmd.storefront || 'us').trim() || 'us';
          if (configuredDevToken !== config.developerToken) {
            musicKitConfigured = false;
          }
          musicKitConfigPromise = null;
          try { await ensureMusicKitConfigured(); } catch (_) {}
          return;
        }
        if (type === 'play') {
          await handlePlay(cmd);
          return;
        }
        const cmdEpoch = Number(cmd.epoch) || 0;
        if (cmdEpoch && activeEpoch && cmdEpoch < activeEpoch) {
          return;
        }
        if (cmdEpoch) {
          activeEpoch = cmdEpoch;
        }
        if (type === 'pause') {
          stopProgressTimer();
          if (activeMode === 'musickit' && musicKitInstance) {
            try { await musicKitInstance.pause(); } catch (_) {}
          } else if (activeMode === 'audio') {
            suppressAudioPauseEvent = true;
            try { audioEl.pause(); } catch (_) {}
            suppressAudioPauseEvent = false;
          }
          const m = getCurrentMetrics();
          emitState(activeEpoch, 'paused', m.positionMs, m.durationMs, null);
          return;
        }
        if (type === 'resume') {
          if (activeMode === 'musickit' && musicKitInstance) {
            try {
              await musicKitInstance.play();
              const m = getCurrentMetrics();
              emitState(activeEpoch, 'playing', m.positionMs, m.durationMs, null);
              startProgressTimer();
            } catch (err) {
              emitState(activeEpoch, 'error', 0, 0,
                (err && err.message) ? err.message : String(err));
            }
          } else if (activeMode === 'audio' && audioEl.src) {
            try {
              await audioEl.play();
              const m = getCurrentMetrics();
              emitState(activeEpoch, 'playing', m.positionMs, m.durationMs, null);
              startProgressTimer();
            } catch (err) {
              emitState(activeEpoch, 'error', 0, 0,
                (err && err.message) ? err.message : String(err));
            }
          }
          return;
        }
        if (type === 'seek') {
          const posMs = Math.max(0, Number(cmd.positionMs) || 0);
          const posSec = posMs / 1000.0;
          if (activeMode === 'musickit' && musicKitInstance) {
            try { await musicKitInstance.seekToTime(posSec); } catch (_) {}
            const m = getCurrentMetrics();
            emitState(activeEpoch, currentStatus === 'paused' ? 'paused' : 'playing',
              posMs, m.durationMs, null);
          } else if (activeMode === 'audio' && audioEl.src) {
            const dur = Number.isFinite(audioEl.duration) ? audioEl.duration : posSec;
            const targetSec = Math.max(0, Math.min(posSec, dur));
            audioEl.currentTime = targetSec;
            const m = getCurrentMetrics();
            emitState(activeEpoch, audioEl.paused ? 'paused' : 'playing',
              Math.round(targetSec * 1000), m.durationMs, null);
          }
          return;
        }
        if (type === 'setVolume') {
          const rawVol = Number(cmd.volume);
          currentVolume = Number.isFinite(rawVol)
            ? Math.max(0, Math.min(1, rawVol))
            : 1.0;
          audioEl.volume = currentVolume;
          if (musicKitInstance) {
            try { musicKitInstance.volume = currentVolume; } catch (_) {}
          }
          return;
        }
        if (type === 'stop') {
          await silenceAllInternal();
          emitState(activeEpoch, 'stopped', 0, 0, null);
        }
      }

      if (window.chrome && window.chrome.webview) {
        window.chrome.webview.addEventListener('message', function (ev) {
          let cmd = ev ? ev.data : null;
          if (typeof cmd === 'string') {
            try { cmd = JSON.parse(cmd); } catch (_) { return; }
          }
          handleCommand(cmd);
        });
      }

      postNative({ type: 'ready' });
    })();
  </script>
</body>
</html>)HTML";

std::string BuildBridgeHtml() {
  std::string html;
  html.reserve(sizeof(kBridgeHtmlPart1) + sizeof(kBridgeHtmlPart2) +
               sizeof(kBridgeHtmlPart3));
  html.append(kBridgeHtmlPart1);
  html.append(kBridgeHtmlPart2);
  html.append(kBridgeHtmlPart3);
  return html;
}

#endif  // LUMINA_HAS_WEBVIEW2

}  // namespace

struct ExternalMusicHost::Impl
    : public std::enable_shared_from_this<ExternalMusicHost::Impl> {
  HWND owner_hwnd_ = nullptr;
  HWND host_hwnd_ = nullptr;
  DWORD ui_thread_id_ = 0;
  StateCallback on_state_;
  std::atomic<bool> closing_{false};
  std::atomic<bool> runtime_init_failed_{false};
  bool started_ = false;
  bool bridge_ready_ = false;

  bool has_active_epoch_ = false;
  int64_t current_epoch_ = 0;
  double volume_ = 1.0;

  bool has_config_ = false;
  ExternalPlaybackConfigureArgs config_;

  bool has_pending_play_ = false;
  ExternalPlaybackPlayArgs pending_play_;
  bool pending_paused_ = false;
  int64_t pending_seek_ms_ = -1;

  std::mutex queue_mutex_;
  std::deque<ExternalPlaybackStateEvent> ui_queue_;
  bool dispatching_ui_ = false;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  ICoreWebView2Environment* environment_ = nullptr;
  ICoreWebView2Controller* controller_ = nullptr;
  ICoreWebView2* webview_ = nullptr;
  EventRegistrationToken nav_starting_token_{};
  EventRegistrationToken nav_completed_token_{};
  EventRegistrationToken web_resource_token_{};
  EventRegistrationToken web_message_token_{};
  EventRegistrationToken permission_token_{};
  bool has_nav_starting_token_ = false;
  bool has_nav_completed_token_ = false;
  bool has_web_resource_token_ = false;
  bool has_web_message_token_ = false;
  bool has_permission_token_ = false;
#endif

  ~Impl() { Shutdown(); }

  void EmitState(const ExternalPlaybackStateEvent& ev) {
    if (closing_.load()) {
      return;
    }
    if (::GetCurrentThreadId() == ui_thread_id_ && !dispatching_ui_) {
      DispatchSingleState(ev);
      return;
    }
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      ui_queue_.push_back(ev);
    }
    if (host_hwnd_ != nullptr && ::IsWindow(host_hwnd_)) {
      ::PostMessageW(host_hwnd_, kDispatchUiQueueMessage, 0, 0);
    }
  }

  void DispatchSingleState(const ExternalPlaybackStateEvent& ev) {
    if (closing_.load() || !on_state_) {
      return;
    }
    StateCallback cb = on_state_;
    dispatching_ui_ = true;
    cb(ev);
    dispatching_ui_ = false;
    DrainUiQueue();
  }

  void DrainUiQueue() {
    if (closing_.load() || dispatching_ui_) {
      return;
    }
    for (;;) {
      std::deque<ExternalPlaybackStateEvent> batch;
      {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        if (ui_queue_.empty()) {
          break;
        }
        batch.swap(ui_queue_);
      }
      dispatching_ui_ = true;
      for (const auto& ev : batch) {
        if (closing_.load() || !on_state_) {
          break;
        }
        StateCallback cb = on_state_;
        cb(ev);
      }
      dispatching_ui_ = false;
      if (closing_.load()) {
        break;
      }
    }
  }

  void CleanupWebView() {
#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
    bridge_ready_ = false;
    if (webview_ != nullptr) {
      if (has_nav_starting_token_) {
        webview_->remove_NavigationStarting(nav_starting_token_);
        has_nav_starting_token_ = false;
      }
      if (has_nav_completed_token_) {
        webview_->remove_NavigationCompleted(nav_completed_token_);
        has_nav_completed_token_ = false;
      }
      if (has_web_resource_token_) {
        webview_->remove_WebResourceRequested(web_resource_token_);
        has_web_resource_token_ = false;
      }
      if (has_web_message_token_) {
        webview_->remove_WebMessageReceived(web_message_token_);
        has_web_message_token_ = false;
      }
      if (has_permission_token_) {
        webview_->remove_PermissionRequested(permission_token_);
        has_permission_token_ = false;
      }
      webview_->Release();
      webview_ = nullptr;
    }
    if (controller_ != nullptr) {
      controller_->Close();
      controller_->Release();
      controller_ = nullptr;
    }
    if (environment_ != nullptr) {
      environment_->Release();
      environment_ = nullptr;
    }
#endif
  }

  void Shutdown() {
    if (closing_.exchange(true)) {
      return;
    }
    on_state_ = nullptr;
    has_pending_play_ = false;
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      ui_queue_.clear();
    }
    CleanupWebView();
    if (host_hwnd_ != nullptr) {
      HWND hwnd_to_destroy = host_hwnd_;
      host_hwnd_ = nullptr;
      if (::IsWindow(hwnd_to_destroy)) {
        ::SetWindowLongPtrW(hwnd_to_destroy, GWLP_USERDATA, 0);
        ::DestroyWindow(hwnd_to_destroy);
      }
    }
  }

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  bool PostBridgeJson(const std::string& json_utf8) {
    if (closing_.load() || webview_ == nullptr) {
      return false;
    }
    const std::wstring wide = Utf8ToWide(json_utf8);
    if (wide.empty()) {
      return false;
    }
    return SUCCEEDED(webview_->PostWebMessageAsJson(wide.c_str()));
  }

  void SendConfigureToBridge() {
    if (!has_config_ || !bridge_ready_) {
      return;
    }
    const std::string storefront =
        config_.storefront.empty() ? "us" : config_.storefront;
    const std::string json =
        std::string("{\"type\":\"configure\",\"developerToken\":\"") +
        JsonEscape(config_.developer_token) + "\",\"musicUserToken\":\"" +
        JsonEscape(config_.music_user_token) + "\",\"storefront\":\"" +
        JsonEscape(storefront) + "\"}";
    PostBridgeJson(json);
  }

  void SendVolumeToBridge() {
    if (!bridge_ready_) {
      return;
    }
    const std::string json = std::string("{\"type\":\"setVolume\",\"volume\":") +
                             FormatDoubleJson(volume_) + "}";
    PostBridgeJson(json);
  }

  void SendPlayToBridge(const ExternalPlaybackPlayArgs& args) {
    if (!bridge_ready_) {
      return;
    }
    const std::string json =
        std::string("{\"type\":\"play\",\"trackUri\":\"") +
        JsonEscape(args.track_uri) + "\",\"previewUrl\":\"" +
        JsonEscape(args.preview_url) + "\",\"externalWebUrl\":\"" +
        JsonEscape(args.external_web_url) + "\",\"epoch\":" +
        std::to_string(args.epoch) + "}";
    PostBridgeJson(json);
  }

  void SendSimpleEpochCommand(const char* type, int64_t epoch) {
    if (!bridge_ready_ || type == nullptr) {
      return;
    }
    const std::string json = std::string("{\"type\":\"") + type +
                             "\",\"epoch\":" + std::to_string(epoch) + "}";
    PostBridgeJson(json);
  }

  void SendSeekToBridge(int64_t position_ms, int64_t epoch) {
    if (!bridge_ready_) {
      return;
    }
    const std::string json =
        std::string("{\"type\":\"seek\",\"positionMs\":") +
        std::to_string(position_ms) + ",\"epoch\":" + std::to_string(epoch) +
        "}";
    PostBridgeJson(json);
  }

  void OnBridgeReady() {
    if (closing_.load()) {
      return;
    }
    bridge_ready_ = true;
    SendConfigureToBridge();
    SendVolumeToBridge();
    if (has_pending_play_) {
      ExternalPlaybackPlayArgs play_args = pending_play_;
      const bool should_pause = pending_paused_;
      const int64_t queued_seek = pending_seek_ms_;
      has_pending_play_ = false;
      pending_paused_ = false;
      pending_seek_ms_ = -1;
      SendPlayToBridge(play_args);
      if (queued_seek > 0) {
        SendSeekToBridge(queued_seek, play_args.epoch);
      }
      if (should_pause) {
        SendSimpleEpochCommand("pause", play_args.epoch);
      }
    }
  }

  void HandleWebMessageReceived(ICoreWebView2WebMessageReceivedEventArgs* args) {
    if (closing_.load() || args == nullptr) {
      return;
    }
    LPWSTR raw_src = nullptr;
    if (SUCCEEDED(args->get_Source(&raw_src)) && raw_src != nullptr) {
      const std::string src_utf8 = WideToUtf8(raw_src);
      ::CoTaskMemFree(raw_src);
      if (!StartsWithCaseInsensitive(src_utf8, kBridgeOriginPrefix)) {
        return;
      }
    } else {
      return;
    }

    LPWSTR raw_json = nullptr;
    if (FAILED(args->get_WebMessageAsJson(&raw_json)) || raw_json == nullptr) {
      return;
    }
    const std::string json_utf8 = WideToUtf8(raw_json);
    ::CoTaskMemFree(raw_json);

    std::map<std::string, JsonFlatValue> obj;
    if (!ParseFlatJsonObject(json_utf8, &obj)) {
      return;
    }

    auto type_it = obj.find("type");
    if (type_it == obj.end() ||
        type_it->second.kind != JsonFlatValue::Kind::kString) {
      return;
    }

    const std::string& msg_type = type_it->second.string_val;
    if (msg_type == "ready") {
      OnBridgeReady();
      return;
    }

    if (msg_type != "state") {
      return;
    }

    ExternalPlaybackStateEvent ev;
    auto epoch_it = obj.find("epoch");
    if (epoch_it != obj.end() &&
        epoch_it->second.kind == JsonFlatValue::Kind::kNumber) {
      ev.epoch = epoch_it->second.int_val;
    }
    if (has_active_epoch_ && ev.epoch != current_epoch_) {
      return;
    }

    auto status_it = obj.find("status");
    if (status_it == obj.end() ||
        status_it->second.kind != JsonFlatValue::Kind::kString) {
      return;
    }
    ev.status = ToLowerAscii(status_it->second.string_val);
    if (!IsTerminalOrSupportedStatus(ev.status)) {
      return;
    }

    auto pos_it = obj.find("positionMs");
    if (pos_it != obj.end() &&
        pos_it->second.kind == JsonFlatValue::Kind::kNumber) {
      ev.position_ms = std::max<int64_t>(0, pos_it->second.int_val);
    }
    auto dur_it = obj.find("durationMs");
    if (dur_it != obj.end() &&
        dur_it->second.kind == JsonFlatValue::Kind::kNumber) {
      ev.duration_ms = std::max<int64_t>(0, dur_it->second.int_val);
    }
    auto err_it = obj.find("error");
    if (err_it != obj.end() &&
        err_it->second.kind == JsonFlatValue::Kind::kString) {
      ev.error = err_it->second.string_val;
    }

    EmitState(ev);
  }

  void HandleWebResourceRequested(
      ICoreWebView2WebResourceRequestedEventArgs* args) {
    if (closing_.load() || args == nullptr || environment_ == nullptr) {
      return;
    }
    ICoreWebView2WebResourceRequest* req = nullptr;
    if (FAILED(args->get_Request(&req)) || req == nullptr) {
      return;
    }
    LPWSTR raw_uri = nullptr;
    bool matches = false;
    if (SUCCEEDED(req->get_Uri(&raw_uri)) && raw_uri != nullptr) {
      const std::string uri_utf8 = WideToUtf8(raw_uri);
      ::CoTaskMemFree(raw_uri);
      matches = StartsWithCaseInsensitive(uri_utf8, kBridgeOriginPrefix);
    }
    req->Release();

    if (!matches) {
      return;
    }

    const std::string html = BuildBridgeHtml();
    IStream* stream = CreateMemoryStreamFromUtf8(html);
    if (stream == nullptr) {
      return;
    }
    ICoreWebView2WebResourceResponse* response = nullptr;
    const HRESULT resp_hr = environment_->CreateWebResourceResponse(
        stream, 200, L"OK",
        L"Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store",
        &response);
    stream->Release();
    if (SUCCEEDED(resp_hr) && response != nullptr) {
      args->put_Response(response);
      response->Release();
    }
  }

  void FailStartup(const std::string& error_message) {
    runtime_init_failed_.store(true);
    if (has_pending_play_) {
      ExternalPlaybackStateEvent ev;
      ev.epoch = pending_play_.epoch;
      ev.status = "error";
      ev.error = error_message;
      has_pending_play_ = false;
      EmitState(ev);
    }
  }

  bool EnsureStarted(std::string* error_out) {
    if (closing_.load()) {
      if (error_out != nullptr) {
        *error_out = "ExternalMusicHost is shutting down";
      }
      return false;
    }
    if (started_) {
      return !runtime_init_failed_.load();
    }

    HMODULE loader = LoadWebView2LoaderModule();
    if (loader == nullptr) {
      runtime_init_failed_.store(true);
      if (error_out != nullptr) {
        *error_out = "WebView2Loader.dll not available";
      }
      return false;
    }

    auto create_env_fn =
        reinterpret_cast<CreateCoreWebView2EnvironmentWithOptionsFn>(
            ::GetProcAddress(loader,
                             "CreateCoreWebView2EnvironmentWithOptions"));
    if (create_env_fn == nullptr) {
      runtime_init_failed_.store(true);
      if (error_out != nullptr) {
        *error_out =
            "CreateCoreWebView2EnvironmentWithOptions export missing in "
            "WebView2Loader.dll";
      }
      return false;
    }

    const HINSTANCE hinst = ::GetModuleHandleW(nullptr);
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = Impl::WndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = kHostWindowClassName;
    ::RegisterClassExW(&wc);

    // Hidden off-screen tool window that never steals focus or shows in Alt-Tab.
    host_hwnd_ = ::CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kHostWindowClassName,
        L"LuminaExternalPlaybackHost", WS_POPUP, -32000, -32000, 320, 240,
        nullptr, nullptr, hinst, this);
    if (host_hwnd_ == nullptr) {
      runtime_init_failed_.store(true);
      if (error_out != nullptr) {
        *error_out = "Failed to create hidden WebView2 host window";
      }
      return false;
    }

    started_ = true;

    auto* env_options = new (std::nothrow) ExternalPlaybackEnvironmentOptions(
        L"--autoplay-policy=no-user-gesture-required");
    const std::wstring user_data_dir = GetExternalPlaybackUserDataFolder();
    auto self = shared_from_this();

    auto* env_handler = MakeComCallback2<
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, HRESULT,
        ICoreWebView2Environment*>(
        [self](HRESULT env_hr, ICoreWebView2Environment* env) -> HRESULT {
          if (self->closing_.load()) {
            return S_OK;
          }
          if (FAILED(env_hr) || env == nullptr) {
            self->FailStartup(
                "Failed to initialize WebView2 runtime (HRESULT=" +
                std::to_string(static_cast<long>(env_hr)) + ")");
            return S_OK;
          }

          self->environment_ = env;
          self->environment_->AddRef();

          auto* ctrl_handler = MakeComCallback2<
              ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
              HRESULT, ICoreWebView2Controller*>(
              [self](HRESULT ctrl_hr,
                     ICoreWebView2Controller* ctrl) -> HRESULT {
                if (self->closing_.load()) {
                  if (ctrl != nullptr) {
                    ctrl->Close();
                  }
                  return S_OK;
                }
                if (FAILED(ctrl_hr) || ctrl == nullptr) {
                  self->FailStartup("Failed to create WebView2 controller");
                  return S_OK;
                }

                self->controller_ = ctrl;
                self->controller_->AddRef();
                RECT bounds{0, 0, 320, 240};
                self->controller_->put_Bounds(bounds);
                // Keep controller marked visible inside the hidden tool HWND so
                // Chromium does not suspend/defer HTML5 <audio> or MusicKit.
                self->controller_->put_IsVisible(TRUE);

                if (FAILED(self->controller_->get_CoreWebView2(
                        &self->webview_)) ||
                    self->webview_ == nullptr) {
                  self->FailStartup("Failed to acquire CoreWebView2 instance");
                  return S_OK;
                }

                ICoreWebView2Settings* settings = nullptr;
                if (SUCCEEDED(self->webview_->get_Settings(&settings)) &&
                    settings != nullptr) {
                  settings->put_IsScriptEnabled(TRUE);
                  settings->put_IsWebMessageEnabled(TRUE);
                  settings->put_AreDefaultScriptDialogsEnabled(FALSE);
                  settings->put_IsStatusBarEnabled(FALSE);
                  settings->put_AreDevToolsEnabled(FALSE);
                  settings->put_AreDefaultContextMenusEnabled(FALSE);

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

                self->webview_->AddWebResourceRequestedFilter(
                    L"https://lumina-external.music.apple.local/*",
                    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT);

                auto* res_handler = MakeComCallback2<
                    ICoreWebView2WebResourceRequestedEventHandler,
                    ICoreWebView2*,
                    ICoreWebView2WebResourceRequestedEventArgs*>(
                    [self](ICoreWebView2* /*res_sender*/,
                           ICoreWebView2WebResourceRequestedEventArgs* res_args)
                        -> HRESULT {
                      self->HandleWebResourceRequested(res_args);
                      return S_OK;
                    });
                if (res_handler != nullptr) {
                  if (SUCCEEDED(self->webview_->add_WebResourceRequested(
                          res_handler, &self->web_resource_token_))) {
                    self->has_web_resource_token_ = true;
                  }
                  res_handler->Release();
                }

                auto* nav_start_handler = MakeComCallback2<
                    ICoreWebView2NavigationStartingEventHandler,
                    ICoreWebView2*,
                    ICoreWebView2NavigationStartingEventArgs*>(
                    [self](ICoreWebView2* /*nav_sender*/,
                           ICoreWebView2NavigationStartingEventArgs* nav_args)
                        -> HRESULT {
                      if (self->closing_.load() || nav_args == nullptr) {
                        return S_OK;
                      }
                      LPWSTR uri_ptr = nullptr;
                      bool allow = false;
                      if (SUCCEEDED(nav_args->get_Uri(&uri_ptr)) &&
                          uri_ptr != nullptr) {
                        const std::string uri_utf8 = WideToUtf8(uri_ptr);
                        ::CoTaskMemFree(uri_ptr);
                        allow = StartsWithCaseInsensitive(uri_utf8,
                                                          kBridgeOriginPrefix);
                      }
                      if (!allow) {
                        nav_args->put_Cancel(TRUE);
                      }
                      return S_OK;
                    });
                if (nav_start_handler != nullptr) {
                  if (SUCCEEDED(self->webview_->add_NavigationStarting(
                          nav_start_handler, &self->nav_starting_token_))) {
                    self->has_nav_starting_token_ = true;
                  }
                  nav_start_handler->Release();
                }

                auto* nav_done_handler = MakeComCallback2<
                    ICoreWebView2NavigationCompletedEventHandler,
                    ICoreWebView2*,
                    ICoreWebView2NavigationCompletedEventArgs*>(
                    [self](ICoreWebView2* /*done_sender*/,
                           ICoreWebView2NavigationCompletedEventArgs* done_args)
                        -> HRESULT {
                      if (self->closing_.load() || done_args == nullptr) {
                        return S_OK;
                      }
                      BOOL ok = FALSE;
                      if (SUCCEEDED(done_args->get_IsSuccess(&ok)) && !ok) {
                        self->FailStartup(
                            "Failed to load internal Apple Music WebView2 "
                            "bridge document");
                      }
                      return S_OK;
                    });
                if (nav_done_handler != nullptr) {
                  if (SUCCEEDED(self->webview_->add_NavigationCompleted(
                          nav_done_handler, &self->nav_completed_token_))) {
                    self->has_nav_completed_token_ = true;
                  }
                  nav_done_handler->Release();
                }

                auto* perm_handler = MakeComCallback2<
                    ICoreWebView2PermissionRequestedEventHandler,
                    ICoreWebView2*,
                    ICoreWebView2PermissionRequestedEventArgs*>(
                    [self](ICoreWebView2* /*perm_sender*/,
                           ICoreWebView2PermissionRequestedEventArgs* perm_args)
                        -> HRESULT {
                      if (self->closing_.load() || perm_args == nullptr) {
                        return S_OK;
                      }
                      COREWEBVIEW2_PERMISSION_KIND kind =
                          COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
                      if (SUCCEEDED(perm_args->get_PermissionKind(&kind)) &&
                          kind == COREWEBVIEW2_PERMISSION_KIND_AUTOPLAY) {
                        perm_args->put_State(
                            COREWEBVIEW2_PERMISSION_STATE_ALLOW);
                      }
                      return S_OK;
                    });
                if (perm_handler != nullptr) {
                  if (SUCCEEDED(self->webview_->add_PermissionRequested(
                          perm_handler, &self->permission_token_))) {
                    self->has_permission_token_ = true;
                  }
                  perm_handler->Release();
                }

                auto* msg_handler = MakeComCallback2<
                    ICoreWebView2WebMessageReceivedEventHandler,
                    ICoreWebView2*,
                    ICoreWebView2WebMessageReceivedEventArgs*>(
                    [self](ICoreWebView2* /*msg_sender*/,
                           ICoreWebView2WebMessageReceivedEventArgs* msg_args)
                        -> HRESULT {
                      self->HandleWebMessageReceived(msg_args);
                      return S_OK;
                    });
                if (msg_handler != nullptr) {
                  if (SUCCEEDED(self->webview_->add_WebMessageReceived(
                          msg_handler, &self->web_message_token_))) {
                    self->has_web_message_token_ = true;
                  }
                  msg_handler->Release();
                }

                const HRESULT nav_hr = self->webview_->Navigate(kBridgeUrl);
                if (FAILED(nav_hr)) {
                  self->FailStartup(
                      "Failed to navigate WebView2 external playback bridge");
                }
                return S_OK;
              });

          if (ctrl_handler == nullptr) {
            self->FailStartup(
                "Out of memory creating WebView2 controller handler");
            return S_OK;
          }
          const HRESULT ch_hr =
              env->CreateCoreWebView2Controller(self->host_hwnd_, ctrl_handler);
          ctrl_handler->Release();
          if (FAILED(ch_hr)) {
            self->FailStartup("CreateCoreWebView2Controller failed");
          }
          return S_OK;
        });

    if (env_handler == nullptr) {
      if (env_options != nullptr) {
        env_options->Release();
      }
      runtime_init_failed_.store(true);
      if (error_out != nullptr) {
        *error_out = "Out of memory creating WebView2 environment handler";
      }
      return false;
    }

    HRESULT env_hr = create_env_fn(
        nullptr, user_data_dir.c_str(), env_options, env_handler);
    if (FAILED(env_hr) && env_options != nullptr) {
      env_hr =
          create_env_fn(nullptr, user_data_dir.c_str(), nullptr, env_handler);
    }
    env_handler->Release();
    if (env_options != nullptr) {
      env_options->Release();
    }
    if (FAILED(env_hr)) {
      runtime_init_failed_.store(true);
      if (error_out != nullptr) {
        char hr_buf[32] = {};
        std::snprintf(hr_buf, sizeof(hr_buf), "0x%08lx",
                      static_cast<unsigned long>(env_hr));
        *error_out =
            std::string("CreateCoreWebView2EnvironmentWithOptions failed (HRESULT=") +
            hr_buf + ")";
      }
      return false;
    }
    return true;
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

    if (message == kDispatchUiQueueMessage) {
      self->DrainUiQueue();
      return 0;
    }

    if (message == WM_NCDESTROY) {
      ::SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      self->host_hwnd_ = nullptr;
      return 0;
    }

    return ::DefWindowProcW(window, message, wparam, lparam);
  }
#endif  // LUMINA_HAS_WEBVIEW2
};

ExternalMusicHost::ExternalMusicHost(std::shared_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

ExternalMusicHost::~ExternalMusicHost() {
  Shutdown();
}

bool ExternalMusicHost::IsWebView2Available() {
#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  HMODULE loader = LoadWebView2LoaderModule();
  if (loader == nullptr) {
    return false;
  }
  auto create_env_fn =
      reinterpret_cast<CreateCoreWebView2EnvironmentWithOptionsFn>(
          ::GetProcAddress(loader,
                           "CreateCoreWebView2EnvironmentWithOptions"));
  if (create_env_fn == nullptr) {
    return false;
  }
  auto version_fn =
      reinterpret_cast<GetAvailableCoreWebView2BrowserVersionStringFn>(
          ::GetProcAddress(loader,
                           "GetAvailableCoreWebView2BrowserVersionString"));
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

std::unique_ptr<ExternalMusicHost> ExternalMusicHost::Create(
    HWND owner_hwnd,
    StateCallback on_state) {
  auto impl = std::make_shared<Impl>();
  impl->owner_hwnd_ = owner_hwnd;
  impl->ui_thread_id_ = ::GetCurrentThreadId();
  impl->on_state_ = std::move(on_state);
  return std::unique_ptr<ExternalMusicHost>(new ExternalMusicHost(impl));
}

bool ExternalMusicHost::IsAvailable() const {
#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (!impl_ || impl_->closing_.load() || impl_->runtime_init_failed_.load()) {
    return false;
  }
  return IsWebView2Available();
#else
  return false;
#endif
}

bool ExternalMusicHost::Configure(const ExternalPlaybackConfigureArgs& args,
                                  std::string* error_out) {
  if (!impl_ || impl_->closing_.load()) {
    if (error_out != nullptr) {
      *error_out = "ExternalMusicHost is not active";
    }
    return false;
  }
  impl_->config_ = args;
  impl_->has_config_ = true;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (!IsAvailable()) {
    // Allow configure to succeed lazily as a no-op so subsequent play reports a
    // clean unsupported state instead of throwing early during setup.
    return true;
  }
  if (!impl_->EnsureStarted(error_out)) {
    return false;
  }
  if (impl_->bridge_ready_) {
    impl_->SendConfigureToBridge();
  }
  return true;
#else
  (void)error_out;
  return true;
#endif
}

bool ExternalMusicHost::Play(const ExternalPlaybackPlayArgs& args,
                             std::string* error_out) {
  if (!impl_ || impl_->closing_.load()) {
    if (error_out != nullptr) {
      *error_out = "ExternalMusicHost is not active";
    }
    return false;
  }

  impl_->current_epoch_ = args.epoch;
  impl_->has_active_epoch_ = true;
  impl_->pending_paused_ = false;
  impl_->pending_seek_ms_ = -1;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (!IsAvailable()) {
    const std::string msg =
        "Microsoft Edge WebView2 runtime is not available for external Apple "
        "Music playback";
    if (error_out != nullptr) {
      *error_out = msg;
    }
    ExternalPlaybackStateEvent ev;
    ev.epoch = args.epoch;
    ev.status = "error";
    ev.error = msg;
    impl_->EmitState(ev);
    return false;
  }

  impl_->pending_play_ = args;
  impl_->has_pending_play_ = true;

  ExternalPlaybackStateEvent loading_ev;
  loading_ev.epoch = args.epoch;
  loading_ev.status = "loading";
  impl_->EmitState(loading_ev);

  std::string start_err;
  if (!impl_->EnsureStarted(&start_err)) {
    impl_->has_pending_play_ = false;
    if (error_out != nullptr) {
      *error_out = start_err;
    }
    ExternalPlaybackStateEvent err_ev;
    err_ev.epoch = args.epoch;
    err_ev.status = "error";
    err_ev.error = start_err.empty()
                       ? "Failed to start WebView2 external playback host"
                       : start_err;
    impl_->EmitState(err_ev);
    return false;
  }

  if (impl_->bridge_ready_) {
    impl_->has_pending_play_ = false;
    impl_->SendPlayToBridge(args);
  }
  return true;
#else
  const std::string msg =
      "External Apple Music playback is unsupported in this build "
      "(LUMINA_HAS_WEBVIEW2=0)";
  if (error_out != nullptr) {
    *error_out = msg;
  }
  ExternalPlaybackStateEvent ev;
  ev.epoch = args.epoch;
  ev.status = "error";
  ev.error = msg;
  impl_->EmitState(ev);
  return false;
#endif
}

bool ExternalMusicHost::Pause(int64_t epoch, std::string* error_out) {
  if (!impl_ || impl_->closing_.load()) {
    if (error_out != nullptr) {
      *error_out = "ExternalMusicHost is not active";
    }
    return false;
  }
  if (epoch != 0 && impl_->has_active_epoch_ && epoch < impl_->current_epoch_) {
    return true;
  }
  if (epoch != 0) {
    impl_->current_epoch_ = epoch;
    impl_->has_active_epoch_ = true;
  }

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (impl_->has_pending_play_) {
    impl_->pending_paused_ = true;
    ExternalPlaybackStateEvent ev;
    ev.epoch = impl_->current_epoch_;
    ev.status = "paused";
    impl_->EmitState(ev);
    return true;
  }
  if (impl_->bridge_ready_) {
    impl_->SendSimpleEpochCommand("pause", impl_->current_epoch_);
  }
  return true;
#else
  (void)error_out;
  return true;
#endif
}

bool ExternalMusicHost::Resume(int64_t epoch, std::string* error_out) {
  if (!impl_ || impl_->closing_.load()) {
    if (error_out != nullptr) {
      *error_out = "ExternalMusicHost is not active";
    }
    return false;
  }
  if (epoch != 0 && impl_->has_active_epoch_ && epoch < impl_->current_epoch_) {
    return true;
  }
  if (epoch != 0) {
    impl_->current_epoch_ = epoch;
    impl_->has_active_epoch_ = true;
  }
  impl_->pending_paused_ = false;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (impl_->bridge_ready_) {
    impl_->SendSimpleEpochCommand("resume", impl_->current_epoch_);
  }
  return true;
#else
  (void)error_out;
  return true;
#endif
}

bool ExternalMusicHost::Seek(int64_t position_ms,
                             int64_t epoch,
                             std::string* error_out) {
  if (!impl_ || impl_->closing_.load()) {
    if (error_out != nullptr) {
      *error_out = "ExternalMusicHost is not active";
    }
    return false;
  }
  if (epoch != 0 && impl_->has_active_epoch_ && epoch < impl_->current_epoch_) {
    return true;
  }
  if (epoch != 0) {
    impl_->current_epoch_ = epoch;
    impl_->has_active_epoch_ = true;
  }
  const int64_t clamped_pos = std::max<int64_t>(0, position_ms);

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (impl_->has_pending_play_) {
    impl_->pending_seek_ms_ = clamped_pos;
    return true;
  }
  if (impl_->bridge_ready_) {
    impl_->SendSeekToBridge(clamped_pos, impl_->current_epoch_);
  }
  return true;
#else
  (void)clamped_pos;
  (void)error_out;
  return true;
#endif
}

bool ExternalMusicHost::SetVolume(double volume, std::string* error_out) {
  if (!impl_ || impl_->closing_.load()) {
    if (error_out != nullptr) {
      *error_out = "ExternalMusicHost is not active";
    }
    return false;
  }
  const double clamped =
      std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0;
  impl_->volume_ = clamped;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (impl_->bridge_ready_) {
    impl_->SendVolumeToBridge();
  }
  return true;
#else
  (void)error_out;
  return true;
#endif
}

bool ExternalMusicHost::Stop(int64_t epoch, std::string* error_out) {
  if (!impl_ || impl_->closing_.load()) {
    if (error_out != nullptr) {
      *error_out = "ExternalMusicHost is not active";
    }
    return false;
  }
  if (epoch != 0 && impl_->has_active_epoch_ && epoch < impl_->current_epoch_) {
    return true;
  }
  if (epoch != 0) {
    impl_->current_epoch_ = epoch;
    impl_->has_active_epoch_ = true;
  }
  impl_->has_pending_play_ = false;
  impl_->pending_paused_ = false;
  impl_->pending_seek_ms_ = -1;

#if defined(LUMINA_HAS_WEBVIEW2) && LUMINA_HAS_WEBVIEW2
  if (impl_->bridge_ready_) {
    impl_->SendSimpleEpochCommand("stop", impl_->current_epoch_);
  }
#else
  (void)error_out;
#endif

  ExternalPlaybackStateEvent ev;
  ev.epoch = impl_->current_epoch_;
  ev.status = "stopped";
  impl_->EmitState(ev);
  return true;
}

void ExternalMusicHost::Shutdown() {
  if (impl_) {
    impl_->Shutdown();
  }
}
