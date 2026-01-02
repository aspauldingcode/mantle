#!/bin/sh
set -e
rm -rf ./build/

# Configure
cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

# Build using all cores
cmake --build build --parallel $(nproc 2>/dev/null || sysctl -n hw.ncpu)
