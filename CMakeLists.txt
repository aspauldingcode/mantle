cmake_minimum_required(VERSION 3.10)
project(Mantle LANGUAGES C CXX OBJC)

# Generate compile_commands.json
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES "arm64;arm64e;x86_64")


# Enable ARC globally for all Objective-C files
add_compile_options($<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>)

# Optional: Add your warning and debug flags
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -g")

# Include directories
include_directories(${CMAKE_SOURCE_DIR}/include)

# Core loader (wm_init)
add_executable(mantle wm_init/init.m wm_init/env.c common/mantle_mach.m)
target_link_libraries(mantle PRIVATE
    "-framework Foundation -framework SystemConfiguration -framework JavaScriptCore"
    "-framework CoreVideo -framework QuartzCore"
)

# Core application support (libcore - injected into all processes)
add_library(core SHARED wm_core/core.m common/mantle_mach.m)
target_link_libraries(core PRIVATE
    "-framework Foundation -framework Cocoa -framework SystemConfiguration -framework Security -framework IOKit"
    "-lresolv.9 -lffi"
    ${CMAKE_SOURCE_DIR}/libdobby.a
)

# Force load libc++ before anything else for Frida compatibility
set_property(TARGET core APPEND_STRING PROPERTY
    LINK_FLAGS " -Wl,-bind_at_load -force_load /usr/lib/libc++.1.dylib"
)
