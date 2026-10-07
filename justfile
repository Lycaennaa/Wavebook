# Distill is a cli wrapper making it easier for humans and agents to use xcode/swift/cargo commands by showing only errors/warnings and other non noise. https://github.com/lycaennaa/distill

# Always sort recipes alphabetically

distill_available := `command -v distill >/dev/null 2>&1 && printf true || printf false`

worktree_root := justfile_directory()
worktree_build_dir := worktree_root + "/.build"
derived_data := worktree_build_dir + "/derived-data"
xcode_build_options := "-derivedDataPath \"" + derived_data + "\" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto"
debug_products := derived_data + "/Build/Products/Debug"
release_products := derived_data + "/Build/Products/Release"
test_result_bundle := worktree_build_dir + "/test-results.xcresult"

@build:
    if [ "{{ distill_available }}" = "true" ]; then distill xcode build -- -scheme Wavebook -configuration Debug {{ xcode_build_options }}; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Debug {{ xcode_build_options }} build; fi

@build-release:
    if [ "{{ distill_available }}" = "true" ]; then distill xcode build -- -scheme Wavebook -configuration Release {{ xcode_build_options }}; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release {{ xcode_build_options }} build; fi

@build-release-move:
    if [ "{{ distill_available }}" = "true" ]; then distill xcode build --mv -- -scheme Wavebook -configuration Release {{ xcode_build_options }}; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release {{ xcode_build_options }} build && mv "{{ release_products }}/Wavebook.app" /Applications/; fi

@build-release-omv: build-release-move
    open /Applications/Wavebook.app

@build-release-open:
    if [ "{{ distill_available }}" = "true" ]; then distill xcode build --open -- -scheme Wavebook -configuration Release {{ xcode_build_options }}; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release {{ xcode_build_options }} build && open "{{ release_products }}/Wavebook.app"; fi

@check: check-generated-project check-tooling check-pbx lint test

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

@check-generated-project:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v xcodegen >/dev/null 2>&1; then printf 'XcodeGen 2.46.0 or later is required\n' >&2; exit 1; fi
    mkdir -p "{{ worktree_build_dir }}"
    project_file="{{ worktree_root }}/Wavebook.xcodeproj/project.pbxproj"
    original_project="$(mktemp "{{ worktree_build_dir }}/project.pbxproj.XXXXXX")"
    cp "$project_file" "$original_project"
    trap 'rm -f "$original_project"' EXIT
    xcodegen generate --spec "{{ worktree_root }}/project.yml"
    if ! cmp -s "$original_project" "$project_file"; then
        diff -u "$original_project" "$project_file" || true
        printf 'Generated project was out of date; review the regenerated project file\n' >&2
        exit 1
    fi

@check-package-locks:
    python3 -B scripts/check-package-locks.py

@check-pbx:
    python3 -B scripts/check-pbx-identifiers.py

@check-tooling: check-package-locks
    sh -n scripts/install-hooks.sh

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

@clean:
    rm -rf "{{ worktree_build_dir }}"

@generate-project:
    xcodegen generate --spec project.yml

@install-hooks:
    sh scripts/install-hooks.sh

@lint:
    if [ "{{ distill_available }}" = "true" ]; then distill swift lint -- --config .swiftlint.yml; else swiftlint lint --config .swiftlint.yml; fi

@lint-fix:
    if [ "{{ distill_available }}" = "true" ]; then distill swift lint -- --fix --config .swiftlint.yml; else swiftlint lint --fix --config .swiftlint.yml; fi

@run: build
    open "{{ debug_products }}/Wavebook.app"

@setup:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v brew >/dev/null 2>&1 || { printf 'Install Homebrew first.\n' >&2; exit 1; }
    if ! command -v xcodegen >/dev/null 2>&1; then HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen; fi
    if ! command -v swiftlint >/dev/null 2>&1; then HOMEBREW_NO_AUTO_UPDATE=1 brew install swiftlint; fi

@test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ worktree_build_dir }}"
    result_bundle="{{ test_result_bundle }}"
    rm -rf "$result_bundle"
    printf 'XCTest result bundle retained on failure: %s\n' "$result_bundle"
    status=0
    if [ "{{ distill_available }}" = "true" ]; then
        distill xcode test -- -scheme WavebookTests -configuration Debug {{ xcode_build_options }} -resultBundlePath "$result_bundle" || status=$?
    else
        xcodebuild -project Wavebook.xcodeproj -scheme WavebookTests -configuration Debug {{ xcode_build_options }} -resultBundlePath "$result_bundle" test || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
        rm -rf "$result_bundle"
    fi
    exit "$status"
