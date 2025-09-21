all: archive dmg

archive:
	set -o pipefail && xcodebuild archive \
        -project ProxySwitcher.xcodeproj \
        -destination "generic/platform=macOS" \
        -scheme "ProxySwitcher" \
        -archivePath "./ProxySwitcher/ProxySwitcher.xcarchive" \
        -xcconfig "./ProxySwitcher/MainConfig.xcconfig" \
        GCC_OPTIMIZATION_LEVEL=s \
        SWIFT_OPTIMIZATION_LEVEL=-O \
        GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
        DEBUG_INFORMATION_FORMAT=dwarf-with-dsym | xcbeautify

dmg:
	create-dmg \
        --volname "ProxySwitcher" \
        --background "./Misc/Media/dmg_background.png" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 160 \
        --icon "ProxySwitcher.app" 180 170 \
        --hide-extension "ProxySwitcher.app" \
        --app-drop-link 480 170 \
        --no-internet-enable \
        "./ProxySwitcher/ProxySwitcher.dmg" \
        "./ProxySwitcher/ProxySwitcher.xcarchive/Products/Applications/"
