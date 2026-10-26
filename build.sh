#!/bin/bash
# 构建 TileProto.app（swiftc 直编，无需 Xcode 工程）
set -e
cd "$(dirname "$0")"
mkdir -p TileProto.app/Contents/MacOS TileProto.app/Contents/Resources
swiftc -O -o TileProto.app/Contents/MacOS/TileProto main.swift \
  -framework AppKit -framework ApplicationServices
cp Info.plist TileProto.app/Contents/Info.plist
cp TileProto.icns TileProto.app/Contents/Resources/ 2>/dev/null || true
echo BUILD OK
