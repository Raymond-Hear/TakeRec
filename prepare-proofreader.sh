#!/bin/bash
set -euo pipefail

project="$(cd -- "$(dirname -- "$0")" && pwd)"
destination="$project/build.noindex/ProofreaderDependencies"
model_name=qwen2.5-1.5b-instruct-q4_k_m.gguf
model_checksum=6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e
framework_checksum=d324b558ef4622deb485e1124871304953a4cc7dc2c478a81521c153bd6c5205
archive_checksum=c19be78b5f00d8d29a25da41042cb7afa094cbf6280a225abe614b03b20029ab

matches_checksum() {
    [[ -f "$2" ]] && printf '%s  %s\n' "$1" "$2" | shasum -a 256 -c - >/dev/null
}

if matches_checksum "$model_checksum" "$destination/$model_name" &&
   matches_checksum "$framework_checksum" "$destination/llama.framework/llama"; then
    printf '离线校对资源已就绪。\n'
    exit 0
fi

mkdir -p "$project/build.noindex"
staging="$(mktemp -d "$project/build.noindex/.proofreader.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

curl --fail --location --retry 2 -o "$staging/llama.zip" \
    'https://github.com/ggml-org/llama.cpp/releases/download/b5046/llama-b5046-xcframework.zip'
matches_checksum "$archive_checksum" "$staging/llama.zip"
ditto -x -k "$staging/llama.zip" "$staging/engine"
framework="$staging/engine/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework"
matches_checksum "$framework_checksum" "$framework/llama"

if ! matches_checksum "$model_checksum" "$destination/$model_name"; then
    curl --fail --location --retry 2 -o "$staging/$model_name" \
        "https://www.modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/$model_name"
    matches_checksum "$model_checksum" "$staging/$model_name"
fi

mkdir -p "$destination"
rm -rf -- "$destination/llama.framework"
mv -- "$framework" "$destination/llama.framework"
if [[ -f "$staging/$model_name" ]]; then mv -f -- "$staging/$model_name" "$destination/$model_name"; fi
printf '离线校对资源已就绪。\n'
