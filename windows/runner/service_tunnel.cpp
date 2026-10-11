#include "service_tunnel.h"

#include "service_protocol.h"

namespace {

constexpr size_t kMaxQueue = 4096;

std::string Utf8(const uint8_t* data, size_t size) {
  return std::string(reinterpret_cast<const char*>(data), size);
}

// The pipe's server is the installed LocalVPNService and that service runs
// |expected|. Asked from the service manager: a normal user can't open a
// LocalSystem process to read its image, but may query a service, and only
// an administrator can create or change one.
bool ServerIsOurService(ULONG pid, const std::wstring& expected) {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!scm) return false;
  bool ok = false;
  SC_HANDLE svc = OpenServiceW(scm, lvsvc::kServiceName,
                               SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG);
  if (svc) {
    SERVICE_STATUS_PROCESS status{};
    DWORD needed = 0;
    if (QueryServiceStatusEx(svc, SC_STATUS_PROCESS_INFO,
                             reinterpret_cast<LPBYTE>(&status), sizeof(status),
                             &needed) &&
        status.dwProcessId == pid) {
      QueryServiceConfigW(svc, nullptr, 0, &needed);
      std::vector<uint8_t> buffer(needed);
      auto* config = reinterpret_cast<QUERY_SERVICE_CONFIGW*>(buffer.data());
      if (needed &&
          QueryServiceConfigW(svc, config, needed, &needed) &&
          config->lpBinaryPathName) {
        std::wstring path = config->lpBinaryPathName;
        if (!path.empty() && path[0] == L'"') {
          path = path.substr(1, path.find(L'"', 1) - 1);
        }
        ok = lvsvc::SamePath(path, expected);
      }
    }
    CloseServiceHandle(svc);
  }
  CloseServiceHandle(scm);
  return ok;
}

}  // namespace

ServiceTunnel::ServiceTunnel(std::wstring expected_server)
    : expected_server_(expected_server.empty()
                           ? lvsvc::OwnFolder() + lvsvc::kServiceExe
                           : std::move(expected_server)) {}

ServiceTunnel::~ServiceTunnel() { Stop(); }

bool ServiceTunnel::Available() {
  // Listening = the pipe exists (WaitNamedPipe returns at once either way
  // with a 1 ms timeout: true when an instance is free, ERROR_SEM_TIMEOUT
  // when it is busy, ERROR_FILE_NOT_FOUND when there is no server).
  if (WaitNamedPipeW(lvsvc::kPipeName, 1)) return true;
  return GetLastError() == ERROR_SEM_TIMEOUT;
}

std::wstring ServiceTunnel::Start(const std::string& virtual_ip,
                                  const std::string& subnet, WakeCallback wake,
                                  FailCallback fail, std::string* error_code) {
  Stop();
  auto fail_with = [&](const char* code, const std::wstring& message) {
    if (error_code) *error_code = code;
    Close();
    return message;
  };

  // The service serves one client and recreates the pipe after each: right
  // after a stop it may be busy closing (PIPE_BUSY) or not there for a
  // moment (FILE_NOT_FOUND). Wait up to ~3 s.
  for (int attempt = 0; attempt < 30; ++attempt) {
    pipe_ = CreateFileW(lvsvc::kPipeName, GENERIC_READ | GENERIC_WRITE, 0,
                        nullptr, OPEN_EXISTING,
                        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                            SECURITY_IDENTIFICATION,
                        nullptr);
    if (pipe_ != INVALID_HANDLE_VALUE) break;
    const DWORD err = GetLastError();
    if (err == ERROR_PIPE_BUSY) {
      WaitNamedPipeW(lvsvc::kPipeName, 100);
    } else if (err == ERROR_FILE_NOT_FOUND) {
      Sleep(100);
    } else {
      break;
    }
  }
  if (pipe_ == INVALID_HANDLE_VALUE) {
    return fail_with("SERVICE_UNAVAILABLE",
                     L"ไม่พบบริการ LocalVPN Service — ติดตั้งโปรแกรมใหม่ "
                     L"หรือเปิดแบบผู้ดูแลระบบ");
  }

  // Only our own service may receive the LAN's packets.
  ULONG server_pid = 0;
  if (!GetNamedPipeServerProcessId(pipe_, &server_pid) ||
      !(lvsvc::SamePath(lvsvc::ProcessImage(server_pid), expected_server_) ||
        ServerIsOurService(server_pid, expected_server_))) {
    return fail_with("SERVICE_UNTRUSTED",
                     L"บริการ LocalVPN ที่พบไม่ใช่ของโปรแกรมนี้ — ติดตั้งใหม่");
  }

  quit_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  uint8_t type = 0;
  std::vector<uint8_t> payload;
  const uint32_t version = lvsvc::kVersion;
  if (!lvsvc::WriteMessage(pipe_, lvsvc::kHello,
                           reinterpret_cast<const uint8_t*>(&version), 4,
                           quit_) ||
      !lvsvc::ReadMessage(pipe_, &type, &payload, quit_) ||
      type != lvsvc::kHelloReply || payload.size() < 4) {
    return fail_with("SERVICE_REFUSED",
                     L"บริการ LocalVPN ไม่ตอบ — ลองเปิดโปรแกรมใหม่");
  }

  if (!lvsvc::WriteMessage(pipe_, lvsvc::kStart, virtual_ip + "\n" + subnet,
                           quit_) ||
      !lvsvc::ReadMessage(pipe_, &type, &payload, quit_) ||
      type != lvsvc::kResult || payload.empty()) {
    return fail_with("SERVICE_FAILED", L"บริการ LocalVPN ไม่ตอบ");
  }
  if (payload[0] != 1) {
    std::string text = Utf8(payload.data() + 1, payload.size() - 1);
    size_t nl = text.find('\n');
    std::string code = nl == std::string::npos ? "TUN_FAILED" : text.substr(0, nl);
    std::string message = nl == std::string::npos ? text : text.substr(nl + 1);
    if (error_code) *error_code = code;
    Close();
    return lvsvc::FromUtf8(message);
  }

  wake_ = std::move(wake);
  fail_ = std::move(fail);
  running_ = true;
  reader_ = std::thread(&ServiceTunnel::ReaderLoop, this);
  return L"";
}

