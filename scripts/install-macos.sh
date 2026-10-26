#!/bin/bash
# Install the published binary. Never modifies the Time Note data directory.
set -euo pipefail
VERSION="1.1.5"
ASSET="TimeNote-$VERSION-macOS-universal.zip"
BASE="https://github.com/Jiang59991/time-note/releases/download/v$VERSION"
EXPECTED_SHA256="96d918264dc448b85d8295debc17e2d8839e3432508bb54b3224aa3a0edd2ae0"
DESTINATION="$HOME/Applications"
if [ "${1:-}" = "--destination" ] && [ "$#" -eq 2 ]; then
  DESTINATION="$2"
elif [ "$#" -ne 0 ]; then
  printf 'Usage: bash scripts/install-macos.sh [--destination /absolute/applications-directory]\n' >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ]; then
  printf '当前安装包仅支持 macOS；Windows 请阅读 INSTALL.md 的源码移植说明。\n' >&2
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
  printf '需要 macOS 14 或更新版本。\n' >&2
  exit 1
fi
case "$DESTINATION" in /*) ;; *) printf '安装目录须为绝对路径。\n' >&2; exit 2 ;; esac
TARGET="$DESTINATION/Time Note.app"
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  printf '已有应用：%s\n为保留已有安装，本脚本停止。请先退出旧版，由你或助手备份旧 App 后更新；不要删除时间数据目录。\n' "$TARGET" >&2
  exit 1
fi
if [ "$DESTINATION" = "$HOME/Applications" ] && [ -e '/Applications/Time Note.app' ]; then
  printf '发现 /Applications/Time Note.app；请更新已有副本，避免安装两个版本。\n' >&2
  exit 1
fi
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/time-note-install.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
printf '下载 Time Note %s（当前尚未 Apple 公证）…\n' "$VERSION"
curl --fail --location --retry 2 --proto '=https' --tlsv1.2 "$BASE/$ASSET" --output "$TEMP_DIR/$ASSET"
ACTUAL_SHA256=$(shasum -a 256 "$TEMP_DIR/$ASSET" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  printf '安装包 SHA-256 不匹配，停止安装。\n' >&2
  exit 1
fi
ditto -x -k "$TEMP_DIR/$ASSET" "$TEMP_DIR/unpacked"
APP="$TEMP_DIR/unpacked/Time Note.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [ "$BUNDLE_ID" != local.zoey.time-note ] || [ "$BUNDLE_VERSION" != "$VERSION" ]; then
  printf '安装包身份或版本不匹配，停止安装。\n' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$DESTINATION"
ditto "$APP" "$TARGET"
printf '已安装：%s\n首次打开如被系统拦截，请按 INSTALL.md 的说明，由你本人在系统设置中确认。\n' "$TARGET"
