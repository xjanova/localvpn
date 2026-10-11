// winsock2 must come before windows.h.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#include <shellapi.h>

#include "native_channels.h"

#include <flutter/standard_method_codec.h>

#include <chrono>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::string ToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                static_cast<int>(wide.size()), nullptr, 0,
                                nullptr, nullptr);
  std::string out(len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      out.data(), len, nullptr, nullptr);
  return out;
}

const EncodableMap* ArgsMap(const flutter::MethodCall<EncodableValue>& call) {
  return std::get_if<EncodableMap>(call.arguments());
}

std::string GetString(const EncodableMap* map, const char* key) {
  if (!map) return std::string();
  auto it = map->find(EncodableValue(key));
  if (it == map->end()) return std::string();
  auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}

int GetInt(const EncodableMap* map, const char* key, int fallback) {
  if (!map) return fallback;
  auto it = map->find(EncodableValue(key));
  if (it == map->end()) return fallback;
  if (auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (auto* v = std::get_if<int64_t>(&it->second)) return static_cast<int>(*v);
  return fallback;
}

// Runs |fn| on the thread that owns |window| (the platform thread).
void PostRun(HWND window, std::function<void()> fn) {
  auto* heap = new std::function<void()>(std::move(fn));
  if (!PostMessage(window, NativeChannels::kWmRun, 0,
                   reinterpret_cast<LPARAM>(heap))) {
    delete heap;
  }
}

bool IsProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  bool elevated = GetTokenInformation(token, TokenElevation, &elevation,
                                      sizeof(elevation), &size) &&
                  elevation.TokenIsElevated;
  CloseHandle(token);
  return elevated;
}

// Sends |count| ICMP echo requests. Entries are round-trip ms or -1.
EncodableMap IcmpPing(const std::string& host, int count, int timeout_ms) {
  EncodableMap out;
  WSADATA wsa;
  bool wsa_ok = WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
  addrinfo hints{};
  hints.ai_family = AF_INET;
  addrinfo* res = nullptr;
  if (getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) {
    if (wsa_ok) WSACleanup();
    out[EncodableValue("ok")] = EncodableValue(false);
    out[EncodableValue("error")] = EncodableValue("resolve");
    return out;
  }
  IN_ADDR dest = reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr;
  freeaddrinfo(res);
  char ip_text[INET_ADDRSTRLEN] = {0};
  InetNtopA(AF_INET, &dest, ip_text, sizeof(ip_text));

  EncodableList rtts;
  HANDLE icmp = IcmpCreateFile();
  if (icmp != INVALID_HANDLE_VALUE) {
    char payload[32] = "LocalVPN latency probe";
    std::vector<BYTE> reply(sizeof(ICMP_ECHO_REPLY) + sizeof(payload) + 64);
    for (int i = 0; i < count; i++) {
      auto start = std::chrono::steady_clock::now();
      DWORD n = IcmpSendEcho(icmp, dest.S_un.S_addr, payload, sizeof(payload),
                             nullptr, reply.data(),
                             static_cast<DWORD>(reply.size()), timeout_ms);
      auto* r = reinterpret_cast<PICMP_ECHO_REPLY>(reply.data());
      if (n > 0 && r->Status == IP_SUCCESS) {
        // RoundTripTime has 1 ms resolution; use our own clock below 1 ms.
        double measured = std::chrono::duration<double, std::milli>(
                              std::chrono::steady_clock::now() - start)
                              .count();
        double rtt = r->RoundTripTime > 0 ? r->RoundTripTime : measured;
        rtts.push_back(EncodableValue(rtt));
      } else {
        rtts.push_back(EncodableValue(-1.0));
      }
      if (i + 1 < count) Sleep(150);
    }
    IcmpCloseHandle(icmp);
  }
  if (wsa_ok) WSACleanup();
  out[EncodableValue("ok")] = EncodableValue(true);
  out[EncodableValue("ip")] = EncodableValue(std::string(ip_text));
  out[EncodableValue("rtts")] = EncodableValue(rtts);
  return out;
}

