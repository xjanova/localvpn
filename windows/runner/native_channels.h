#ifndef RUNNER_NATIVE_CHANNELS_H_
#define RUNNER_NATIVE_CHANNELS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <atomic>
#include <functional>
#include <memory>

#include "vpn_tunnel.h"

// Windows side of the app's own platform channels:
//   com.xjanova.localvpn/vpn      — virtual LAN adapter (same API as Android)
//   com.xjanova.localvpn/windows  — elevation, ICMP ping, active adapter info
class NativeChannels {
 public:
  // Messages posted to the top-level window by worker threads.
  static constexpr UINT kWmPackets = WM_APP + 0x51;
  static constexpr UINT kWmRun = WM_APP + 0x52;

  NativeChannels(flutter::BinaryMessenger* messenger, HWND window);
  ~NativeChannels();

  // Call from the window procedure; returns true when the message was ours.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  using Call = flutter::MethodCall<flutter::EncodableValue>;
  using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void OnVpnCall(const Call& call, Result result);
  void OnWindowsCall(const Call& call, Result result);
  void DeliverPackets();
  // Runs |fn| on the platform thread. Safe to call from any thread.
  void PostToPlatform(std::function<void()> fn);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> vpn_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> win_channel_;
  VpnTunnel tunnel_;
  // Cleared in the destructor so late worker callbacks become no-ops.
  std::shared_ptr<std::atomic<bool>> alive_;
};

#endif  // RUNNER_NATIVE_CHANNELS_H_
