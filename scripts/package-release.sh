#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)
SCHEME=${SCHEME:-Wavebook}
CONFIGURATION=${CONFIGURATION:-Release}
PACKAGE_NAME=${APP_NAME:-}
BUNDLE_IDENTIFIER=${BUNDLE_IDENTIFIER:-com.lycaennaa.wavebook}
VERSION=${VERSION:-}
DIST_DIR=${DIST_DIR:-$ROOT/dist}
DERIVED_DATA=${DERIVED_DATA:-$ROOT/.build/derived-data}
ADHOC_SIGN=${ADHOC_SIGN:-YES}
STRIP_RELEASE=${STRIP_RELEASE:-NO}

case "$PACKAGE_NAME" in
    */*)
        printf '%s\n' 'APP_NAME must not contain a slash' >&2
        exit 2
        ;;
esac

case "$ADHOC_SIGN" in
    YES|NO) ;;
    *)
        printf '%s\n' 'ADHOC_SIGN must be YES or NO' >&2
        exit 2
        ;;
esac
case "$STRIP_RELEASE" in
    YES|NO) ;;
    *)
        printf '%s\n' 'STRIP_RELEASE must be YES or NO' >&2
        exit 2
        ;;
esac

PROJECT_PATH=$ROOT/Wavebook.xcodeproj
if [ ! -d "$PROJECT_PATH" ] || [ -L "$PROJECT_PATH" ] || [ -L "$PROJECT_PATH/project.pbxproj" ] || [ ! -f "$PROJECT_PATH/project.pbxproj" ]; then
    printf 'Xcode project not found: %s\n' "$PROJECT_PATH" >&2
    exit 1
fi

for command in codesign cp ditto mkdir mktemp mv plutil python3 rm shasum strip xattr xcodebuild; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    fi
done

canonical_path() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

BUILD_ROOT=$ROOT/.build
BUILD_ROOT_REAL=$(canonical_path "$BUILD_ROOT")
if [ "$BUILD_ROOT_REAL" != "$BUILD_ROOT" ]; then
    printf 'Build directory must not be a symlink: %s\n' "$BUILD_ROOT" >&2
    exit 2
fi

case "$DERIVED_DATA" in
    /*) ;;
    *)
        printf '%s\n' 'DERIVED_DATA must be an absolute path inside the repository .build directory' >&2
        exit 2
        ;;
esac
DERIVED_DATA_REAL=$(canonical_path "$DERIVED_DATA")
case "$DERIVED_DATA_REAL" in
    "$BUILD_ROOT_REAL"/*) ;;
    *)
        printf 'DERIVED_DATA must resolve inside %s\n' "$BUILD_ROOT" >&2
        exit 2
        ;;
esac
DERIVED_DATA=$DERIVED_DATA_REAL

DIST_ROOT=$ROOT/dist
DIST_ROOT_REAL=$(canonical_path "$DIST_ROOT")
if [ "$DIST_ROOT_REAL" != "$DIST_ROOT" ]; then
    printf 'Distribution directory must not be a symlink: %s\n' "$DIST_ROOT" >&2
    exit 2
fi
case "$DIST_DIR" in
    /*) ;;
    *)
        printf '%s\n' 'DIST_DIR must be an absolute path inside the repository dist directory' >&2
        exit 2
        ;;
esac
DIST_DIR_REAL=$(canonical_path "$DIST_DIR")
case "$DIST_DIR_REAL" in
    "$DIST_ROOT_REAL"|"$DIST_ROOT_REAL"/*) ;;
    *)
        printf 'DIST_DIR must resolve inside %s\n' "$DIST_ROOT" >&2
        exit 2
        ;;
esac
DIST_DIR=$DIST_DIR_REAL

OUTPUT_DIR=
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$OUTPUT_DIR" ]; then
        if ! rm -rf "$OUTPUT_DIR" && [ "$status" -eq 0 ]; then
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$DERIVED_DATA" "$DIST_DIR" "$ROOT/.build/derived-data/SourcePackages"

xcodebuild \
    -project "$PROJECT_PATH" \
    -configuration "$CONFIGURATION" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$ROOT/.build/derived-data/SourcePackages" \
    "APP_BUNDLE_IDENTIFIER=$BUNDLE_IDENTIFIER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    SDKROOT=auto \
    build

case "$CONFIGURATION" in
    ''|.|..|*/*)
        printf '%s\n' 'CONFIGURATION must be a single non-parent path component' >&2
        exit 2
        ;;
esac