void ServiceTunnel::ReaderLoop() {
  uint8_t type = 0;
  std::vector<uint8_t> payload;
  while (lvsvc::ReadMessage(pipe_, &type, &payload, quit_)) {
    if (type == lvsvc::kPackets) {
      bool was_empty;
      {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        was_empty = queue_.empty();
        size_t i = 0;
        while (i + 2 <= payload.size()) {
          const size_t len = payload[i] | (payload[i + 1] << 8);
          i += 2;
          if (len == 0 || i + len > payload.size()) break;
          if (queue_.size() < kMaxQueue) {
            queue_.emplace_back(payload.begin() + i, payload.begin() + i + len);
            ++packets_in_;
          } else {
            ++packets_dropped_;
          }
          i += len;
        }
      }
      if (was_empty && wake_) wake_();
    } else if (type == lvsvc::kFailed) {
      running_ = false;
      if (fail_) fail_(lvsvc::FromUtf8(Utf8(payload.data(), payload.size())));
      return;
    }
  }
  // The pipe broke without a word: the service stopped or restarted.
  if (running_.exchange(false) && WaitForSingleObject(quit_, 0) != WAIT_OBJECT_0 &&
      fail_) {
    fail_(L"บริการ LocalVPN หยุดทำงาน — กดเชื่อมต่อใหม่อีกครั้ง");
  }
}

bool ServiceTunnel::Inject(const uint8_t* data, size_t size) {
  if (!running_ || size == 0 || size > 0xFFFF) return false;
  std::lock_guard<std::mutex> lock(write_mutex_);
  if (!lvsvc::WriteMessage(pipe_, lvsvc::kInject, data, size, quit_)) {
    ++packets_dropped_;
    return false;
  }
  ++packets_out_;
  return true;
}

void ServiceTunnel::TakePackets(std::vector<Packet>* out) {
  std::lock_guard<std::mutex> lock(queue_mutex_);
  if (out->empty()) {
    out->swap(queue_);
  } else {
    for (auto& p : queue_) out->push_back(std::move(p));
    queue_.clear();
  }
}

void ServiceTunnel::Stop() {
  // Closing the pipe is the stop: the service tears the adapter down when
  // its client goes away.
  running_ = false;
  if (quit_) SetEvent(quit_);
  if (pipe_ != INVALID_HANDLE_VALUE) CancelIoEx(pipe_, nullptr);
  if (reader_.joinable()) reader_.join();
  Close();
  std::lock_guard<std::mutex> lock(queue_mutex_);
  queue_.clear();
}

void ServiceTunnel::Close() {
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
  if (quit_) {
    CloseHandle(quit_);
    quit_ = nullptr;
  }
}
