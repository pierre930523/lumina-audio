#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <algorithm>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi == 0) {
    dpi = 96;
  }
  double scale_factor = dpi / 96.0;

  int scaled_x = Scale(static_cast<int>(origin.x), scale_factor);
  int scaled_y = Scale(static_cast<int>(origin.y), scale_factor);
  int scaled_w = Scale(static_cast<int>(size.width), scale_factor);
  int scaled_h = Scale(static_cast<int>(size.height), scale_factor);

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (GetMonitorInfo(monitor, &monitor_info)) {
    const RECT& work = monitor_info.rcWork;
    const int work_w = std::max(1, static_cast<int>(work.right - work.left));
    const int work_h = std::max(1, static_cast<int>(work.bottom - work.top));

    scaled_w = std::clamp(scaled_w, 1, work_w);
    scaled_h = std::clamp(scaled_h, 1, work_h);

    const int work_left = static_cast<int>(work.left);
    const int work_top = static_cast<int>(work.top);
    const int max_x = std::max(work_left, static_cast<int>(work.right) - scaled_w);
    const int max_y = std::max(work_top, static_cast<int>(work.bottom) - scaled_h);
    scaled_x = std::clamp(scaled_x, work_left, max_x);
    scaled_y = std::clamp(scaled_y, work_top, max_y);
  }

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW, scaled_x, scaled_y,
      scaled_w, scaled_h, nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  last_monitor_ = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  last_dpi_ = FlutterDesktopGetDpiForMonitor(last_monitor_);
  if (last_dpi_ == 0) {
    last_dpi_ = 96;
  }
  RECT client_rect = GetClientArea();
  last_client_width_ = client_rect.right - client_rect.left;
  last_client_height_ = client_rect.bottom - client_rect.top;

  UpdateTheme(window);

  MARGINS margins = {0, 0, 1, 0};
  DwmExtendFrameIntoClientArea(window, &margins);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

void Win32Window::Hide() {
  if (window_handle_) {
    ShowWindow(window_handle_, SW_HIDE);
  }
}

