#!/bin/bash
set -e

# Create a temporary directory
mkdir -p dobby_temp

# Fetch and extract dobby-macos-all.tar.gz
curl -L -o dobby-macos-all.tar.gz https://github.com/jmpews/Dobby/releases/latest/download/dobby-macos-all.tar.gz
tar -xvf dobby-macos-all.tar.gz -C dobby_temp
rm dobby-macos-all.tar.gz

# Move the files
mv dobby_temp/build/macos/dobby.h ./include/dobby.h
mv dobby_temp/build/macos/universal/libdobby.a .

# Clean up
rm -rf dobby_temp
