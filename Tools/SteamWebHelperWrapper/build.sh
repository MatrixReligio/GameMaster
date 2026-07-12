#!/usr/bin/env bash
# Builds the steamwebhelper wrapper (Windows PE) and copies it into the app
# resources. Requires mingw-w64 (brew install mingw-w64).
set -euo pipefail
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -o steamwebhelper_wrapper.exe steamwebhelper_wrapper.c
cp steamwebhelper_wrapper.exe ../../Sources/GMApps/Resources/steamwebhelper_wrapper.exe
echo "built and installed steamwebhelper_wrapper.exe ($(stat -f%z steamwebhelper_wrapper.exe) bytes)"
