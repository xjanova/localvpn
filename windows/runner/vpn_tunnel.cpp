// winsock2 must come before windows.h (pulled in by vpn_tunnel.h).
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include "vpn_tunnel.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "third_party/wintun/include/wintun.h"

namespace {

// Fixed adapter GUID so Windows keeps one identity for the LocalVPN adapter
// instead of numbering a new "Unidentified network" on every connect.
constexpr GUID kAdapterGuid = {
    0x6b6f6c4c, 0x5650, 0x4e2d, {0x9c, 0x1a, 0x4c, 0x4f, 0x43, 0x41, 0x4c, 0x56}};
constexpr wchar_t kAdapterName[] = L"LocalVPN";
constexpr DWORD kRingCapacity = 0x400000;  // 4 MiB
constexpr size_t kMaxQueuedPackets = 4096;
constexpr ULONG kMtu = 1400;  // leaves room for UDP/relay overhead

WINTUN_CREATE_ADAPTER_FUNC* WintunCreateAdapter;
WINTUN_OPEN_ADAPTER_FUNC* WintunOpenAdapter;
WINTUN_CLOSE_ADAPTER_FUNC* WintunCloseAdapter;
WINTUN_GET_ADAPTER_LUID_FUNC* WintunGetAdapterLUID;
WINTUN_START_SESSION_FUNC* WintunStartSession;
WINTUN_END_SESSION_FUNC* WintunEndSession;
WINTUN_GET_READ_WAIT_EVENT_FUNC* WintunGetReadWaitEvent;
WINTUN_RECEIVE_PACKET_FUNC* WintunReceivePacket;
WINTUN_RELEASE_RECEIVE_PACKET_FUNC* WintunReleaseReceivePacket;
WINTUN_ALLOCATE_SEND_PACKET_FUNC* WintunAllocateSendPacket;
WINTUN_SEND_PACKET_FUNC* WintunSendPacket;

bool ParseIpv4(const std::string& text, uint32_t* out) {
  IN_ADDR addr;
  if (InetPtonA(AF_INET, text.c_str(), &addr) != 1) return false;
  *out = ntohl(addr.S_un.S_addr);
  return true;
}

// Accepts "10.10.0.0/24" or a netmask such as "255.255.255.0".
bool ParsePrefix(const std::string& subnet, uint8_t* prefix) {
  auto slash = subnet.find('/');
  if (slash != std::string::npos) {
    int bits = std::atoi(subnet.c_str() + slash + 1);
    if (bits < 8 || bits > 30) return false;
    *prefix = static_cast<uint8_t>(bits);
    return true;
  }
  uint32_t mask;
  if (!ParseIpv4(subnet, &mask)) return false;
  uint8_t bits = 0;
  while (bits < 32 && (mask & (0x80000000u >> bits))) bits++;
  // Reject non-contiguous masks.
  if (bits < 8 || bits > 30 || (mask << bits) != 0) return false;
  *prefix = bits;
  return true;
}

std::wstring Format(const wchar_t* fmt, DWORD code) {
  wchar_t buf[256];
  swprintf_s(buf, fmt, code);
  return buf;
}

}  // namespace

VpnTunnel::VpnTunnel() = default;

VpnTunnel::~VpnTunnel() {
  Stop();
  if (wintun_) FreeLibrary(wintun_);
}

