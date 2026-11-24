# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(lumina_app LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "lumina_app")

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


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


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

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

if(LUMINA_WEBVIEW2_LOADER_DLL AND EXISTS "${LUMINA_WEBVIEW2_LOADER_DLL}")
  install(FILES "${LUMINA_WEBVIEW2_LOADER_DLL}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the hook/build.dart from all packages.
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

# Bundle compiled Rust core_ffi.dll next to the Windows desktop executable.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../target/debug/core_ffi.dll"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  CONFIGURATIONS Debug
  OPTIONAL
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../target/release/core_ffi.dll"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  CONFIGURATIONS Profile;Release
  OPTIONAL
  COMPONENT Runtime)

# === MSVC Runtime DLL Bundling ===
# Copy Microsoft Visual C++ 2015-2022 x64 runtime DLLs (msvcp140.dll, vcruntime140.dll,
# vcruntime140_1.dll, etc.) into the bundle directory when VS Redistributables are installed.
set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${INSTALL_BUNDLE_LIB_DIR}")
set(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT Runtime)
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_NO_WARNINGS TRUE)
include(InstallRequiredSystemLibraries)
if(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
  list(LENGTH CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS _LUMINA_MSVC_RUNTIME_COUNT)
  message(STATUS "Lumina Audio: Bundling ${_LUMINA_MSVC_RUNTIME_COUNT} MSVC system runtime DLL(s).")
else()
  message(WARNING
    "Lumina Audio: MSVC system runtime DLLs were not found by InstallRequiredSystemLibraries. "
    "Ensure Visual Studio C++ Redistributable libraries are installed for self-contained Release bundles "
    "(target machines otherwise require Microsoft Visual C++ 2015-2022 Redistributable x64).")
endif()

# === Vendored Windows Runtime Binaries (yt-dlp, deno, ffmpeg) & Third-Party Licenses ===
# Populated by `scripts/prepare_release_deps.ps1`. Uses OPTIONAL installs so Debug builds
# never fail when binaries have not yet been downloaded, while emitting clear warnings.
set(LUMINA_VENDOR_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/bin")
set(LUMINA_VENDOR_EXECUTABLES
  "yt-dlp.exe"
  "deno.exe"
  "ffmpeg.exe"
)
set(LUMINA_VENDOR_MISSING "")
foreach(_lumina_exe IN LISTS LUMINA_VENDOR_EXECUTABLES)
  set(_lumina_exe_path "${LUMINA_VENDOR_BIN_DIR}/${_lumina_exe}")
  if(NOT EXISTS "${_lumina_exe_path}")
    list(APPEND LUMINA_VENDOR_MISSING "${_lumina_exe}")
  endif()
  install(FILES "${_lumina_exe_path}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/bin"
    OPTIONAL
    COMPONENT Runtime)
endforeach()

set(LUMINA_THIRD_PARTY_LICENSES "${LUMINA_VENDOR_BIN_DIR}/THIRD_PARTY_LICENSES.txt")
if(NOT EXISTS "${LUMINA_THIRD_PARTY_LICENSES}")
  list(APPEND LUMINA_VENDOR_MISSING "THIRD_PARTY_LICENSES.txt")
endif()
install(FILES "${LUMINA_THIRD_PARTY_LICENSES}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  OPTIONAL
  COMPONENT Runtime)

if(LUMINA_VENDOR_MISSING)
  string(JOIN ", " _lumina_missing_str ${LUMINA_VENDOR_MISSING})
  message(WARNING
    "Lumina Audio: Missing vendored runtime file(s) in ${LUMINA_VENDOR_BIN_DIR}: ${_lumina_missing_str}. "
    "Debug builds can proceed, but Release bundles will be incomplete. "
    "Run `powershell -ExecutionPolicy Bypass -File scripts/prepare_release_deps.ps1` from the repository root.")
endif()

# Release-time safety guard: warn clearly during Release install if any vendored deliverable is absent.
install(CODE "
  if(\"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"Release\")
    set(_lumina_missing_release \"\")
    foreach(_lumina_rel_file IN ITEMS \"bin/yt-dlp.exe\" \"bin/deno.exe\" \"bin/ffmpeg.exe\" \"THIRD_PARTY_LICENSES.txt\")
      if(NOT EXISTS \"${INSTALL_BUNDLE_LIB_DIR}/\${_lumina_rel_file}\")
        list(APPEND _lumina_missing_release \"\${_lumina_rel_file}\")
      endif()
    endforeach()
    if(_lumina_missing_release)
      string(JOIN \", \" _lumina_missing_release_str \${_lumina_missing_release})
      message(WARNING
        \"Lumina Audio: Release bundle is missing required vendored runtime file(s): \${_lumina_missing_release_str}. \"
        \"Run `powershell -ExecutionPolicy Bypass -File scripts/prepare_release_deps.ps1` from the repository root and rebuild.\")
    endif()
  endif()
" COMPONENT Runtime)
