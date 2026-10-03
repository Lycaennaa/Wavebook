# Distill is a cli wrapper making it easier for humans and agents to use xcode/swift/cargo commands by showing only errors/warnings and other non noise. https://github.com/lycaennaa/distill

build:
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -scheme Wavebook -configuration Debug -derivedDataPath .build/debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Debug -derivedDataPath .build/debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

build-release:
    if command -v distill >/dev/null 2>&1; then distill xcode build -- -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build; fi

build-release-open:
    if command -v distill >/dev/null 2>&1; then distill xcode build --open -- -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme Wavebook -configuration Release -derivedDataPath .build/release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto build && open .build/release/Build/Products/Release/*.app; fi

test:
    if command -v distill >/dev/null 2>&1; then distill xcode test -- -scheme WavebookTests -configuration Debug -derivedDataPath .build/test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto; else xcodebuild -project Wavebook.xcodeproj -scheme WavebookTests -configuration Debug -derivedDataPath .build/test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SDKROOT=auto test; fi

package:
    sh scripts/package-release.sh

install-hooks:
    sh scripts/install-hooks.sh

check-pbx:
    python3 -B scripts/check-pbx-identifiers.py

lint:
    if command -v distill >/dev/null 2>&1; then distill swift lint -- --config .swiftlint.yml; else swiftlint lint --config .swiftlint.yml; fi