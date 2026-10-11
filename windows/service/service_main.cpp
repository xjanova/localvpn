// LocalVPNService.exe — runs as LocalSystem and owns the Wintun adapter for
// LocalVPN.exe, so the app starts without administrator rights.
//
//   LocalVPNService.exe                   started by the service manager
//   LocalVPNService.exe --install         installer (elevated): create + start
//   LocalVPNService.exe --uninstall       installer (elevated): stop + delete
//   LocalVPNService.exe --console [--fake] [--any-client]
//                                         run in the foreground (tests);
//                                         --fake echoes injected packets back
//                                         instead of opening Wintun
//
// Protocol: windows/runner/service_protocol.h. One client at a time; when it
// disconnects (the app closed or crashed) the adapter is torn down.
#include <windows.h>
#include <sddl.h>

#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../runner/service_protocol.h"
#include "../runner/tunnel_backend.h"
#include "../runner/vpn_tunnel.h"

namespace {

SERVICE_STATUS_HANDLE g_status_handle = nullptr;
SERVICE_STATUS g_status{};
HANDLE g_stop = nullptr;
bool g_fake = false;
bool g_any_client = false;

void Log(const wchar_t* format, ...) {
  wchar_t line[512];
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(line, _TRUNCATE, format, args);
  va_end(args);
  OutputDebugStringW(line);
  OutputDebugStringW(L"\n");
  if (GetConsoleWindow()) fwprintf(stderr, L"%s\n", line);
}

// Echoes every injected packet back as if the adapter had sent it: lets the
// pipe protocol be tested without administrator rights.
class FakeTunnel : public TunnelBackend {
 public:
  std::wstring Start(const std::string&, const std::string&, WakeCallback wake,
                     FailCallback, std::string*) override {
    wake_ = std::move(wake);
    running_ = true;
    return L"";
  }
  void Stop() override { running_ = false; }
  bool IsRunning() const override { return running_; }
  bool Inject(const uint8_t* data, size_t size) override {
    bool was_empty;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      was_empty = queue_.empty();
      queue_.emplace_back(data, data + size);
    }
    ++count_;
    if (was_empty && wake_) wake_();
    return true;
  }
  void TakePackets(std::vector<Packet>* out) override {
    std::lock_guard<std::mutex> lock(mutex_);
    out->swap(queue_);
  }
  uint64_t packets_in() const override { return count_; }
  uint64_t packets_out() const override { return count_; }
  uint64_t packets_dropped() const override { return 0; }

 private:
  std::mutex mutex_;
  std::vector<Packet> queue_;
  WakeCallback wake_;
  std::atomic<bool> running_{false};
  std::atomic<uint64_t> count_{0};
};

// One connected app.
class Session {
 public:
  explicit Session(HANDLE pipe) : pipe_(pipe) {
    end_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (g_fake) {
      tunnel_ = std::make_unique<FakeTunnel>();
    } else {
      tunnel_ = std::make_unique<VpnTunnel>();
    }
  }

  ~Session() {
    SetEvent(end_);
    tunnel_->Stop();
    if (pump_.joinable()) pump_.join();
    CloseHandle(end_);
    CloseHandle(wake_);
  }

  void Run() {
    pump_ = std::thread(&Session::Pump, this);
    HANDLE cancel = g_stop;
    uint8_t type = 0;
    std::vector<uint8_t> payload;
    while (lvsvc::ReadMessage(pipe_, &type, &payload, cancel)) {
      switch (type) {
        case lvsvc::kHello: {
          const uint32_t v = lvsvc::kVersion;
          Write(lvsvc::kHelloReply, reinterpret_cast<const uint8_t*>(&v), 4);
          break;
        }
        case lvsvc::kStart: {
          std::string text(payload.begin(), payload.end());
          size_t nl = text.find('\n');
          std::string code;
          std::wstring error =
              nl == std::string::npos
                  ? L"ข้อมูลวงเครือข่ายไม่ครบ"
                  : tunnel_->Start(
                        text.substr(0, nl), text.substr(nl + 1),
                        [this] { SetEvent(wake_); },
                        [this](const std::wstring& message) {
                          Write(lvsvc::kFailed, lvsvc::ToUtf8(message));
                        },
                        &code);
          std::string reply(1, error.empty() ? '\x01' : '\x00');
          if (!error.empty()) {
            reply += (code.empty() ? "TUN_FAILED" : code) + "\n" +
                     lvsvc::ToUtf8(error);
          }
          Write(lvsvc::kResult, reinterpret_cast<const uint8_t*>(reply.data()),
                reply.size());
          Log(L"start %S: %s", text.substr(0, nl).c_str(),
              error.empty() ? L"ok" : error.c_str());
          break;
        }
        case lvsvc::kStop:
          tunnel_->Stop();
          Write(lvsvc::kResult, reinterpret_cast<const uint8_t*>("\x01"), 1);
          break;
        case lvsvc::kInject:
          if (!payload.empty()) tunnel_->Inject(payload.data(), payload.size());
          break;
        default:
          break;  // unknown: newer app, ignore
      }
    }
  }

