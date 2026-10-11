#ifndef RUNNER_SERVICE_TUNNEL_H_
#define RUNNER_SERVICE_TUNNEL_H_

#include <windows.h>

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "tunnel_backend.h"

// The virtual LAN adapter run by LocalVPNService.exe (see
// service_protocol.h). Lets the app work without administrator rights when
// the service is installed.
class ServiceTunnel : public TunnelBackend {
 public:
  // |expected_server| is the service image the pipe must belong to; empty =
  // LocalVPNService.exe next to this exe.
  explicit ServiceTunnel(std::wstring expected_server = L"");
  ~ServiceTunnel() override;

  // The service is installed and listening.
  static bool Available();

  std::wstring Start(const std::string& virtual_ip, const std::string& subnet,
                     WakeCallback wake, FailCallback fail,
                     std::string* error_code) override;
  void Stop() override;
  bool IsRunning() const override { return running_.load(); }
  bool Inject(const uint8_t* data, size_t size) override;
  void TakePackets(std::vector<Packet>* out) override;

  uint64_t packets_in() const override { return packets_in_.load(); }
  uint64_t packets_out() const override { return packets_out_.load(); }
  uint64_t packets_dropped() const override { return packets_dropped_.load(); }

 private:
  void ReaderLoop();
  void Close();

  std::wstring expected_server_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  HANDLE quit_ = nullptr;
  std::thread reader_;
  std::mutex write_mutex_;
  std::atomic<bool> running_{false};

  std::mutex queue_mutex_;
  std::vector<Packet> queue_;
  WakeCallback wake_;
  FailCallback fail_;

  std::atomic<uint64_t> packets_in_{0};
  std::atomic<uint64_t> packets_out_{0};
  std::atomic<uint64_t> packets_dropped_{0};
};

#endif  // RUNNER_SERVICE_TUNNEL_H_