// The adapter Windows would use to reach the internet right now.
EncodableValue ActiveAdapter() {
  sockaddr_in probe{};
  probe.sin_family = AF_INET;
  InetPtonA(AF_INET, "1.1.1.1", &probe.sin_addr);
  DWORD index = 0;
  if (GetBestInterfaceEx(reinterpret_cast<sockaddr*>(&probe), &index) !=
      NO_ERROR) {
    return EncodableValue();
  }
  ULONG size = 16 * 1024;
  std::vector<BYTE> buffer(size);
  ULONG flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_DNS_SERVER |
                GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_ANYCAST;
  auto* addrs = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
  ULONG rc = GetAdaptersAddresses(AF_INET, flags, nullptr, addrs, &size);
  if (rc == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size);
    addrs = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
    rc = GetAdaptersAddresses(AF_INET, flags, nullptr, addrs, &size);
  }
  if (rc != NO_ERROR) return EncodableValue();
  for (auto* a = addrs; a; a = a->Next) {
    if (a->IfIndex != index) continue;
    EncodableMap m;
    m[EncodableValue("name")] = EncodableValue(ToUtf8(a->FriendlyName));
    m[EncodableValue("description")] = EncodableValue(ToUtf8(a->Description));
    m[EncodableValue("guid")] = EncodableValue(std::string(a->AdapterName));
    std::string type = "other";
    if (a->IfType == IF_TYPE_IEEE80211) type = "wifi";
    if (a->IfType == IF_TYPE_ETHERNET_CSMACD) type = "ethernet";
    m[EncodableValue("type")] = EncodableValue(type);
    m[EncodableValue("speedMbps")] =
        EncodableValue(static_cast<int64_t>(a->TransmitLinkSpeed / 1000000));
    m[EncodableValue("mtu")] = EncodableValue(static_cast<int32_t>(a->Mtu));
    for (auto* u = a->FirstUnicastAddress; u; u = u->Next) {
      if (u->Address.lpSockaddr->sa_family != AF_INET) continue;
      char text[INET_ADDRSTRLEN] = {0};
      InetNtopA(AF_INET,
                &reinterpret_cast<sockaddr_in*>(u->Address.lpSockaddr)->sin_addr,
                text, sizeof(text));
      m[EncodableValue("ipv4")] = EncodableValue(std::string(text));
      break;
    }
    for (auto* g = a->FirstGatewayAddress; g; g = g->Next) {
      if (g->Address.lpSockaddr->sa_family != AF_INET) continue;
      char text[INET_ADDRSTRLEN] = {0};
      InetNtopA(AF_INET,
                &reinterpret_cast<sockaddr_in*>(g->Address.lpSockaddr)->sin_addr,
                text, sizeof(text));
      m[EncodableValue("gateway")] = EncodableValue(std::string(text));
      break;
    }
    return EncodableValue(m);
  }
  return EncodableValue();
}

}  // namespace

NativeChannels::NativeChannels(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window), alive_(std::make_shared<std::atomic<bool>>(true)) {
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  vpn_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "com.xjanova.localvpn/vpn", &codec);
  vpn_channel_->SetMethodCallHandler(
      [this](const Call& call, Result result) {
        OnVpnCall(call, std::move(result));
      });
  win_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "com.xjanova.localvpn/windows", &codec);
  win_channel_->SetMethodCallHandler(
      [this](const Call& call, Result result) {
        OnWindowsCall(call, std::move(result));
      });
}

NativeChannels::~NativeChannels() {
  alive_->store(false);
  tunnel_.Stop();
  vpn_channel_->SetMethodCallHandler(nullptr);
  win_channel_->SetMethodCallHandler(nullptr);
}

bool NativeChannels::HandleMessage(UINT message, WPARAM, LPARAM lparam) {
  if (message == kWmPackets) {
    DeliverPackets();
    return true;
  }
  if (message == kWmRun) {
    std::unique_ptr<std::function<void()>> fn(
        reinterpret_cast<std::function<void()>*>(lparam));
    if (fn && *fn) (*fn)();
    return true;
  }
  return false;
}

void NativeChannels::PostToPlatform(std::function<void()> fn) {
  PostRun(window_, std::move(fn));
}

void NativeChannels::DeliverPackets() {
  std::vector<VpnTunnel::Packet> packets;
  tunnel_.TakePackets(&packets);
  if (packets.empty()) return;
  EncodableList list;
  list.reserve(packets.size());
  for (auto& p : packets) list.push_back(EncodableValue(std::move(p)));
  vpn_channel_->InvokeMethod("onTunPackets",
                             std::make_unique<EncodableValue>(std::move(list)));
}

