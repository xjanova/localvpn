#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kInstanceMutex[] = L"Local\\XmanStudio.LocalVPN.Instance";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"LocalVPN";

// One LocalVPN per desktop session: two copies would fight over the single
// virtual adapter. Returns false when another copy already owns the session
// (and brings that copy's window forward).
bool ClaimSingleInstance(bool elevated_relaunch, HANDLE* mutex) {
  *mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutex);
  DWORD error = ::GetLastError();
  if (*mutex && error != ERROR_ALREADY_EXISTS) return true;

  if (elevated_relaunch && *mutex) {
    // The non-elevated copy that started us is shutting down; wait for it.
    DWORD wait = ::WaitForSingleObject(*mutex, 15000);
    if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) return true;
  }

  // ERROR_ACCESS_DENIED means an elevated copy owns the mutex.
  HWND existing = ::FindWindowW(kWindowClass, kWindowTitle);
  if (existing) {
    ::ShowWindow(existing, SW_SHOW);
    if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
    ::SetForegroundWindow(existing);
  }
  if (*mutex) ::CloseHandle(*mutex);
  *mutex = nullptr;
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  bool elevated_relaunch =
      command_line && std::wcsstr(command_line, L"--elevated-relaunch");
  HANDLE instance_mutex = nullptr;
  if (!ClaimSingleInstance(elevated_relaunch, &instance_mutex)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(80, 60);
  Win32Window::Size size(1360, 860);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
