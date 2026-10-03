# Distill is a cli wrapper making it easier for humans and agents to use xcode/swift/cargo commands by showing only errors/warnings and other non noise. https://github.com/lycaennaa/distill

check-ci-toolchain:
    #!/usr/bin/env bash
    set -euo pipefail
    test "$(uname -s)" = Darwin
    xcode_output="$(xcodebuild -version)"
    swift_output="$(swift --version)"
    printf '%s\n%s\n' "$xcode_output" "$swift_output"
    xcode_version="$(printf '%s\n' "$xcode_output" | python3 -c 'import sys; print(sys.stdin.readline().split()[1])')"
    swift_version="$(printf '%s\n' "$swift_output" | python3 -c 'import re, sys; match=re.search(r"Swift version ([0-9.]+)", sys.stdin.read()); print(match.group(1) if match else "")')"
    if [[ "$xcode_version" != 16.4 ]]; then
        printf 'CI parity expects Xcode 16.4; found %s\n' "$xcode_version" >&2
        exit 1
    fi
    if [[ "$swift_version" != 6.1.2 ]]; then
        printf 'CI parity expects Swift 6.1.2; found %s\n' "$swift_version" >&2
        exit 1
    fi

build:
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -scheme Wavebook -configuration Debug -derivedDataPath .build/debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Debug -derivedDataPath .build/debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

build-release:
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

build-release-open:
    if command -v distill >/dev/null 2>&1; then distill xcode build --open -- -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build && open .build/release/Build/Products/Release/*.app; fi

test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .build
    result_bundle=".build/test-$(date +%Y%m%d-%H%M%S).xcresult"
    printf 'XCTest result bundle: %s\n' "$result_bundle"
    if command -v distill >/dev/null 2>&1; then
        distill xcode test -- -scheme WavebookTests -configuration Debug -derivedDataPath .build/test -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto
    else
        xcodebuild -project Wavebook.xcodeproj -scheme WavebookTests -configuration Debug -derivedDataPath .build/test -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto test
    fi

package:
    sh scripts/package-release.sh

install-hooks:
    sh scripts/install-hooks.sh

check-pbx:
    python3 -B scripts/check-pbx-identifiers.py

lint:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --config .swiftlint.yml; else swiftlint lint --config .swiftlint.yml; fi

check-generated-project:
    @if ! command -v xcodegen >/dev/null 2>&1; then printf 'XcodeGen 2.46.0 or later is required\n' >&2; exit 1; fi
    xcodegen generate --spec project.yml
    git diff --exit-code -- Wavebook.xcodeproj

check-tooling:
    sh -n scripts/package-release.sh scripts/install-hooks.sh
    python3 -B scripts/check-package-locks.py

ci:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "${WAVEBOOK_DEVELOPER_DIR:-}" ]]; then
        export DEVELOPER_DIR="$WAVEBOOK_DEVELOPER_DIR"
    fi
    just check-ci-toolchain
    just check-generated-project
    just check-tooling
    just check-pbx
    just lint
    just test
    just build-release