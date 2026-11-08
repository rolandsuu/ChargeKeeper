#!/bin/bash
# Builds ChargeKeeper.app, signs it with your Apple Development certificate, and installs
# it to /Applications. Pass --test to include the command-line test driver.
set -euo pipefail

cd "$(dirname "$0")/.."

SIGNING_IDENTITY="03C83F0E789D87EABA8120BA15FE4E92D6A271DD"
APP="build/ChargeKeeper.app"
SERVICE_ID="com.rolandsu.chargekeeper.service"

flags=()
if [[ "${1:-}" == "--test" ]]; then
    flags+=(-Xswiftc -DCK_TEST_COMMANDS)
fi

swift build -c release --scratch-path .build-release ${flags[@]+"${flags[@]}"}
BIN="$(swift build -c release --scratch-path .build-release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/ChargeKeeper" "$BIN/ChargeKeeperService" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "Resources/$SERVICE_ID.plist" "$APP/Contents/Library/LaunchDaemons/"
# Compiling the icon needs Xcode's actool. Without Xcode, the copy compiled last time is used.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
        --include-all-app-icons --output-partial-info-plist build/icon-info.plist \
        --errors >/dev/null
    cp "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/Assets.car" Resources/CompiledIcon/
else
    cp Resources/CompiledIcon/AppIcon.icns Resources/CompiledIcon/Assets.car "$APP/Contents/Resources/"
fi

codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" \
    --identifier "$SERVICE_ID" "$APP/Contents/MacOS/ChargeKeeperService"
codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict "$APP"

rm -rf /Applications/ChargeKeeper.app
ditto "$APP" /Applications/ChargeKeeper.app
echo "Installed /Applications/ChargeKeeper.app"