PRODUCTS_ROOT=$DERIVED_DATA/Build/Products
PRODUCTS_ROOT_REAL=$(canonical_path "$PRODUCTS_ROOT")
case "$PRODUCTS_ROOT_REAL" in
    "$DERIVED_DATA"/*) ;;
    *)
        printf 'Build products directory must stay inside %s\n' "$DERIVED_DATA" >&2
        exit 1
        ;;
esac
PRODUCTS_DIR=$PRODUCTS_ROOT/$CONFIGURATION
PRODUCTS_DIR_REAL=$(canonical_path "$PRODUCTS_DIR")
case "$PRODUCTS_DIR_REAL" in
    "$PRODUCTS_ROOT_REAL"/*) ;;
    *)
        printf 'Configuration products directory must stay inside %s\n' "$PRODUCTS_ROOT" >&2
        exit 1
        ;;
esac
APP_PATH=
for candidate in "$PRODUCTS_DIR"/*.app; do
    if [ ! -d "$candidate" ]; then
        continue
    fi
    if [ -L "$candidate" ]; then
        printf 'Built app must not be a symlink: %s\n' "$candidate" >&2
        exit 1
    fi
    candidate_real=$(canonical_path "$candidate")
    case "$candidate_real" in
        "$PRODUCTS_DIR_REAL"/*) ;;
        *)
            printf 'Built app must stay inside %s\n' "$PRODUCTS_DIR" >&2
            exit 1
            ;;
    esac
    if [ -n "$APP_PATH" ]; then
        printf 'Multiple app products found in %s\n' "$PRODUCTS_DIR" >&2
        exit 1
    fi
    APP_PATH=$candidate
done
if [ -z "$APP_PATH" ]; then
    printf 'Built app not found in: %s\n' "$PRODUCTS_DIR" >&2
    exit 1
fi

BUILT_APP_NAME=${APP_PATH##*/}
BUILT_APP_NAME=${BUILT_APP_NAME%.app}
PACKAGE_NAME=${PACKAGE_NAME:-$BUILT_APP_NAME}
VERSION=${VERSION:-$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")}
case "$VERSION" in
    ''|*[!A-Za-z0-9._-]*)
        printf '%s\n' 'VERSION must contain only letters, numbers, dots, underscores, or hyphens' >&2
        exit 2
        ;;
esac
OUTPUT_DIR=$(mktemp -d "$DIST_DIR/.package-output.XXXXXX")
STAGED_APP_PATH=$OUTPUT_DIR/$BUILT_APP_NAME.app
ditto "$APP_PATH" "$STAGED_APP_PATH"
APP_PATH=$STAGED_APP_PATH

EXECUTABLE_PATH=$APP_PATH/Contents/MacOS/$BUILT_APP_NAME
if [ ! -f "$EXECUTABLE_PATH" ]; then
    printf 'App executable not found: %s\n' "$EXECUTABLE_PATH" >&2
    exit 1
fi

strip_frameworks() {
    for framework in "$APP_PATH"/Contents/Frameworks/*.framework; do
        if [ ! -d "$framework" ]; then
            continue
        fi
        framework_name=${framework##*/}
        framework_name=${framework_name%.framework}
        framework_executable=$framework/Versions/A/$framework_name
        if [ ! -f "$framework_executable" ]; then
            framework_executable=$framework/$framework_name
        fi
        if [ -f "$framework_executable" ]; then
            strip -x "$framework_executable"
        fi
    done
}

sign_frameworks() {
    for framework in "$APP_PATH"/Contents/Frameworks/*.framework; do
        if [ -d "$framework" ]; then
            codesign --force --sign - --timestamp=none "$framework"
        fi
    done
}

if [ "$STRIP_RELEASE" = YES ]; then
    strip -x "$EXECUTABLE_PATH"
    strip_frameworks
fi
cp "$ROOT/LICENSE" "$APP_PATH/Contents/Resources/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.txt"
xattr -rc "$APP_PATH"

if [ "$ADHOC_SIGN" = YES ]; then
    sign_frameworks
    codesign --force --sign - --timestamp=none "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"
fi

python3 -B "$ROOT/scripts/check-release-privacy.py" "$APP_PATH" "$ROOT" "$BUNDLE_IDENTIFIER"

ZIP_PATH=$DIST_DIR/$PACKAGE_NAME-$VERSION.zip
CHECKSUM_PATH=$ZIP_PATH.sha256
for output in "$ZIP_PATH" "$CHECKSUM_PATH"; do
    if [ -d "$output" ]; then
        printf 'Release artifact path is a directory: %s\n' "$output" >&2
        exit 2
    fi
done

ZIP_TEMP=$OUTPUT_DIR/$PACKAGE_NAME-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_TEMP"
python3 -B "$ROOT/scripts/check-release-privacy.py" "$ZIP_TEMP" "$ROOT" "$BUNDLE_IDENTIFIER"
xattr -c "$ZIP_TEMP"
mv -f "$ZIP_TEMP" "$ZIP_PATH"
(
    cd "$DIST_DIR"
    shasum -a 256 "./${ZIP_PATH##*/}" > "${CHECKSUM_PATH##*/}"
)

printf 'Created:\n  %s\n  %s\n' "$ZIP_PATH" "$CHECKSUM_PATH"