 private:
  void Write(uint8_t type, const uint8_t* data, size_t size) {
    std::lock_guard<std::mutex> lock(write_mutex_);
    lvsvc::WriteMessage(pipe_, type, data, size, end_);
  }
  void Write(uint8_t type, const std::string& text) {
    Write(type, reinterpret_cast<const uint8_t*>(text.data()), text.size());
  }

  // Packets from the adapter → the app, in batches of up to ~60 KB.
  void Pump() {
    HANDLE waits[2] = {wake_, end_};
    std::vector<TunnelBackend::Packet> packets;
    std::vector<uint8_t> batch;
    while (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0) {
      packets.clear();
      tunnel_->TakePackets(&packets);
      batch.clear();
      for (const auto& p : packets) {
        if (p.empty() || p.size() > 0xFFFF) continue;
        if (batch.size() + 2 + p.size() > 60000) {
          Write(lvsvc::kPackets, batch.data(), batch.size());
          batch.clear();
        }
        batch.push_back(static_cast<uint8_t>(p.size() & 0xFF));
        batch.push_back(static_cast<uint8_t>(p.size() >> 8));
        batch.insert(batch.end(), p.begin(), p.end());
      }
      if (!batch.empty()) Write(lvsvc::kPackets, batch.data(), batch.size());
    }
  }

  HANDLE pipe_;
  HANDLE end_;
  HANDLE wake_;
  std::unique_ptr<TunnelBackend> tunnel_;
  std::thread pump_;
  std::mutex write_mutex_;
};

// SYSTEM and administrators: full; signed-in users: read/write. Remote
// clients are refused by the pipe mode.
bool PipeSecurity(SECURITY_ATTRIBUTES* sa) {
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1, &sd,
          nullptr)) {
    return false;
  }
  sa->nLength = sizeof(*sa);
  sa->lpSecurityDescriptor = sd;
  sa->bInheritHandle = FALSE;
  return true;
}

bool ClientAllowed(HANDLE pipe) {
  if (g_any_client) return true;
  ULONG pid = 0;
  if (!GetNamedPipeClientProcessId(pipe, &pid)) return false;
  const std::wstring image = lvsvc::ProcessImage(pid);
  const std::wstring expected = lvsvc::OwnFolder() + lvsvc::kAppExe;
  if (lvsvc::SamePath(image, expected)) return true;
  Log(L"refused client %s", image.c_str());
  return false;
}

void Serve() {
  SECURITY_ATTRIBUTES sa{};
  if (!PipeSecurity(&sa)) {
    Log(L"pipe security failed: %lu", GetLastError());
    return;
  }
  while (WaitForSingleObject(g_stop, 0) != WAIT_OBJECT_0) {
    // FIRST_PIPE_INSTANCE: if another process squatted the name, fail
    // instead of sharing it.
    HANDLE pipe = CreateNamedPipeW(
        lvsvc::kPipeName,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
            PIPE_REJECT_REMOTE_CLIENTS,
        1, 256 * 1024, 256 * 1024, 0, &sa);
    if (pipe == INVALID_HANDLE_VALUE) {
      Log(L"CreateNamedPipe failed: %lu", GetLastError());
      if (WaitForSingleObject(g_stop, 2000) == WAIT_OBJECT_0) break;
      continue;
    }
    OVERLAPPED ov{};
    ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    BOOL connected = ConnectNamedPipe(pipe, &ov);
    DWORD err = connected ? ERROR_PIPE_CONNECTED : GetLastError();
    if (err == ERROR_IO_PENDING) {
      HANDLE waits[2] = {ov.hEvent, g_stop};
      if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0) {
        DWORD n;
        err = GetOverlappedResult(pipe, &ov, &n, FALSE) ? ERROR_PIPE_CONNECTED
                                                       : GetLastError();
      } else {
        CancelIoEx(pipe, &ov);
        err = ERROR_OPERATION_ABORTED;
      }
    }
    CloseHandle(ov.hEvent);
    if (err == ERROR_PIPE_CONNECTED && ClientAllowed(pipe)) {
      Session session(pipe);
      session.Run();
    }
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
  }
  LocalFree(sa.lpSecurityDescriptor);
}