bool VpnTunnel::LoadWintun(std::wstring* error) {
  if (wintun_) return true;
  // Only look next to the exe and in System32 — never the current directory.
  HMODULE mod = LoadLibraryExW(
      L"wintun.dll", nullptr,
      LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (!mod) {
    *error = L"ไม่พบไฟล์ wintun.dll ในโฟลเดอร์ของโปรแกรม กรุณาติดตั้ง LocalVPN ใหม่";
    return false;
  }
#define LOAD(name)                                                     \
  name = reinterpret_cast<decltype(name)>(GetProcAddress(mod, #name)); \
  if (!name) {                                                         \
    FreeLibrary(mod);                                                  \
    *error = L"wintun.dll ไม่สมบูรณ์ กรุณาติดตั้ง LocalVPN ใหม่";       \
    return false;                                                      \
  }
  LOAD(WintunCreateAdapter)
  LOAD(WintunOpenAdapter)
  LOAD(WintunCloseAdapter)
  LOAD(WintunGetAdapterLUID)
  LOAD(WintunStartSession)
  LOAD(WintunEndSession)
  LOAD(WintunGetReadWaitEvent)
  LOAD(WintunReceivePacket)
  LOAD(WintunReleaseReceivePacket)
  LOAD(WintunAllocateSendPacket)
  LOAD(WintunSendPacket)
#undef LOAD
  wintun_ = mod;
  return true;
}

std::wstring VpnTunnel::Start(const std::string& virtual_ip,
                              const std::string& subnet, WakeCallback wake,
                              FailCallback fail, std::string* error_code) {
  Stop();

  uint32_t ip;
  uint8_t prefix;
  if (!ParseIpv4(virtual_ip, &ip) || !ParsePrefix(subnet, &prefix)) {
    *error_code = "INVALID_ARGS";
    return L"ข้อมูล IP ของวงเครือข่ายไม่ถูกต้อง";
  }

  std::wstring error;
  if (!LoadWintun(&error)) {
    *error_code = "WINTUN_MISSING";
    return error;
  }

  auto adapter = WintunOpenAdapter(kAdapterName);
  if (!adapter) {
    adapter = WintunCreateAdapter(kAdapterName, kAdapterName, &kAdapterGuid);
  }
  if (!adapter) {
    DWORD code = GetLastError();
    if (code == ERROR_ACCESS_DENIED) {
      *error_code = "ADMIN_REQUIRED";
      return L"ต้องเปิด LocalVPN ด้วยสิทธิ์ผู้ดูแลระบบ (Run as administrator) "
             L"เพื่อสร้างการ์ดเครือข่ายเสมือน";
    }
    *error_code = "ADAPTER_FAILED";
    return Format(L"สร้างการ์ดเครือข่ายเสมือนไม่สำเร็จ (รหัส %lu)", code);
  }
  adapter_ = adapter;

  NET_LUID luid;
  WintunGetAdapterLUID(adapter, &luid);

  own_ip_ = ip;
  mask_ = prefix == 0 ? 0 : 0xFFFFFFFFu << (32 - prefix);
  net_ = ip & mask_;

  // An adapter reused after a crash may still carry another network's IP.
  PMIB_UNICASTIPADDRESS_TABLE table = nullptr;
  if (GetUnicastIpAddressTable(AF_INET, &table) == NO_ERROR) {
    for (ULONG i = 0; i < table->NumEntries; i++) {
      auto& row = table->Table[i];
      if (row.InterfaceLuid.Value == luid.Value &&
          ntohl(row.Address.Ipv4.sin_addr.S_un.S_addr) != ip) {
        DeleteUnicastIpAddressEntry(&row);
      }
    }
    FreeMibTable(table);
  }

  MIB_UNICASTIPADDRESS_ROW addr;
  InitializeUnicastIpAddressEntry(&addr);
  addr.InterfaceLuid = luid;
  addr.Address.Ipv4.sin_family = AF_INET;
  addr.Address.Ipv4.sin_addr.S_un.S_addr = htonl(ip);
  addr.OnLinkPrefixLength = prefix;
  addr.DadState = IpDadStatePreferred;
  DWORD res = CreateUnicastIpAddressEntry(&addr);
  if (res != NO_ERROR && res != ERROR_OBJECT_ALREADY_EXISTS) {
    Stop();
    *error_code = res == ERROR_ACCESS_DENIED ? "ADMIN_REQUIRED" : "IP_FAILED";
    return Format(L"ตั้งค่า IP ให้การ์ดเครือข่ายเสมือนไม่สำเร็จ (รหัส %lu)", res);
  }

  MIB_IPINTERFACE_ROW iface;
  InitializeIpInterfaceEntry(&iface);
  iface.Family = AF_INET;
  iface.InterfaceLuid = luid;
  if (GetIpInterfaceEntry(&iface) == NO_ERROR) {
    iface.NlMtu = kMtu;
    iface.SitePrefixLength = 0;  // must be 0 for IPv4 or the call fails
    SetIpInterfaceEntry(&iface);
  }

  session_ = WintunStartSession(adapter, kRingCapacity);
  if (!session_) {
    DWORD code = GetLastError();
    Stop();
    *error_code = "SESSION_FAILED";
    return Format(L"เปิดการ์ดเครือข่ายเสมือนไม่สำเร็จ (รหัส %lu)", code);
  }

  wake_ = std::move(wake);
  fail_ = std::move(fail);
  quit_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  running_ = true;
  reader_ = std::thread(&VpnTunnel::ReaderLoop, this);
  return L"";
}

void VpnTunnel::Stop() {
  running_ = false;
  if (quit_event_) SetEvent(quit_event_);
  if (reader_.joinable()) reader_.join();
  if (session_) {
    WintunEndSession(static_cast<WINTUN_SESSION_HANDLE>(session_));
    session_ = nullptr;
  }
  if (adapter_) {
    // Removes the adapter if this process created it.
    WintunCloseAdapter(static_cast<WINTUN_ADAPTER_HANDLE>(adapter_));
    adapter_ = nullptr;
  }
  if (quit_event_) {
    CloseHandle(quit_event_);
    quit_event_ = nullptr;
  }
  std::lock_guard<std::mutex> lock(queue_mutex_);
  queue_.clear();
}

bool VpnTunnel::ShouldForward(const uint8_t* pkt, DWORD size) const {
  if (size < 20 || (pkt[0] >> 4) != 4) return false;  // IPv4 only
  uint32_t dst = (uint32_t(pkt[16]) << 24) | (uint32_t(pkt[17]) << 16) |
                 (uint32_t(pkt[18]) << 8) | pkt[19];
  if (dst == 0xFFFFFFFFu) return true;               // limited broadcast
  if ((dst & 0xF0000000u) == 0xE0000000u) return false;  // multicast noise
  if ((dst & mask_) != net_) return false;
  if (dst == own_ip_ || dst == net_) return false;
  return true;  // a peer, or the subnet broadcast (LAN game discovery)
}

void VpnTunnel::ReaderLoop() {
  auto session = static_cast<WINTUN_SESSION_HANDLE>(session_);
  HANDLE handles[2] = {quit_event_, WintunGetReadWaitEvent(session)};
  while (running_) {
    DWORD size = 0;
    BYTE* pkt = WintunReceivePacket(session, &size);
    if (pkt) {
      if (ShouldForward(pkt, size)) {
        Packet copy(pkt, pkt + size);
        bool wake = false;
        {
          std::lock_guard<std::mutex> lock(queue_mutex_);
          if (queue_.size() >= kMaxQueuedPackets) {
            packets_dropped_++;
          } else {
            wake = queue_.empty();
            queue_.push_back(std::move(copy));
            packets_out_++;
          }
        }
        WintunReleaseReceivePacket(session, pkt);
        if (wake && wake_) wake_();
      } else {
        WintunReleaseReceivePacket(session, pkt);
      }
      continue;
    }
    DWORD code = GetLastError();
    if (code == ERROR_NO_MORE_ITEMS) {
      if (WaitForMultipleObjects(2, handles, FALSE, INFINITE) == WAIT_OBJECT_0) {
        break;
      }
      continue;
    }
    if (running_ && fail_) {
      fail_(Format(L"การ์ดเครือข่ายเสมือนหยุดทำงาน (รหัส %lu)", code));
    }
    break;
  }
}

bool VpnTunnel::Inject(const uint8_t* data, size_t size) {
  if (!running_ || !session_ || size < 20 || size > WINTUN_MAX_IP_PACKET_SIZE) {
    return false;
  }
  if ((data[0] >> 4) != 4) return false;
  // A peer may only hand us packets from inside the virtual subnet, addressed
  // to us or to a broadcast address — nothing that looks like it came from the
  // internet or targets another host.
  uint32_t src = (uint32_t(data[12]) << 24) | (uint32_t(data[13]) << 16) |
                 (uint32_t(data[14]) << 8) | data[15];
  uint32_t dst = (uint32_t(data[16]) << 24) | (uint32_t(data[17]) << 16) |
                 (uint32_t(data[18]) << 8) | data[19];
  uint32_t bcast = net_ | ~mask_;
  if ((src & mask_) != net_ || src == own_ip_) return false;
  if (dst != own_ip_ && dst != bcast && dst != 0xFFFFFFFFu) return false;

  auto session = static_cast<WINTUN_SESSION_HANDLE>(session_);
  BYTE* out = WintunAllocateSendPacket(session, static_cast<DWORD>(size));
  if (!out) {
    packets_dropped_++;
    return false;
  }
  std::memcpy(out, data, size);
  WintunSendPacket(session, out);
  packets_in_++;
  return true;
}

void VpnTunnel::TakePackets(std::vector<Packet>* out) {
  std::lock_guard<std::mutex> lock(queue_mutex_);
  out->swap(queue_);
  queue_.clear();
}