void NativeChannels::OnVpnCall(const Call& call, Result result) {
  const std::string& method = call.method_name();
  const EncodableMap* args = ArgsMap(call);

  if (method == "startVpn") {
    std::string ip = GetString(args, "virtualIp");
    std::string subnet = GetString(args, "subnet");
    if (ip.empty() || subnet.empty()) {
      result->Error("INVALID_ARGS", "virtualIp and subnet are required");
      return;
    }
    HWND window = window_;
    auto alive = alive_;
    std::string code;
    std::wstring error = tunnel_.Start(
        ip, subnet,
        [window]() { PostMessage(window, kWmPackets, 0, 0); },
        [this, window, alive](const std::wstring& message) {
          std::string text = ToUtf8(message);
          PostRun(window, [this, alive, text]() {
            if (!alive->load()) return;
            tunnel_.Stop();
            vpn_channel_->InvokeMethod(
                "onVpnError", std::make_unique<EncodableValue>(text));
          });
        },
        &code);
    if (!error.empty()) {
      result->Error(code, ToUtf8(error));
      return;
    }
    result->Success(EncodableValue(true));
    vpn_channel_->InvokeMethod("onVpnStatusChanged",
                               std::make_unique<EncodableValue>("connected"));
    return;
  }

  if (method == "stopVpn") {
    bool was_running = tunnel_.IsRunning();
    tunnel_.Stop();
    result->Success(EncodableValue(true));
    if (was_running) {
      vpn_channel_->InvokeMethod(
          "onVpnStatusChanged",
          std::make_unique<EncodableValue>("disconnected"));
    }
    return;
  }

  if (method == "getVpnStatus") {
    result->Success(EncodableValue(
        std::string(tunnel_.IsRunning() ? "connected" : "disconnected")));
    return;
  }

  if (method == "injectPacket") {
    bool ok = false;
    if (args) {
      auto it = args->find(EncodableValue("data"));
      if (it != args->end()) {
        if (auto* data = std::get_if<std::vector<uint8_t>>(&it->second)) {
          ok = tunnel_.Inject(data->data(), data->size());
        }
      }
    }
    result->Success(EncodableValue(ok));
    return;
  }

  if (method == "getStats") {
    EncodableMap m;
    m[EncodableValue("running")] = EncodableValue(tunnel_.IsRunning());
    m[EncodableValue("packetsIn")] =
        EncodableValue(static_cast<int64_t>(tunnel_.packets_in()));
    m[EncodableValue("packetsOut")] =
        EncodableValue(static_cast<int64_t>(tunnel_.packets_out()));
    m[EncodableValue("packetsDropped")] =
        EncodableValue(static_cast<int64_t>(tunnel_.packets_dropped()));
    result->Success(EncodableValue(m));
    return;
  }

  result->NotImplemented();
}

void NativeChannels::OnWindowsCall(const Call& call, Result result) {
  const std::string& method = call.method_name();
  const EncodableMap* args = ArgsMap(call);

  if (method == "isElevated") {
    result->Success(EncodableValue(IsProcessElevated()));
    return;
  }

  if (method == "relaunchAsAdmin") {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_NOASYNC;
    info.lpVerb = L"runas";
    info.lpFile = path;
    info.lpParameters = L"--elevated-relaunch";
    info.nShow = SW_SHOWNORMAL;
    // false = the user said no to the UAC prompt.
    result->Success(EncodableValue(ShellExecuteExW(&info) == TRUE));
    return;
  }

  if (method == "quit") {
    result->Success(EncodableValue(true));
    PostQuitMessage(0);
    return;
  }

  if (method == "icmpPing") {
    std::string host = GetString(args, "host");
    int count = GetInt(args, "count", 4);
    int timeout = GetInt(args, "timeoutMs", 1000);
    if (host.empty() || count < 1 || count > 50) {
      result->Error("INVALID_ARGS", "host and 1..50 count are required");
      return;
    }
    std::shared_ptr<flutter::MethodResult<EncodableValue>> shared(
        result.release());
    HWND window = window_;
    auto alive = alive_;
    std::thread([window, alive, shared, host, count, timeout]() {
      EncodableMap out = IcmpPing(host, count, timeout);
      PostRun(window, [alive, shared, out]() {
        if (!alive->load()) return;
        shared->Success(EncodableValue(out));
      });
    }).detach();
    return;
  }

  if (method == "getActiveAdapter") {
    result->Success(ActiveAdapter());
    return;
  }

  result->NotImplemented();
}
