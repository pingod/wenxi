cmake_minimum_required(VERSION 3.15)
project(desktop_drop_native_tests LANGUAGES CXX)
get_filename_component(REPO "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(FLUTTER_RUNTIME "${REPO}/windows/flutter/ephemeral")
set(FLUTTER_WRAPPER "${REPO}/build/windows/x64/flutter/Release/flutter_wrapper_plugin.lib")
if(NOT EXISTS "${FLUTTER_WRAPPER}" OR NOT EXISTS "${FLUTTER_RUNTIME}/flutter_windows.dll.lib")
  message(FATAL_ERROR "This isolated test requires existing Flutter Windows wrapper libraries.")
endif()
add_executable(desktop_drop_native_test "${REPO}/tool/tests/desktop_drop_native_test.cpp")
target_compile_features(desktop_drop_native_test PRIVATE cxx_std_17)
target_compile_definitions(desktop_drop_native_test PRIVATE FLUTTER_PLUGIN_IMPL)
target_compile_options(desktop_drop_native_test PRIVATE /W4 /WX /utf-8)
target_include_directories(desktop_drop_native_test PRIVATE
  "${FLUTTER_RUNTIME}" "${FLUTTER_RUNTIME}/cpp_client_wrapper/include")
target_link_libraries(desktop_drop_native_test PRIVATE
  "${FLUTTER_WRAPPER}" "${FLUTTER_RUNTIME}/flutter_windows.dll.lib" ole32 shell32 user32)
add_custom_command(TARGET desktop_drop_native_test POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${FLUTTER_RUNTIME}/flutter_windows.dll"
    "$<TARGET_FILE_DIR:desktop_drop_native_test>")
enable_testing()
add_test(NAME windows_file_drop COMMAND desktop_drop_native_test)
