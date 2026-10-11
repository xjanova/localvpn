cmake_minimum_required(VERSION 3.14)
project(localvpn_service LANGUAGES CXX)

# LocalVPNService.exe: owns the Wintun adapter as LocalSystem so LocalVPN.exe
# can start without a UAC prompt (see service_main.cpp).
add_executable(LocalVPNService
  "service_main.cpp"
  "../runner/vpn_tunnel.cpp"
)
apply_standard_settings(LocalVPNService)
target_compile_definitions(LocalVPNService PRIVATE NOMINMAX UNICODE _UNICODE)
target_include_directories(LocalVPNService PRIVATE "${CMAKE_SOURCE_DIR}")
target_link_libraries(LocalVPNService PRIVATE "iphlpapi.lib" "ws2_32.lib" "advapi32.lib")
set_target_properties(LocalVPNService PROPERTIES LINK_FLAGS "/SUBSYSTEM:CONSOLE")