void Win32Window::ShowAndFocus() {
  if (!window_handle_) {
    return;
  }
  if (IsIconic(window_handle_)) {
    ShowWindow(window_handle_, SW_RESTORE);
  } else {
    ShowWindow(window_handle_, SW_SHOW);
  }
  SetForegroundWindow(window_handle_);
  SetActiveWindow(window_handle_);
  if (child_content_ != nullptr) {
    SetFocus(child_content_);
  }
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE: {
      if (wparam == TRUE) {
        if (is_fullscreen_) {
          return 0;
        }
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        if (IsZoomed(hwnd)) {
          HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
          MONITORINFO monitor_info{};
          monitor_info.cbSize = sizeof(monitor_info);
          if (GetMonitorInfo(monitor, &monitor_info)) {
            params->rgrc[0] = monitor_info.rcWork;
          }
        }
        return 0;
      }
      return 0;
    }

    case WM_CLOSE:
      if (prevent_close_ && OnWindowCloseRequested()) {
        return 0;
      }
      break;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto* suggested = reinterpret_cast<RECT*>(lparam);
      if (suggested == nullptr) {
        return 0;
      }
      HMONITOR target_monitor =
          MonitorFromRect(suggested, MONITOR_DEFAULTTONEAREST);
      UINT new_dpi = HIWORD(wparam);
      if (new_dpi == 0) {
        new_dpi = FlutterDesktopGetDpiForMonitor(target_monitor);
      }
      if (new_dpi == 0) {
        new_dpi = 96;
      }

      last_monitor_ = target_monitor;
      last_dpi_ = new_dpi;

      if (is_fullscreen_) {
        MONITORINFO mi = { sizeof(mi) };
        if (GetMonitorInfo(target_monitor, &mi)) {
          SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                       mi.rcMonitor.right - mi.rcMonitor.left,
                       mi.rcMonitor.bottom - mi.rcMonitor.top,
                       SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
        }
      } else if (!IsZoomed(hwnd)) {
        LONG new_left = suggested->left;
        LONG new_top = suggested->top;
        LONG new_width = suggested->right - suggested->left;
        LONG new_height = suggested->bottom - suggested->top;

        MONITORINFO monitor_info{};
        monitor_info.cbSize = sizeof(monitor_info);
        if (GetMonitorInfo(target_monitor, &monitor_info)) {
          const RECT& work = monitor_info.rcWork;
          const LONG work_w = std::max<LONG>(1, work.right - work.left);
          const LONG work_h = std::max<LONG>(1, work.bottom - work.top);
          new_width = std::clamp<LONG>(new_width, 1, work_w);
          new_height = std::clamp<LONG>(new_height, 1, work_h);

          const LONG max_left =
              std::max<LONG>(work.left, work.right - new_width);
          const LONG max_top =
              std::max<LONG>(work.top, work.bottom - new_height);
          new_left = std::clamp<LONG>(new_left, work.left, max_left);
          new_top = std::clamp<LONG>(new_top, work.top, max_top);
        }

        SetWindowPos(hwnd, nullptr, static_cast<int>(new_left),
                     static_cast<int>(new_top), static_cast<int>(new_width),
                     static_cast<int>(new_height),
                     SWP_NOZORDER | SWP_NOACTIVATE);
      }

      SyncChildContentBounds();
      HMONITOR current_monitor =
          MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (current_monitor != nullptr) {
        last_monitor_ = current_monitor;
      }
      OnDisplayOrDpiChanged();
      return 0;
    }

    case WM_SIZE: {
      SyncChildContentBounds();
      if (wparam != SIZE_MINIMIZED) {
        RECT rect = GetClientArea();
        const LONG width = rect.right - rect.left;
        const LONG height = rect.bottom - rect.top;
        if (width != last_client_width_ || height != last_client_height_) {
          last_client_width_ = width;
          last_client_height_ = height;
          OnDisplayOrDpiChanged();
        }
      } else {
        last_client_width_ = 0;
        last_client_height_ = 0;
      }
      return 0;
    }

    case WM_WINDOWPOSCHANGED: {
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      if (dpi == 0) {
        dpi = 96;
      }
      if (monitor != last_monitor_ || dpi != last_dpi_) {
        last_monitor_ = monitor;
        last_dpi_ = dpi;
        SyncChildContentBounds();
        OnDisplayOrDpiChanged();
      }
      // Always forward WM_WINDOWPOSCHANGED to DefWindowProc so WM_SIZE and
      // WM_MOVE are synthesized.
      return DefWindowProc(hwnd, message, wparam, lparam);
    }

    case WM_DISPLAYCHANGE:
    case WM_EXITSIZEMOVE: {
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      if (dpi == 0) {
        dpi = 96;
      }
      last_monitor_ = monitor;
      last_dpi_ = dpi;
      if (is_fullscreen_) {
        MONITORINFO mi = { sizeof(mi) };
        if (GetMonitorInfo(monitor, &mi)) {
          SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                       mi.rcMonitor.right - mi.rcMonitor.left,
                       mi.rcMonitor.bottom - mi.rcMonitor.top,
                       SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
        }
      }
      SyncChildContentBounds();
      OnDisplayOrDpiChanged();
      return DefWindowProc(hwnd, message, wparam, lparam);
    }

    case WM_GETMINMAXINFO: {
      LRESULT result = DefWindowProc(hwnd, message, wparam, lparam);
      auto* min_max = reinterpret_cast<MINMAXINFO*>(lparam);
      if (min_max != nullptr) {
        HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
        if (dpi == 0) {
          dpi = 96;
        }
        MONITORINFO monitor_info{};
        monitor_info.cbSize = sizeof(monitor_info);
        if (GetMonitorInfo(monitor, &monitor_info)) {
          if (is_fullscreen_) {
            const RECT& mon = monitor_info.rcMonitor;
            const LONG mon_w = mon.right - mon.left;
            const LONG mon_h = mon.bottom - mon.top;
            min_max->ptMaxSize.x = mon_w;
            min_max->ptMaxSize.y = mon_h;
            min_max->ptMaxPosition.x = mon.left;
            min_max->ptMaxPosition.y = mon.top;
            min_max->ptMaxTrackSize.x = mon_w;
            min_max->ptMaxTrackSize.y = mon_h;
            min_max->ptMinTrackSize.x = mon_w;
            min_max->ptMinTrackSize.y = mon_h;
            return 0;
          }
          const RECT& work = monitor_info.rcWork;
          const LONG work_w = std::max<LONG>(1, work.right - work.left);
          const LONG work_h = std::max<LONG>(1, work.bottom - work.top);
          const double scale_factor = dpi / 96.0;
          LONG min_w = static_cast<LONG>(Scale(480, scale_factor));
          LONG min_h = static_cast<LONG>(Scale(380, scale_factor));
          min_w = std::clamp<LONG>(min_w, 1, work_w);
          min_h = std::clamp<LONG>(min_h, 1, work_h);
          min_max->ptMinTrackSize.x =
              std::min(std::max(min_max->ptMinTrackSize.x, min_w), work_w);
          min_max->ptMinTrackSize.y =
              std::min(std::max(min_max->ptMinTrackSize.y, min_h), work_h);
        } else {
          const double scale_factor = dpi / 96.0;
          LONG min_w = static_cast<LONG>(Scale(480, scale_factor));
          LONG min_h = static_cast<LONG>(Scale(380, scale_factor));
          min_max->ptMinTrackSize.x =
              std::max(min_max->ptMinTrackSize.x, min_w);
          min_max->ptMinTrackSize.y =
              std::max(min_max->ptMinTrackSize.y, min_h);
        }
      }
      return result;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  child_content_ = nullptr;
  last_monitor_ = nullptr;
  last_dpi_ = 96;
  last_client_width_ = -1;
  last_client_height_ = -1;
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SyncChildContentBounds();

  SetFocus(child_content_);
}

