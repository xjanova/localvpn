# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(localvpn LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "LocalVPN")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# MSVC 14.5x turns the old <experimental/coroutine> header that C++/WinRT
# plugins (audioplayers) still include into a hard error. Older toolsets
# ignore the define.
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd4100)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# The service that runs the virtual LAN adapter for the app; see
# service/service_main.cpp.
add_subdirectory("service")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# wireguard_flutter_plus marks the exe requireAdministrator (its tunnel
# service needs admin). We start without a UAC prompt instead: the virtual
# LAN adapter runs in LocalVPNService (installed by the setup), and the VPN /
# game boost pages offer "relaunch as admin" when they need it.
# -DLOCALVPN_AS_INVOKER=OFF gives back the always-elevated exe.
option(LOCALVPN_AS_INVOKER "Start without a UAC prompt" ON)
if(LOCALVPN_AS_INVOKER)
  set_target_properties(${BINARY_NAME} PROPERTIES LINK_FLAGS
    "/MANIFESTUAC:\"level='asInvoker' uiAccess='false'\" /SUBSYSTEM:WINDOWS")
endif()

# audioplayers_windows pulls WIL from NuGet and links its MSBuild .targets
# file, which only the Visual Studio generator understands. For Ninja builds
# point at the headers directly and drop the .targets entry.
if(TARGET audioplayers_windows_plugin AND NOT CMAKE_GENERATOR MATCHES "Visual Studio")
  target_include_directories(audioplayers_windows_plugin PRIVATE
    "${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary/include")
  get_target_property(_ap_libs audioplayers_windows_plugin LINK_LIBRARIES)
  list(FILTER _ap_libs EXCLUDE REGEX "\\.targets$")
  set_target_properties(audioplayers_windows_plugin PROPERTIES LINK_LIBRARIES "${_ap_libs}")
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)
install(TARGETS LocalVPNService RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Wintun driver loader for the virtual LAN adapter (signed by WireGuard LLC,
# redistributable next to software that uses it via wintun.h).
if(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64")
  set(WINTUN_ARCH "arm64")
else()
  set(WINTUN_ARCH "amd64")
endif()
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/third_party/wintun/bin/${WINTUN_ARCH}/wintun.dll"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)

# Ship the MSVC runtime (msvcp140, vcruntime140*) next to the exe so the
# app starts on machines without the VC++ redistributable.
set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${INSTALL_BUNDLE_LIB_DIR}")
set(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT Runtime)
set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)
include(InstallRequiredSystemLibraries)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
