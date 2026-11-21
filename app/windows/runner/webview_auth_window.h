#ifndef RUNNER_WEBVIEW_AUTH_WINDOW_H_
#define RUNNER_WEBVIEW_AUTH_WINDOW_H_

#include <windows.h>

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

struct WebViewAuthRequest {
  std::wstring title;
  std::wstring initial_url;
  std::wstring cookie_domain;
  std::wstring required_host_substring;
  std::vector<std::wstring> excluded_url_substrings;
  std::vector<std::wstring> required_any_cookies;
  std::vector<std::wstring> required_all_cookies;
  std::vector<std::wstring> header_url_substrings;
  std::vector<std::wstring> capture_header_names;
  std::vector<std::wstring> capture_query_params;
  std::vector<std::wstring> required_headers;
  std::vector<std::vector<std::wstring>> required_groups;
  bool clear_session = false;
};

struct WebViewAuthResult {
  bool captured = false;
  bool cancelled = false;
  std::string cookie_header;
  std::map<std::string, std::string> cookies;
  std::map<std::string, std::string> headers;
  std::map<std::string, std::string> query_params;
  std::string captured_url;
  std::string error;
};

class WebViewAuthWindow {
 public:
  using CompletionCallback = std::function<void(const WebViewAuthResult&)>;

  static bool IsWebView2Available();

  static std::unique_ptr<WebViewAuthWindow> Open(
      HWND parent_hwnd,
      const WebViewAuthRequest& request,
      CompletionCallback on_complete,
      UINT closed_notify_msg);

  ~WebViewAuthWindow();

  WebViewAuthWindow(const WebViewAuthWindow&) = delete;
  WebViewAuthWindow& operator=(const WebViewAuthWindow&) = delete;

  void CloseCancelled();
  void CloseWithError(const std::string& error_message);
  HWND Handle() const;

 private:
  struct Impl;
  explicit WebViewAuthWindow(std::shared_ptr<Impl> impl);
  std::shared_ptr<Impl> impl_;
};

#endif  // RUNNER_WEBVIEW_AUTH_WINDOW_H_
