#!/bin/bash
# 用系统自带的 swiftc 编译并打包成 build/CCSessions.app，不需要 Xcode。
# 用法：./build.sh            只编译
#       ./build.sh install    编译后复制到 /Applications 并重启
set -euo pipefail
cd "$(dirname "$0")"

APP=build/CCSessions.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework Carbon \
  -o "$APP/Contents/MacOS/cc-sessions" \
  Sources/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"
# 本地自签，macOS 才会记住「允许控制 iTerm」的授权。
codesign --force --sign - "$APP" >/dev/null
echo "已生成 $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x cc-sessions 2>/dev/null || true
  rm -rf /Applications/CCSessions.app
  cp -R "$APP" /Applications/
  open /Applications/CCSessions.app
  echo "已安装到 /Applications/CCSessions.app 并启动"
fi
