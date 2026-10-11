#ifndef RUNNER_SERVICE_PROTOCOL_H_
#define RUNNER_SERVICE_PROTOCOL_H_

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// LocalVPN.exe (not elevated) and LocalVPNService.exe (LocalSystem) talk over
// one named pipe, byte mode, both ends overlapped. Every message:
//
//   u32 length (little endian, of type + payload) | u8 type | payload
//
// The service accepts only LocalVPN.exe from its own folder; the app accepts
// only LocalVPNService.exe from its own folder as the pipe's server.
namespace lvsvc {

constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\LocalVPN.Service.1";
constexpr wchar_t kServiceName[] = L"LocalVPNService";
constexpr wchar_t kServiceExe[] = L"LocalVPNService.exe";
constexpr wchar_t kAppExe[] = L"LocalVPN.exe";
constexpr uint32_t kVersion = 1;
constexpr uint32_t kMaxMessage = 1u << 20;

enum MessageType : uint8_t {
  // app → service
  kHello = 0x01,   // u32 version
  kStart = 0x02,   // "virtual_ip\nsubnet"
  kStop = 0x03,
  kInject = 0x04,  // one IPv4 packet
  // service → app
  kHelloReply = 0x81,  // u32 version
  kResult = 0x82,      // u8 ok | "code\nmessage" (UTF-8)
  kPackets = 0x83,     // repeated: u16 length | packet
  kFailed = 0x84,      // message (UTF-8): the session died on its own
};

// Reads or writes exactly |size| bytes. False on EOF, error or |cancel|.
inline bool PipeIo(HANDLE pipe, bool write, uint8_t* buffer, DWORD size,
                   HANDLE cancel) {
  OVERLAPPED ov{};
  ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ov.hEvent) return false;
  DWORD total = 0;
  bool ok = true;
  while (ok && total < size) {
    ResetEvent(ov.hEvent);
    DWORD n = 0;
    BOOL done = write
                    ? WriteFile(pipe, buffer + total, size - total, &n, &ov)
                    : ReadFile(pipe, buffer + total, size - total, &n, &ov);
    if (!done) {
      if (GetLastError() != ERROR_IO_PENDING) {
        ok = false;
        break;
      }
      HANDLE waits[2] = {ov.hEvent, cancel};
      DWORD w = WaitForMultipleObjects(cancel ? 2 : 1, waits, FALSE, INFINITE);
      if (w != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &ov);
        GetOverlappedResult(pipe, &ov, &n, TRUE);
        ok = false;
        break;
      }
      if (!GetOverlappedResult(pipe, &ov, &n, FALSE)) {
        ok = false;
        break;
      }
    }
    if (n == 0) {
      ok = false;  // the other end closed
      break;
    }
    total += n;
  }
  CloseHandle(ov.hEvent);
  return ok;
}

inline bool WriteMessage(HANDLE pipe, uint8_t type, const uint8_t* data,
                         size_t size, HANDLE cancel) {
  if (size + 1 > kMaxMessage) return false;
  std::vector<uint8_t> frame(5 + size);
  const uint32_t length = static_cast<uint32_t>(size + 1);
  memcpy(frame.data(), &length, 4);
  frame[4] = type;
  if (size) memcpy(frame.data() + 5, data, size);
  return PipeIo(pipe, true, frame.data(), static_cast<DWORD>(frame.size()),
                cancel);
}

inline bool WriteMessage(HANDLE pipe, uint8_t type, const std::string& text,
                         HANDLE cancel) {
  return WriteMessage(pipe, type, reinterpret_cast<const uint8_t*>(text.data()),
                      text.size(), cancel);
}

inline bool ReadMessage(HANDLE pipe, uint8_t* type,
                        std::vector<uint8_t>* payload, HANDLE cancel) {
  uint8_t header[5];
  if (!PipeIo(pipe, false, header, 5, cancel)) return false;
  uint32_t length = 0;
  memcpy(&length, header, 4);
  if (length == 0 || length > kMaxMessage) return false;
  *type = header[4];
  payload->resize(length - 1);
  return length == 1 ||
         PipeIo(pipe, false, payload->data(), length - 1, cancel);
}

inline std::string ToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()),
                              nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()),
                      out.data(), n, nullptr, nullptr);
  return out;
}

inline std::wstring FromUtf8(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                              nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), n);
  return out;
}

// Folder of the running executable, with a trailing backslash.
inline std::wstring OwnFolder() {
  wchar_t path[MAX_PATH * 2] = {0};
  DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH * 2);
  std::wstring s(path, n);
  return s.substr(0, s.find_last_of(L'\\') + 1);
}

// Full image path of process |pid|, empty when it can't be read.
inline std::wstring ProcessImage(DWORD pid) {
  HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!p) return {};
  wchar_t path[MAX_PATH * 2] = {0};
  DWORD n = MAX_PATH * 2;
  std::wstring out;
  if (QueryFullProcessImageNameW(p, 0, path, &n)) out.assign(path, n);
  CloseHandle(p);
  return out;
}

inline bool SamePath(const std::wstring& a, const std::wstring& b) {
  return !a.empty() && CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1,
                                            TRUE) == CSTR_EQUAL;
}

}  // namespace lvsvc

#endif  // RUNNER_SERVICE_PROTOCOL_H_
