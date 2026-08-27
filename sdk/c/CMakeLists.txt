# Consuming the Gosslens C SDK from CMake. This imports the staged library, it
# does not build the engine: run `zig build c-sdk` first, then point
# GOSSLENS_SDK_DIR at zig-out/c-sdk (the default below finds it in a checkout).
cmake_minimum_required(VERSION 3.16)
project(gosslens_c_sdk C)

set(GOSSLENS_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../zig-out/c-sdk"
    CACHE PATH "Directory `zig build c-sdk` stages (include/ and lib/)")

if(APPLE)
    set(_goss_shared "${GOSSLENS_SDK_DIR}/lib/libgosslens.dylib")
else()
    set(_goss_shared "${GOSSLENS_SDK_DIR}/lib/libgosslens.so")
endif()

if(NOT EXISTS "${_goss_shared}")
    message(FATAL_ERROR
        "libgosslens not found at ${_goss_shared}. Run: zig build c-sdk")
endif()

add_library(gosslens SHARED IMPORTED GLOBAL)
set_target_properties(gosslens PROPERTIES
    IMPORTED_LOCATION "${_goss_shared}"
    INTERFACE_INCLUDE_DIRECTORIES "${GOSSLENS_SDK_DIR}/include")

add_executable(gosslens_demo demo/main.c)
target_compile_features(gosslens_demo PRIVATE c_std_11)
target_link_libraries(gosslens_demo PRIVATE gosslens)
set_target_properties(gosslens_demo PROPERTIES
    BUILD_RPATH "${GOSSLENS_SDK_DIR}/lib")
