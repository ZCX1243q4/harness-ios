#!/usr/bin/env bash
# 把 xcodebuild 产物打成未签名 ipa（Payload/Harness.app），任何重签工具都能吃
set -euo pipefail

APP="${1:-}"
OUT="${2:-Harness-unsigned.ipa}"

# 没给路径就自己找
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  APP="$(find build -type d -name "*.app" -path "*Release-iphoneos*" | head -1)"
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "找不到 .app，构建可能失败了。build/ 现状：" >&2
  find build -maxdepth 4 -type d 2>/dev/null | head -20 >&2
  exit 1
fi

APP_NAME="$(basename "$APP")"
ROOT="build/ipa-root"

rm -rf "$ROOT"
mkdir -p "$ROOT/Payload"
cp -R "$APP" "$ROOT/Payload/"

# 未签名 ipa 必须清掉签名残留，否则重签工具会拒绝或签名冲突
rm -rf "$ROOT/Payload/$APP_NAME/_CodeSignature"
rm -rf "$ROOT/Payload/$APP_NAME/SC_Info"
rm -f  "$ROOT/Payload/$APP_NAME/embedded.mobileprovision"
chmod +x "$ROOT/Payload/$APP_NAME/$APP_NAME" 2>/dev/null || true

# 输出路径先转成绝对路径，避免 cd 之后算错
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"

( cd "$ROOT" && zip -qry -X "$OUT_ABS" Payload )

echo "--- Payload/$APP_NAME ---"
ls "$ROOT/Payload/$APP_NAME"
echo "--- ipa 结构 ---"
unzip -l "$OUT_ABS" | head -8
echo "unsigned ipa -> $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
