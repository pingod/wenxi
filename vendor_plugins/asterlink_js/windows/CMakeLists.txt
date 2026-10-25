cmake_minimum_required(VERSION 3.14)
project(asterlink_js LANGUAGES C)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/runtime")
set(asterlink_js_bundled_libraries $<TARGET_FILE:asterlink_js> PARENT_SCOPE)
