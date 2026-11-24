#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "external_music_host.h"
#include "webview_auth_window.h"
#include "win32_window.h"

#include <shellapi.h>
#include <wincrypt.h>

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  static constexpr UINT kTrayCallbackMessage = WM_APP + 101;
  static constexpr UINT kForceDestroyMessage = WM_APP + 102;
  static constexpr UINT kWebViewAuthClosedMessage = WM_APP + 103;
  static constexpr UINT kDeferredRedrawMessage = WM_APP + 104;
  static constexpr UINT_PTR kRestoreRedrawTimerId = 3001;
  static constexpr UINT kTrayMenuShow = 2001;
  static constexpr UINT kTrayMenuPlayPause = 2002;
  static constexpr UINT kTrayMenuPrev = 2003;
  static constexpr UINT kTrayMenuNext = 2004;
  static constexpr UINT kTrayMenuQuit = 2005;

  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  void OnDisplayOrDpiChanged() override;
  void OnWindowMinimized() override;
  void OnWindowRestored(bool from_minimized, bool is_maximized) override;
  void OnWindowMaximizeChanged(bool is_maximized) override;
  void OnWindowFocusChanged(bool focused) override;
  void OnWindowShown() override;
  bool OnWindowCloseRequested() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RefreshFlutterSurface(bool schedule_deferred_recovery);
  void InitTray();
  void UpdateTray(const std::string& tooltip_utf8,
                  const std::string& now_playing_label_utf8,
                  bool is_playing);
  void UpdateTrayFromArgs(const flutter::EncodableValue* args);
  void DestroyTray();
  void ShowTrayContextMenu(HWND hwnd);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Window management method channel.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;

  // External Apple Music playback method channel and hidden WebView2 host.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      external_playback_channel_;
  std::unique_ptr<ExternalMusicHost> external_music_host_;

  // Native Win32 system tray state.
  bool tray_active_ = false;
  bool tray_menu_open_ = false;
  NOTIFYICONDATAW tray_nid_{};
  HICON tray_icon_ = nullptr;
  std::wstring tray_tooltip_ = L"Lumina Audio";
  std::wstring now_playing_label_ = L"Lumina Audio \u2014 \u5F85\u6A5F\u4E2D";
  bool tray_is_playing_ = false;

  // Embedded WebView2 OAuth/cookie capture window.
  std::unique_ptr<WebViewAuthWindow> webview_auth_window_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
