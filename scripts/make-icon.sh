#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

source_icon="$PWD/Resources/AppIcon.png"
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" > /dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil -c icns "$iconset" -o "$PWD/Resources/AppIcon.icns"
printf '已生成：%s\n' "$PWD/Resources/AppIcon.icns"