void ReportStatus(DWORD state, DWORD exit_code = NO_ERROR) {
  g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_status.dwCurrentState = state;
  g_status.dwWin32ExitCode = exit_code;
  g_status.dwControlsAccepted =
      state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
                               : 0;
  g_status.dwWaitHint = state == SERVICE_START_PENDING ? 5000 : 0;
  SetServiceStatus(g_status_handle, &g_status);
}

DWORD WINAPI ControlHandler(DWORD control, DWORD, void*, void*) {
  if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
    ReportStatus(SERVICE_STOP_PENDING);
    SetEvent(g_stop);
    return NO_ERROR;
  }
  return control == SERVICE_CONTROL_INTERROGATE ? NO_ERROR
                                                : ERROR_CALL_NOT_IMPLEMENTED;
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
  g_status_handle = RegisterServiceCtrlHandlerExW(lvsvc::kServiceName,
                                                  ControlHandler, nullptr);
  if (!g_status_handle) return;
  ReportStatus(SERVICE_START_PENDING);
  ReportStatus(SERVICE_RUNNING);
  Serve();
  ReportStatus(SERVICE_STOPPED);
}

int Install() {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CREATE_SERVICE);
  if (!scm) return static_cast<int>(GetLastError());
  const std::wstring path =
      L"\"" + lvsvc::OwnFolder() + lvsvc::kServiceExe + L"\"";
  SC_HANDLE svc = CreateServiceW(
      scm, lvsvc::kServiceName, L"LocalVPN Service", SERVICE_ALL_ACCESS,
      SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
      path.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr);
  if (!svc && GetLastError() == ERROR_SERVICE_EXISTS) {
    svc = OpenServiceW(scm, lvsvc::kServiceName, SERVICE_ALL_ACCESS);
    if (svc) {
      ChangeServiceConfigW(svc, SERVICE_NO_CHANGE, SERVICE_AUTO_START,
                           SERVICE_NO_CHANGE, path.c_str(), nullptr, nullptr,
                           nullptr, nullptr, nullptr, L"LocalVPN Service");
    }
  }
  if (!svc) {
    DWORD e = GetLastError();
    CloseServiceHandle(scm);
    return static_cast<int>(e);
  }
  wchar_t description[] =
      L"การ์ดเครือข่ายเสมือนของ LocalVPN — ให้แอปเปิดได้โดยไม่ต้องขอสิทธิ์ผู้ดูแลทุกครั้ง";
  SERVICE_DESCRIPTIONW desc{description};
  ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, &desc);
  SC_ACTION actions[3] = {{SC_ACTION_RESTART, 5000},
                          {SC_ACTION_RESTART, 5000},
                          {SC_ACTION_RESTART, 30000}};
  SERVICE_FAILURE_ACTIONSW failure{86400, nullptr, nullptr, 3, actions};
  ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS, &failure);
  StartServiceW(svc, 0, nullptr);
  CloseServiceHandle(svc);
  CloseServiceHandle(scm);
  return 0;
}

int Uninstall() {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!scm) return static_cast<int>(GetLastError());
  SC_HANDLE svc = OpenServiceW(scm, lvsvc::kServiceName,
                               SERVICE_STOP | SERVICE_QUERY_STATUS | DELETE);
  if (!svc) {
    DWORD e = GetLastError();
    CloseServiceHandle(scm);
    return e == ERROR_SERVICE_DOES_NOT_EXIST ? 0 : static_cast<int>(e);
  }
  SERVICE_STATUS status{};
  ControlService(svc, SERVICE_CONTROL_STOP, &status);
  for (int i = 0; i < 50; ++i) {
    if (!QueryServiceStatus(svc, &status) ||
        status.dwCurrentState == SERVICE_STOPPED) {
      break;
    }
    Sleep(100);
  }
  DeleteService(svc);
  CloseServiceHandle(svc);
  CloseServiceHandle(scm);
  return 0;
}

BOOL WINAPI ConsoleHandler(DWORD) {
  SetEvent(g_stop);
  return TRUE;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  bool console = false;
  for (int i = 1; i < argc; ++i) {
    const std::wstring a = argv[i];
    if (a == L"--install") return Install();
    if (a == L"--uninstall") return Uninstall();
    if (a == L"--console") console = true;
    if (a == L"--fake") g_fake = true;
    if (a == L"--any-client") g_any_client = true;
  }
  g_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (console) {
    SetConsoleCtrlHandler(ConsoleHandler, TRUE);
    Log(L"LocalVPNService console mode%s%s", g_fake ? L" (fake tunnel)" : L"",
        g_any_client ? L" (any client)" : L"");
    Serve();
    return 0;
  }
  g_fake = false;
  g_any_client = false;
  SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<wchar_t*>(lvsvc::kServiceName), ServiceMain}, {nullptr, nullptr}};
  return StartServiceCtrlDispatcherW(table) ? 0 : static_cast<int>(GetLastError());
}
