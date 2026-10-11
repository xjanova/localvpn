#ifndef RUNNER_TUNNEL_BACKEND_H_
#define RUNNER_TUNNEL_BACKEND_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

// The virtual LAN adapter as the app's channel sees it. Two backends:
//   VpnTunnel      — Wintun in this process (needs administrator rights)
//   ServiceTunnel  — Wintun in LocalVPNService.exe, reached over a pipe, so
//                    the app itself starts without a UAC prompt
class TunnelBackend {
 public:
  using Packet = std::vector<uint8_t>;
  // Called on a worker thread whenever packets are waiting. Must be cheap
  // (post a window message).
  using WakeCallback = std::function<void()>;
  // Called on a worker thread when the session dies on its own (Thai text).
  using FailCallback = std::function<void(const std::wstring&)>;

  virtual ~TunnelBackend() = default;

  // Empty on success, otherwise a Thai error message; |error_code| gets a
  // short machine-readable code.
  virtual std::wstring Start(const std::string& virtual_ip,
                             const std::string& subnet, WakeCallback wake,
                             FailCallback fail, std::string* error_code) = 0;
  virtual void Stop() = 0;
  virtual bool IsRunning() const = 0;

  // Thread-safe.
  virtual bool Inject(const uint8_t* data, size_t size) = 0;
  // Moves every waiting packet into |out|. Thread-safe.
  virtual void TakePackets(std::vector<Packet>* out) = 0;

  virtual uint64_t packets_in() const = 0;
  virtual uint64_t packets_out() const = 0;
  virtual uint64_t packets_dropped() const = 0;
};

#endif  // RUNNER_TUNNEL_BACKEND_H_
