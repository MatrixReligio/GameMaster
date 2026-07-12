#!/usr/bin/env bash
# Builds the steamwebhelper wrapper (Windows PE) and copies it into the app
# resources. Requires mingw-w64 (brew install mingw-w64).
set -euo pipefail
cd "$(dirname "$0")"
# -mwindows = GUI subsystem: the real steamwebhelper is a GUI app, so if the
# wrapper were the default console subsystem, Wine would open a stray black
# console window for it. The wrapper has no UI of its own, so GUI subsystem
# just suppresses that window.
x86_64-w64-mingw32-gcc -O2 -mwindows -o steamwebhelper_wrapper.exe steamwebhelper_wrapper.c
cp steamwebhelper_wrapper.exe ../../Sources/GMApps/Resources/steamwebhelper_wrapper.exe
echo "built and installed steamwebhelper_wrapper.exe ($(stat -f%z steamwebhelper_wrapper.exe) bytes)"
