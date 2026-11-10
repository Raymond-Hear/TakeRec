#!/bin/bash
set -euo pipefail

project="$(cd -- "$(dirname -- "$0")" && pwd)"
bundle_id=local.takerec.community
entitlements="$project/App/DeskTake.entitlements"
condition=TAKEREC_DESKTOP
if [[ "${1:-}" == --store ]]; then
    shift
    bundle_id=local.takerec.community.StorePreview
    entitlements="$project/App/DeskTake-Store.entitlements"
    condition=TAKEREC_STORE
    if [[ -z "${1:-}" ]]; then
        printf '请为商店测试版指定单独的 .app 路径。\n' >&2
        exit 2
    fi
fi
configuration="${TAKEREC_BUILD_CONFIGURATION:-release}"
architectures=(arm64 x86_64)
swift_flags=(-O -file-prefix-map "$project=TakeRec")
case "$configuration" in
    release) ;;
    debug)
        architectures=("$(uname -m)")
        swift_flags=(-Onone -g)
        ;;
    *)
        printf 'TAKEREC_BUILD_CONFIGURATION 须为 debug 或 release。\n' >&2
        exit 2
        ;;
esac
app="${1:-"$project/简录.app"}"
if [[ "$app" != /* ]]; then
    app="$PWD/$app"
fi
if [[ "$app" != *.app ]]; then
    printf '输出路径须以 .app 结尾。\n' >&2
    exit 2
fi
if [[ -L "$app" ]]; then
    printf '请选择一个实际的 App 路径。\n' >&2
    exit 2
fi
if [[ -e "$app" ]]; then
    identifier="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identifier" != "$bundle_id" ]]; then
        printf '目标已存在且属于其他项目，请另选输出路径。\n' >&2
        exit 2
    fi
fi

mkdir -p -- "$(dirname -- "$app")"
build="$(mktemp -d "$(dirname -- "$app")/.desktake-build.XXXXXX")"
cleanup() {
    if [[ -d "$build/previous.app" && ! -e "$app" ]]; then
        if ! mv -- "$build/previous.app" "$app"; then
            printf '上一版 App 保存在 %s/previous.app\n' "$build" >&2
            return
        fi
    fi
    rm -rf -- "$build"
}
trap cleanup EXIT
bundle="$build/简录.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project/App/Info.plist" "$bundle/Contents/Info.plist"
if [[ "$condition" == TAKEREC_STORE ]]; then
    /usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$bundle/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleDisplayName -string '简录（商店测试）' "$bundle/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleName -string '简录（商店测试）' "$bundle/Contents/Info.plist"
    /usr/bin/plutil -remove NSLocalNetworkUsageDescription "$bundle/Contents/Info.plist"
fi

assets="$build/Assets.xcassets"
cp -R "$project/App/Assets.xcassets" "$assets"
icon_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconName' "$bundle/Contents/Info.plist")"
iconset="$assets/$icon_name.appiconset"
mkdir -p "$iconset"
cp "$project/App/TakeRecIcon.json" "$iconset/Contents.json"
for size in 16 32 128 256 512; do
    pixels=$((size * 2))
    sips -z "$size" "$size" "$project/App/TakeRec.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$pixels" "$pixels" "$project/App/TakeRec.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
if ! xcrun actool --compile "$bundle/Contents/Resources" --platform macosx \
        --minimum-deployment-target 15.0 --target-device mac --app-icon "$icon_name" \
        --output-partial-info-plist "$build/asset-info.plist" "$assets" > "$build/actool.log" 2>&1; then
    cat "$build/actool.log" >&2
    exit 1
fi
cp "$project/App/Lucide-LICENSE.txt" "$bundle/Contents/Resources/"
cp "$project/LICENSE" "$bundle/Contents/Resources/TakeRec-LICENSE.txt"
if [[ "$condition" == TAKEREC_DESKTOP ]]; then
    mkdir -p "$bundle/Contents/Resources/PhoneReceiver"
    for file in receiver.html receiver.js vdoninja-sdk.js VDO-Ninja-MPL-2.0.txt; do
        cp "$project/App/PhoneReceiver/$file" "$bundle/Contents/Resources/PhoneReceiver/"
    done
fi

sdk="$(xcrun --sdk macosx --show-sdk-path)"
executables=()
for arch in "${architectures[@]}"; do
    mkdir -p "$build/$arch"
    executable="$build/$arch/TakeRec"
    xcrun --sdk macosx swiftc -swift-version 5 "${swift_flags[@]}" -parse-as-library -D "$condition" \
        -target "$arch-apple-macosx15.0" -sdk "$sdk" \
        -module-cache-path "$build/modules" -module-name TakeRec \
        "$project"/Sources/*.swift -o "$executable"
    executables+=("$executable")
done
if [[ "$configuration" == debug ]]; then
    mv "${executables[0]}" "$bundle/Contents/MacOS/TakeRec"
    mv "${executables[0]}.dSYM" "$bundle/Contents/Resources/TakeRec.dSYM"
    cp "$entitlements" "$build/Debug.entitlements"
    entitlements="$build/Debug.entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$entitlements"
else
    xcrun lipo -create "${executables[@]}" -output "$bundle/Contents/MacOS/TakeRec"
fi
codesign --force --sign "${DESKTAKE_SIGN_IDENTITY:--}" --options runtime \
    --entitlements "$entitlements" "$bundle"
codesign --verify --strict "$bundle"

if [[ -e "$app" ]]; then
    mv -- "$app" "$build/previous.app"
fi
mv -- "$bundle" "$app"
printf '%s\n' "$app"
