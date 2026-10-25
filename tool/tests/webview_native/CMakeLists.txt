cmake_minimum_required(VERSION 3.14)
project(webview_native_tests LANGUAGES CXX)
get_filename_component(REPO "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
# Uses the same JSON headers installed by a normal Flutter Windows build.
set(JSON_INCLUDE "${REPO}/build/windows/x64/packages/nlohmann.json/build/native/include")
if(NOT EXISTS "${JSON_INCLUDE}/nlohmann/json.hpp")
  message(FATAL_ERROR "Run flutter build windows once to prepare the plugin dependencies.")
endif()
add_executable(webview_json_test "${REPO}/tool/tests/webview_json_test.cpp")
target_compile_features(webview_json_test PRIVATE cxx_std_17)
target_include_directories(webview_json_test PRIVATE "${JSON_INCLUDE}")
enable_testing()
add_test(NAME webview_json_and_reply COMMAND webview_json_test)

add_executable(webview_lifecycle_test "${REPO}/tool/tests/webview_lifecycle_test.cpp")
target_compile_features(webview_lifecycle_test PRIVATE cxx_std_17)
target_include_directories(webview_lifecycle_test PRIVATE
  "${REPO}/windows/flutter/ephemeral"
  "${REPO}/windows/flutter/ephemeral/cpp_client_wrapper/include")
add_test(NAME webview_lifecycle COMMAND webview_lifecycle_test)

add_executable(webview_permission_test
  "${REPO}/tool/tests/webview_permission_test.cpp"
  "${REPO}/vendor_plugins/flutter_inappwebview_windows/windows/types/permission_response.cpp"
  "${REPO}/windows/flutter/ephemeral/cpp_client_wrapper/standard_codec.cc")
target_compile_features(webview_permission_test PRIVATE cxx_std_17)
target_compile_options(webview_permission_test PRIVATE /W4 /wd4100 /EHsc /utf-8)
target_compile_definitions(webview_permission_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_include_directories(webview_permission_test PRIVATE
  "${REPO}/windows/flutter/ephemeral/cpp_client_wrapper/include"
  "${REPO}/build/windows/x64/packages/Microsoft.Web.WebView2/build/native/include"
  "${REPO}/build/windows/x64/packages/Microsoft.Windows.ImplementationLibrary/include")
add_test(NAME webview_permission COMMAND webview_permission_test)

add_executable(native_diagnostics_test
  "${REPO}/tool/tests/native_diagnostics_test.cpp"
  "${REPO}/windows/runner/native_diagnostics.cpp")
target_compile_features(native_diagnostics_test PRIVATE cxx_std_17)
target_compile_options(native_diagnostics_test PRIVATE /W4 /WX /wd4100 /EHsc /utf-8)
target_compile_definitions(native_diagnostics_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_include_directories(native_diagnostics_test PRIVATE "${JSON_INCLUDE}")
target_link_libraries(native_diagnostics_test PRIVATE wevtapi shell32 ole32)
add_test(NAME native_diagnostics COMMAND native_diagnostics_test)
