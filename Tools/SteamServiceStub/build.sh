#!/usr/bin/env bash
# Builds the no-op steamservice stub (32-bit Windows PE) and copies it into the
# app resources. Requires mingw-w64 (brew install mingw-w64).
#
# Steam's real 32-bit steamservice.exe null-derefs under Wine's new WoW64, which
# pops a "Steam Service Error" dialog on every launch. The service is only needed
# for elevated installs, not login/downloads, so we replace it with this stub
# that registers a do-nothing Windows service and exits cleanly. 32-bit + GUI
# subsystem (-mwindows) so it matches the real binary's shape and shows no window.
set -euo pipefail
cd "$(dirname "$0")"
i686-w64-mingw32-gcc -O2 -mwindows -o steamservice_stub.exe steamservice_stub.c -ladvapi32
cp steamservice_stub.exe ../../Sources/GMApps/Resources/steamservice_stub.exe
echo "built and installed steamservice_stub.exe ($(stat -f%z steamservice_stub.exe) bytes)"
