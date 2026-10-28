#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swiftc_path="$(xcrun --find swiftc)"
testing_plugins="${swiftc_path:h:h}/lib/swift/host/plugins/testing"
testing_flags=()
if [[ -d "$testing_plugins" ]]; then
    testing_flags=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins")
fi
swift test --disable-sandbox --disable-xctest --enable-swift-testing --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "${testing_flags[@]}"