void Win32Window::SyncChildContentBounds() {
  if (window_handle_ == nullptr || child_content_ == nullptr) {
    return;
  }
  RECT frame = GetClientArea();
  const int width = std::max(0, static_cast<int>(frame.right - frame.left));
  const int height = std::max(0, static_cast<int>(frame.bottom - frame.top));
  MoveWindow(child_content_, static_cast<int>(frame.left),
             static_cast<int>(frame.top), width, height, TRUE);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SetPreventClose(bool prevent) {
  prevent_close_ = prevent;
}

bool Win32Window::PreventClose() const {
  return prevent_close_;
}

void Win32Window::ForceDestroy() {
  prevent_close_ = false;
  quit_on_close_ = true;
  if (window_handle_) {
    DestroyWindow(window_handle_);
  }
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::OnDisplayOrDpiChanged() {
  // No-op; provided for subclasses.
}

bool Win32Window::OnWindowCloseRequested() {
  return false;
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

void Win32Window::SetFullScreen(bool fullscreen) {
  if (fullscreen == is_fullscreen_) {
    return;
  }
  HWND hwnd = window_handle_;
  if (!hwnd) {
    return;
  }

  if (fullscreen) {
    saved_placement_.length = sizeof(saved_placement_);
    GetWindowPlacement(hwnd, &saved_placement_);
    saved_style_ = GetWindowLong(hwnd, GWL_STYLE);
    saved_ex_style_ = GetWindowLong(hwnd, GWL_EXSTYLE);

    // If window is currently maximized, restore to clear WS_MAXIMIZE style
    // so Windows allows covering the full screen and taskbar without snapping to work area.
    if (IsZoomed(hwnd)) {
      ShowWindow(hwnd, SW_RESTORE);
    }

    HMONITOR hMon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = { sizeof(mi) };
    GetMonitorInfo(hMon, &mi);

    is_fullscreen_ = true;

    // Clear standard overlapping/caption styles (WS_OVERLAPPEDWINDOW), frame styles,
    // and maximization/minimization states (WS_MAXIMIZE / WS_MINIMIZE) so the window
    // covers the entire monitor and taskbar without Windows treating it as maximized.
    SetWindowLong(hwnd, GWL_STYLE,
                  saved_style_ & ~(WS_OVERLAPPEDWINDOW | WS_CAPTION | WS_THICKFRAME |
                                   WS_MAXIMIZE | WS_MINIMIZE));
    SetWindowLong(hwnd, GWL_EXSTYLE,
                  saved_ex_style_ & ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE |
                                     WS_EX_CLIENTEDGE | WS_EX_STATICEDGE));

    SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                 mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);

    SyncChildContentBounds();
    OnDisplayOrDpiChanged();
  } else {
    is_fullscreen_ = false;

    SetWindowLong(hwnd, GWL_STYLE, saved_style_);
    SetWindowLong(hwnd, GWL_EXSTYLE, saved_ex_style_);
    SetWindowPlacement(hwnd, &saved_placement_);
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);

    SyncChildContentBounds();
    OnDisplayOrDpiChanged();
  }
}

bool Win32Window::IsFullScreen() const {
  return is_fullscreen_;
}
