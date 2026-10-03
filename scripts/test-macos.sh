#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
WORK="${REDMI_BUILD_WORK_DIR:-$ROOT/.build-work}"
mkdir -p "$WORK/swift-module-cache"
swiftc -parse-as-library -O -swift-version 5 -target arm64-apple-macos14 -module-cache-path "$WORK/swift-module-cache" "$ROOT/macOS/Sources/RedmiMirroring/Protocol.swift" "$ROOT/macOS/Validation/ProtocolValidation.swift" -o "$WORK/protocol-validation"
"$WORK/protocol-validation"
swiftc -parse-as-library -O -swift-version 5 -target arm64-apple-macos14 -module-cache-path "$WORK/swift-module-cache" "$ROOT/macOS/Sources/RedmiMirroring/Media.swift" "$ROOT/macOS/Validation/MediaValidation.swift" -o "$WORK/media-validation"
"$WORK/media-validation"
swiftc -parse-as-library -O -swift-version 5 -target arm64-apple-macos14 -module-cache-path "$WORK/swift-module-cache" "$ROOT/macOS/Sources/RedmiMirroring/Media.swift" "$ROOT/macOS/Validation/AudioContinuity.swift" -o "$WORK/audio-burst-validation"
"$WORK/audio-burst-validation"
