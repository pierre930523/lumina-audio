#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>
#include <iterator>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kLuminaWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kLuminaWindowTitle[] = L"lumina_app";
constexpr wchar_t kLuminaMainWindowProp[] = L"LUMINA_AUDIO_MAIN_WINDOW";

struct EnumWindowSearchState {
  DWORD self_pid = 0;
  HWND found_hwnd = nullptr;
};

BOOL CALLBACK EnumLuminaWindowProc(HWND hwnd, LPARAM lparam) {
  auto* state = reinterpret_cast<EnumWindowSearchState*>(lparam);
  if (state == nullptr) {
    return FALSE;
  }
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0 || pid == state->self_pid) {
    return TRUE;
  }
  wchar_t class_name[64] = {};
  const int class_len = ::GetClassNameW(
      hwnd, class_name, static_cast<int>(std::size(class_name)));
  if (class_len <= 0 || ::wcscmp(class_name, kLuminaWindowClass) != 0) {
    return TRUE;
  }
  if (::GetPropW(hwnd, kLuminaMainWindowProp) != nullptr) {
    state->found_hwnd = hwnd;
    return FALSE;
  }
  return TRUE;
}

HWND FindExistingMainWindow() {
  const DWORD self_pid = ::GetCurrentProcessId();
  constexpr int kMaxAttempts = 10;
  constexpr DWORD kRetryDelayMs = 50;

  for (int attempt = 0; attempt < kMaxAttempts; ++attempt) {
    HWND hwnd = ::FindWindowW(kLuminaWindowClass, kLuminaWindowTitle);
    if (hwnd != nullptr) {
      DWORD pid = 0;
      ::GetWindowThreadProcessId(hwnd, &pid);
      if (pid != 0 && pid != self_pid) {
        return hwnd;
      }
    }

    EnumWindowSearchState state{};
    state.self_pid = self_pid;
    ::EnumWindows(EnumLuminaWindowProc, reinterpret_cast<LPARAM>(&state));
    if (state.found_hwnd != nullptr) {
      return state.found_hwnd;
    }

    if (attempt + 1 < kMaxAttempts) {
      ::Sleep(kRetryDelayMs);
    }
  }
  return nullptr;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Acquire single-instance mutex before initializing FlutterWindow/engine.
  HANDLE single_instance_mutex = ::CreateMutexW(
      nullptr, TRUE, L"Global\\LuminaAudio_SingleInstance_Mutex");
  DWORD last_err = ::GetLastError();
  bool existing_instance =
      (single_instance_mutex != nullptr && last_err == ERROR_ALREADY_EXISTS);

  if (single_instance_mutex == nullptr && last_err == ERROR_ACCESS_DENIED) {
    single_instance_mutex = ::OpenMutexW(
        SYNCHRONIZE, FALSE, L"Global\\LuminaAudio_SingleInstance_Mutex");
    if (single_instance_mutex != nullptr) {
      existing_instance = true;
    } else {
      single_instance_mutex = ::CreateMutexW(
          nullptr, TRUE, L"Local\\LuminaAudio_SingleInstance_Mutex");
      last_err = ::GetLastError();
      existing_instance =
          (single_instance_mutex != nullptr && last_err == ERROR_ALREADY_EXISTS);
    }
  }

  if (existing_instance) {
    const UINT wakeup_msg = ::RegisterWindowMessageW(L"LUMINA_AUDIO_WAKEUP");
    HWND existing_hwnd = FindExistingMainWindow();
    if (existing_hwnd != nullptr && wakeup_msg != 0) {
      DWORD existing_pid = 0;
      ::GetWindowThreadProcessId(existing_hwnd, &existing_pid);
      if (existing_pid != 0) {
        ::AllowSetForegroundWindow(existing_pid);
      }
      ::PostMessageW(existing_hwnd, wakeup_msg, 0, 0);
    }
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"lumina_app", origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
