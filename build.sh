#!/bin/bash
set -euo pipefail

project="$(cd -- "$(dirname -- "$0")" && pwd)"
bundle_id=local.lingfeng.DeskTake
entitlements="$project/App/DeskTake.entitlements"
condition=TAKEREC_DESKTOP
signing_identity="${DESKTAKE_SIGN_IDENTITY:--}"
signing_args=(--force --sign "$signing_identity")
# Library validation requires a Team ID, which ad-hoc local builds do not have.
if [[ "$signing_identity" != - ]]; then
    signing_args+=(--options runtime)
fi
if [[ "${1:-}" == --store ]]; then
    shift
    bundle_id=local.lingfeng.DeskTake.StorePreview
    entitlements="$project/App/DeskTake-Store.entitlements"
    condition=TAKEREC_STORE
    if [[ -z "${1:-}" ]]; then
        printf '请为商店测试版指定单独的 .app 路径。\n' >&2
        exit 2
    fi
fi
app="${1:-"$project/build.noindex/简录.app"}"
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
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers"
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
if [[ "$condition" == TAKEREC_DESKTOP ]]; then
    cp -R "$project/App/PhoneReceiver" "$bundle/Contents/Resources/PhoneReceiver"
fi

proofreader="$project/build.noindex/ProofreaderDependencies"
proofreader_framework="$proofreader/llama.framework"
proofreader_model="$proofreader/qwen2.5-1.5b-instruct-q4_k_m.gguf"
proofreader_flags=()
if [[ -d "$proofreader_framework" || -f "$proofreader_model" ]]; then
    if [[ ! -d "$proofreader_framework" || ! -f "$proofreader_model" ]]; then
        printf '离线校对资源不全，请先准备引擎和模型。\n' >&2
        exit 2
    fi
    mkdir -p "$bundle/Contents/Frameworks"
    ditto "$proofreader_framework" "$bundle/Contents/Frameworks/llama.framework"
    cp -c "$proofreader_model" "$bundle/Contents/Resources/" 2>/dev/null || cp "$proofreader_model" "$bundle/Contents/Resources/"
    cp "$project/App/LlamaCpp-LICENSE.txt" "$project/App/Qwen-LICENSE.txt" "$bundle/Contents/Resources/"
    codesign "${signing_args[@]}" "$bundle/Contents/Frameworks/llama.framework"
    proofreader_flags=(-F "$proofreader" -framework llama -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library -D "$condition" \
        -target "$arch-apple-macosx15.0" -sdk "$sdk" \
        -module-cache-path "$build/modules" -module-name TakeRec \
        ${proofreader_flags[@]+"${proofreader_flags[@]}"} "$project"/Sources/*.swift -o "$build/TakeRec-$arch"
    xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library \
        -target "$arch-apple-macosx15.0" -sdk "$sdk" \
        -module-cache-path "$build/modules" "$project/App/TakeRecRelaunch.swift" -o "$build/TakeRecRelaunch-$arch"
done
xcrun lipo -create "$build/TakeRec-arm64" "$build/TakeRec-x86_64" -output "$bundle/Contents/MacOS/TakeRec"
helper="$bundle/Contents/Helpers/TakeRecRelaunch"
xcrun lipo -create "$build/TakeRecRelaunch-arm64" "$build/TakeRecRelaunch-x86_64" -output "$helper"
helper_signing=("${signing_args[@]}" --identifier "$bundle_id.Relaunch")
if [[ "$condition" == TAKEREC_STORE ]]; then
    helper_signing+=(--entitlements "$project/App/DeskTake-Relaunch-Store.entitlements")
fi
codesign "${helper_signing[@]}" "$helper"
codesign "${signing_args[@]}" --entitlements "$entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"

if [[ -e "$app" ]]; then
    mv -- "$app" "$build/previous.app"
fi
mv -- "$bundle" "$app"
printf '%s\n' "$app"
