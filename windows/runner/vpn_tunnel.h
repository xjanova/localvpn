#ifndef RUNNER_VPN_TUNNEL_H_
#define RUNNER_VPN_TUNNEL_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "tunnel_backend.h"

// Virtual LAN adapter backed by Wintun (wintun.dll, shipped next to the exe).
//
// Start() creates (or reuses) the "LocalVPN" adapter, gives it the member's
// virtual IP, and starts a reader thread. IPv4 packets addressed to the
// virtual subnet are queued and handed to |on_packets| from the reader
// thread; the caller moves them to the platform thread. Inject() writes a
// packet received from a peer back into the adapter.
//
// Creating an adapter needs administrator rights.
class VpnTunnel : public TunnelBackend {
 public:
  VpnTunnel();
  ~VpnTunnel() override;

  VpnTunnel(const VpnTunnel&) = delete;
  VpnTunnel& operator=(const VpnTunnel&) = delete;

  // Returns an empty string on success, otherwise a Thai error message.
  // |error_code| receives a short machine-readable code.
  std::wstring Start(const std::string& virtual_ip, const std::string& subnet,
                     WakeCallback wake, FailCallback fail,
                     std::string* error_code) override;
  void Stop() override;
  bool IsRunning() const override { return running_.load(); }

  // Thread-safe.
  bool Inject(const uint8_t* data, size_t size) override;

  // Moves every queued packet into |out|. Thread-safe.
  void TakePackets(std::vector<Packet>* out) override;

  uint64_t packets_in() const override { return packets_in_.load(); }
  uint64_t packets_out() const override { return packets_out_.load(); }
  uint64_t packets_dropped() const override { return packets_dropped_.load(); }

 private:
  bool LoadWintun(std::wstring* error);
  void ReaderLoop();
  bool ShouldForward(const uint8_t* pkt, DWORD size) const;

  HMODULE wintun_ = nullptr;
  void* adapter_ = nullptr;   // WINTUN_ADAPTER_HANDLE
  void* session_ = nullptr;   // WINTUN_SESSION_HANDLE
  HANDLE quit_event_ = nullptr;
  std::thread reader_;
  std::atomic<bool> running_{false};

  uint32_t own_ip_ = 0;       // host byte order
  uint32_t net_ = 0;
  uint32_t mask_ = 0;

  std::mutex queue_mutex_;
  std::vector<Packet> queue_;

  WakeCallback wake_;
  FailCallback fail_;

  std::atomic<uint64_t> packets_in_{0};
  std::atomic<uint64_t> packets_out_{0};
  std::atomic<uint64_t> packets_dropped_{0};
};

#endif  // RUNNER_VPN_TUNNEL_H_
