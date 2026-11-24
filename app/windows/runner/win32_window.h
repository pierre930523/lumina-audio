#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Hides the current window without destroying it (for minimize-to-tray).
  void Hide();

  // Shows (restoring if minimized) and focuses the window.
  void ShowAndFocus();

  // Release OS resources associated with window.
  void Destroy();

  // Sets whether WM_CLOSE should be intercepted via OnWindowCloseRequested().
  void SetPreventClose(bool prevent);

  // Returns true if close prevention is enabled.
  bool PreventClose() const;

  // Forces window destruction and application exit regardless of prevent_close_.
  void ForceDestroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

  // Sets whether the window is in true Win32 fullscreen mode.
  void SetFullScreen(bool fullscreen);

  // Returns true if the window is currently in fullscreen mode.
  bool IsFullScreen() const;

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

  // Called when the window's monitor, DPI, display configuration, or client
  // size changes so subclasses can resync child rendering.
  virtual void OnDisplayOrDpiChanged();

  // Called when the window is minimized (SIZE_MINIMIZED).
  virtual void OnWindowMinimized();

  // Called when the window is restored from a minimized state.
  virtual void OnWindowRestored(bool from_minimized, bool is_maximized);

  // Called when the window's maximized state changes outside fullscreen mode.
  virtual void OnWindowMaximizeChanged(bool is_maximized);

  // Called when the top-level window gains or loses activation focus.
  virtual void OnWindowFocusChanged(bool focused);

  // Called when the window transitions to a shown, non-minimized state.
  virtual void OnWindowShown();

  // Called when WM_CLOSE is received while prevent_close_ is true.
  // Return true to suppress OS window destruction.
  virtual bool OnWindowCloseRequested();

  // Applies the 1px top DWM glass margin required for frameless shadow/border.
  void ApplyDwmFrameMargins();

  // Synchronizes child content HWND bounds to match the current client area.
  void SyncChildContentBounds(bool force_frame_sync = false);

  // Shared message-processing helpers also invoked if a subclass top-level
  // delegate consumes the message before Win32Window::MessageHandler runs.
  void HandleSizeMessage(HWND hwnd, WPARAM wparam);
  LRESULT HandleActivateMessage(HWND hwnd,
                                UINT message,
                                WPARAM wparam,
                                LPARAM lparam,
                                bool call_def_window_proc);
  LRESULT HandleShowWindowMessage(HWND hwnd,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam,
                                  bool call_def_window_proc);
  void HandleSetFocusMessage(HWND hwnd);

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;
  bool prevent_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;

  // Last observed monitor handle, DPI, and client area dimensions.
  HMONITOR last_monitor_ = nullptr;
  UINT last_dpi_ = 96;
  LONG last_client_width_ = -1;
  LONG last_client_height_ = -1;
  bool was_minimized_ = false;
  bool was_maximized_ = false;

  // True Win32 fullscreen state tracking and window geometry restoration.
  bool is_fullscreen_ = false;
  WINDOWPLACEMENT saved_placement_ = { sizeof(saved_placement_) };
  DWORD saved_style_ = 0;
  DWORD saved_ex_style_ = 0;
};

#endif  // RUNNER_WIN32_WINDOW_H_
