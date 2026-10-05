# Distill is a cli wrapper making it easier for humans and agents to use xcode/swift/cargo commands by showing only errors/warnings and other non noise. https://github.com/lycaennaa/distill

@check-ci-toolchain:
    #!/usr/bin/env bash
    set -euo pipefail
    test "$(uname -s)" = Darwin
    xcode_output="$(xcodebuild -version)"
    swift_output="$("$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" --version)"
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

@build:
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -scheme Wavebook -configuration Debug -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Debug -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi


@build-release:
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -scheme Wavebook -configuration Release -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

@build-release-open:
    if command -v distill >/dev/null 2>&1; then distill xcode build --open -- -scheme Wavebook -configuration Release -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release -derivedDataPath .build/derived-data CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build && open .build/derived-data/Build/Products/Release/*.app; fi

@test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .build
    result_bundle=".build/test-results.xcresult"
    rm -rf "$result_bundle"
    printf 'XCTest result bundle retained on failure: %s\n' "$result_bundle"
    status=0
    if command -v distill >/dev/null 2>&1; then
        distill xcode test -- -scheme WavebookTests -configuration Debug -derivedDataPath .build/derived-data -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto || status=$?
    else
        xcodebuild -project Wavebook.xcodeproj -scheme WavebookTests -configuration Debug -derivedDataPath .build/derived-data -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto test || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
        rm -rf "$result_bundle"
    fi
    exit "$status"

@package:
    sh scripts/package-release.sh

@install-hooks:
    sh scripts/install-hooks.sh

@check-pbx:
    python3 -B scripts/check-pbx-identifiers.py

@lint:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --config .swiftlint.yml; else swiftlint lint --config .swiftlint.yml; fi

@check-generated-project:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v xcodegen >/dev/null 2>&1; then printf 'XcodeGen 2.46.0 or later is required\n' >&2; exit 1; fi
    mkdir -p .build
    project_file="Wavebook.xcodeproj/project.pbxproj"
    original_project="$(mktemp .build/project.pbxproj.XXXXXX)"
    cp "$project_file" "$original_project"
    trap 'rm -f "$original_project"' EXIT
    xcodegen generate --spec project.yml
    if ! cmp -s "$original_project" "$project_file"; then
        diff -u "$original_project" "$project_file" || true
        printf 'Generated project was out of date; review the regenerated project file\n' >&2
        exit 1
    fi

@check-tooling:
    sh -n scripts/package-release.sh scripts/install-hooks.sh
    python3 -B scripts/check-package-locks.py

@ci:
    #!/usr/bin/env bash
    set -euo pipefail
    export DEVELOPER_DIR="${WAVEBOOK_DEVELOPER_DIR:-/Applications/Xcode16.4.app/Contents/Developer}"
    just check-ci-toolchain
    just check-generated-project
    just check-tooling
    just check-pbx
    just lint
    just test
    just build-release