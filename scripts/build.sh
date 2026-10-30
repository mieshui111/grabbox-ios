#!/bin/zsh
# GrabBox iOS 一键构建（在 Mac 上跑）
#   ./scripts/build.sh            → 模拟器编译验证（不需要证书）
#   ./scripts/build.sh ipa        → 未签名 ipa（交给 Sideloadly 侧载，不需要任何账号）
#   ./scripts/build.sh device     → 真机 Debug 包（需要 Xcode 里登录 Apple ID）
#   ./scripts/build.sh testflight → 归档 + 上传 TestFlight（需要 Developer 账号 + 配好 Team）
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-sim}"

# 没有 Xcode 工程就用 XcodeGen 生成（brew install xcodegen）
[ -d GrabBox.xcodeproj ] || {
  echo "▸ 生成 Xcode 工程 (xcodegen)"
  xcodegen generate
}

TEAM=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/' || true)

case "$MODE" in
  sim)
    xcodebuild -project GrabBox.xcodeproj -scheme GrabBox \
      -destination 'platform=iOS Simulator,name=iPhone 16' \
      -configuration Debug build | tail -30
    ;;
  ipa)
    ARCHIVE=build/GrabBox.xcarchive
    rm -rf build
    xcodebuild -project GrabBox.xcodeproj -scheme GrabBox \
      -configuration Release -destination 'generic/platform=iOS' \
      -archivePath "$ARCHIVE" \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      archive | tail -30
    mkdir -p build/Payload
    cp -R "$ARCHIVE/Products/Applications/GrabBox.app" build/Payload/
    ( cd build && zip -qry GrabBox-unsigned.ipa Payload )
    echo "▸ 未签名 ipa: build/GrabBox-unsigned.ipa"
    echo "  下一步：Windows 上用 Sideloadly 加载它，填自己的 Apple ID 签名安装"
    ;;
  device)
    xcodebuild -project GrabBox.xcodeproj -scheme GrabBox \
      -destination 'generic/platform=iOS' \
      -allowProvisioningUpdates ${TEAM:+DEVELOPMENT_TEAM=$TEAM} \
      -configuration Debug build | tail -30
    echo "▸ 产物: $(find ~/Library/Developer/Xcode/DerivedData -name 'GrabBox.app' -path '*Debug-iphoneos*' | head -1)"
    ;;
  testflight)
    ARCHIVE=build/GrabBox.xcarchive
    xcodebuild -project GrabBox.xcodeproj -scheme GrabBox \
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
      ${TEAM:+DEVELOPMENT_TEAM=$TEAM} archive
    xcodebuild -archivePath "$ARCHIVE" -exportArchive \
      -exportOptionsPlist scripts/ExportOptions.plist \
      -allowProvisioningUpdates
    echo "▸ 归档完成，用 Xcode Organizer 或 altool 上传 TestFlight"
    ;;
  *) echo "用法: ./scripts/build.sh [sim|device|testflight]"; exit 1 ;;
esac
