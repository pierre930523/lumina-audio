cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "external_music_host.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "webview_auth_window.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Official Microsoft.Web.WebView2 NuGet package (Plan A), with offline Plan B guard.
set(WEBVIEW2_SDK_DIR "${CMAKE_BINARY_DIR}/webview2_sdk")
set(WEBVIEW2_NUPKG "${WEBVIEW2_SDK_DIR}/microsoft.web.webview2.1.0.2903.40.nupkg")
set(WEBVIEW2_HEADER "${WEBVIEW2_SDK_DIR}/build/native/include/WebView2.h")
set(WEBVIEW2_LOADER_DLL "${WEBVIEW2_SDK_DIR}/build/native/x64/WebView2Loader.dll")

if(NOT (EXISTS "${WEBVIEW2_HEADER}" AND EXISTS "${WEBVIEW2_LOADER_DLL}"))
  file(MAKE_DIRECTORY "${WEBVIEW2_SDK_DIR}")
  file(DOWNLOAD
    "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.2903.40"
    "${WEBVIEW2_NUPKG}"
    TLS_VERIFY ON
    STATUS WEBVIEW2_DL_STATUS
  )
  list(GET WEBVIEW2_DL_STATUS 0 WEBVIEW2_DL_CODE)
  if(WEBVIEW2_DL_CODE EQUAL 0 AND EXISTS "${WEBVIEW2_NUPKG}")
    if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.18")
      file(ARCHIVE_EXTRACT INPUT "${WEBVIEW2_NUPKG}" DESTINATION "${WEBVIEW2_SDK_DIR}")
    else()
      execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xf "${WEBVIEW2_NUPKG}"
        WORKING_DIRECTORY "${WEBVIEW2_SDK_DIR}"
      )
    endif()
  else()
    message(WARNING "Lumina WebView2 NuGet download failed (status=${WEBVIEW2_DL_STATUS}); falling back to Plan B.")
  endif()
endif()

if(EXISTS "${WEBVIEW2_HEADER}" AND EXISTS "${WEBVIEW2_LOADER_DLL}")
  set(LUMINA_WEBVIEW2_LOADER_DLL "${WEBVIEW2_LOADER_DLL}" CACHE FILEPATH "WebView2Loader.dll path" FORCE)
  target_compile_definitions(${BINARY_NAME} PRIVATE "LUMINA_HAS_WEBVIEW2=1")
  target_include_directories(${BINARY_NAME} PRIVATE "${WEBVIEW2_SDK_DIR}/build/native/include")
  message(STATUS "Lumina WebView2 Plan A enabled (LUMINA_HAS_WEBVIEW2=1)")
else()
  set(LUMINA_WEBVIEW2_LOADER_DLL "" CACHE FILEPATH "WebView2Loader.dll path" FORCE)
  target_compile_definitions(${BINARY_NAME} PRIVATE "LUMINA_HAS_WEBVIEW2=0")
  message(STATUS "Lumina WebView2 Plan B active (LUMINA_HAS_WEBVIEW2=0)")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "crypt32.lib" "shell32.lib" "ole32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
