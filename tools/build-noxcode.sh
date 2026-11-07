#!/bin/sh
# build-noxcode.sh — Build RTL812xLucy.kext with only the Command Line Tools
#
# Usage (run on macOS; neither Xcode.app nor sudo is required):
#   sh tools/build-noxcode.sh [source-root] [MacKernelSDK-root]
#   MACKERNELSDK=/path/to/MacKernelSDK sh tools/build-noxcode.sh
#
# Why xcodebuild is not used:
#   The build machine has only the Command Line Tools, and /usr/bin/xcodebuild is a stub.
#   A kext needs clang, the kernel headers, libkmod and `ld -kext`, all of which ship with
#   the CLT. This script reproduces the target's build settings (x86_64, gnu++20, prefix
#   header, MacKernelSDK headers) without the Xcode project.
#
# Output: build-noxcode.XXXXXX/RTL812xLucy.kext (a fresh directory per build; old ones are
#         kept). The path of the newest build is written to latest-noxcode-build.txt.
# Note: this script only builds. It does not deploy, and it does not touch
#       /Library/Extensions or any kernel collection.
set -eu

[ "$(uname -s)" = "Darwin" ] || { echo "This script can only run on macOS" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SRC=${1:-$ROOT}
SRC=$(CDPATH= cd -- "$SRC" && pwd)
DRV="$SRC/RTL812xLucy"
PROJ="$SRC/RTL812xLucy.xcodeproj/project.pbxproj"
NAME=RTL812xLucy
IDENT=com.insanelymac.RTL812xLucy
PCH="$DRV/RTL8125LucyPrefix.pch"

echo "== Environment =="
echo "source : $SRC"
xcrun clang++ --version | head -1
echo "sdk(CLT): $(xcrun --sdk macosx --show-sdk-version)"

# ---- Source files: mirror the target's synchronized group (all .cpp/.c in RTL812xLucy) ----
CPP_SOURCES="RTL812xLucy RTL812xLucyHardware RTL812xLucySetup RTL812xLucyVTD \
RTL8125LucyRxPool RTL812xUserClient rtl8127_fiber rtl812xx"
C_SOURCES="rtl812x_eeprom rtl812x_firmware rtl812x_phy"

[ -d "$DRV" ] || { echo "Source directory not found: $DRV" >&2; exit 1; }
for name in $CPP_SOURCES; do
    [ -f "$DRV/$name.cpp" ] || { echo "Missing source file: $name.cpp" >&2; exit 1; }
done
for name in $C_SOURCES; do
    [ -f "$DRV/$name.c" ] || { echo "Missing source file: $name.c" >&2; exit 1; }
done
for f in Info.plist gpl.txt; do
    [ -f "$DRV/$f" ] || { echo "Missing file: $f" >&2; exit 1; }
done
[ -f "$PCH" ] || { echo "Missing prefix header: $PCH" >&2; exit 1; }
command -v c++filt >/dev/null 2>&1 || { echo "c++filt not found" >&2; exit 1; }

# ---- Version numbers: read them from the project so the kext matches the source ----
CURVER=1.1.302
MKTVER=1.1.3
if [ -f "$PROJ" ]; then
    v=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    if [ -n "$v" ]; then CURVER=$v; fi
    v=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PROJ" | head -1)
    if [ -n "$v" ]; then MKTVER=$v; fi
fi
echo "version: $CURVER (marketing $MKTVER)"

# ---- Locate MacKernelSDK ----
SDK=${2:-${MACKERNELSDK:-}}
if [ -z "$SDK" ]; then
    if [ -d "$SRC/MacKernelSDK/Headers" ]; then
        SDK="$SRC/MacKernelSDK"
    else
        for cand in "$HOME"/MacKernelSDK "$HOME"/src/MacKernelSDK; do
            if [ -d "$cand/Headers" ]; then SDK=$cand; break; fi
        done
    fi
fi
[ -n "$SDK" ] || { echo "MacKernelSDK not found; pass it as the second argument or set MACKERNELSDK" >&2; exit 1; }
SDK=$(CDPATH= cd -- "$SDK" && pwd)
[ -d "$SDK/Headers/IOKit" ] || { echo "MacKernelSDK headers are incomplete: $SDK" >&2; exit 1; }
[ -f "$SDK/Library/universal/libkmodc++.a" ] || { echo "Missing libkmodc++.a" >&2; exit 1; }
[ -f "$SDK/Library/x86_64/libkmod.a" ] || { echo "Missing libkmod.a (x86_64)" >&2; exit 1; }
echo "kernel SDK: $SDK"

# ---- Build directory: new one per build, previous outputs are preserved ----
W=$(mktemp -d "$ROOT/build-noxcode.XXXXXX")
KEXT="$W/$NAME.kext"
BIN="$KEXT/Contents/MacOS/$NAME"
mkdir -p "$W/objects" "$KEXT/Contents/MacOS" "$KEXT/Contents/Resources"
echo "work   : $W"

# ---- kmod_info ----
# xcodebuild generates this translation unit through CreateKModInfo.perl. Bypassing Xcode
# means providing it here, otherwise the binary has no _kmod_info and the kext is rejected.
KMOD="$W/kmod-info.cpp"
cat > "$KMOD" <<'KMOD_EOF'
#include <mach/kmod.h>
#include <libkern/OSKextLib.h>

extern "C" {
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);

KMOD_EXPLICIT_DECL(com.insanelymac.RTL812xLucy, "@VERSION@", _start, _stop);

__attribute__((visibility("hidden"))) kmod_start_func_t *_realmain = nullptr;
__attribute__((visibility("hidden"))) kmod_stop_func_t  *_antimain = nullptr;
__attribute__((visibility("hidden"))) int _kext_apple_cc = __APPLE_CC__;
}
KMOD_EOF
sed "s/@VERSION@/$CURVER/" "$KMOD" > "$KMOD.tmp"
mv "$KMOD.tmp" "$KMOD"

# ---- Compiler flags ----
# Mirror the target: x86_64, gnu++20, the prefix header, MacKernelSDK headers. -O0 keeps the
# conservative choice used by the other CLT build scripts in this workspace.
CFLAGS_COMMON="-arch x86_64 -mkernel -fapple-kext -mno-red-zone \
 -nostdinc++ -O0 \
 -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -D__APPLE_KEXT__ \
 -fno-builtin -fno-common -fno-exceptions -fno-rtti \
 -fstack-protector -fno-threadsafe-statics \
 -Wno-unused-parameter -Wno-unused-function"
CFLAGS="$CFLAGS_COMMON -std=gnu++20"
CFLAGS_C="$CFLAGS_COMMON -std=gnu17"
# The driver carries a small Linux compatibility tree. ethtool.h includes "if_ether.h"
# relative to linux/, and the kernel-style includes are spelled <linux/...>, so both the
# compat root and its uapi root have to be on the search path.
INCLUDES="-I $SDK/Headers -I $DRV -I $DRV/linux -I $DRV/linux/uapi -I $DRV/linux/uapi/linux"

compile_cpp() {
    echo "  CXX $(basename "$1")"
    # shellcheck disable=SC2086
    xcrun clang++ $CFLAGS $INCLUDES -include "$PCH" -c "$1" -o "$2"
}

compile_c() {
    echo "  CC  $(basename "$1")"
    # shellcheck disable=SC2086
    xcrun clang $CFLAGS_C $INCLUDES -include "$PCH" -c "$1" -o "$2"
}

echo "== Compilation =="
for name in $CPP_SOURCES; do
    compile_cpp "$DRV/$name.cpp" "$W/objects/$name.o"
done
for name in $C_SOURCES; do
    compile_c "$DRV/$name.c" "$W/objects/$name.o"
done
compile_cpp "$KMOD" "$W/objects/kmod-info.o"

echo "== Linking =="
# -kext leaves kernel symbols undefined on purpose (resolved at load), so the driver's own
# symbols have to be checked separately below.
# shellcheck disable=SC2086
xcrun ld -kext -arch x86_64 "$W"/objects/*.o \
    "$SDK/Library/universal/libkmodc++.a" \
    "$SDK/Library/x86_64/libkmod.a" \
    -o "$BIN"

echo "== Bundle validation =="
nm "$BIN" > "$W/symbols.txt"
for sym in ' _kmod_info$' ' __start$' ' __stop$'; do
    grep -q "$sym" "$W/symbols.txt" || { echo "Missing symbol: $sym" >&2; exit 1; }
done
FT=$(otool -h "$BIN" | awk 'NR>1{print $5}' | tail -1)
[ "$FT" = "11" ] || { echo "filetype=$FT; expected 11 (MH_KEXT_BUNDLE)" >&2; exit 1; }
echo "  MH_KEXT_BUNDLE OK"
if nm -u "$BIN" | c++filt | grep -E '(^| )RTL8125::|RTL812xUserClient::|RTL8125LucyRxPool' > "$W/unresolved.txt"; then
    echo "Unresolved driver-internal symbols (a source file may be missing):" >&2
    cat "$W/unresolved.txt" >&2
    exit 1
fi
echo "  All driver-internal symbols are defined: OK"

echo "== Info.plist =="
# The source Info.plist is an Xcode template; a manual build has to expand the variables or
# CFBundleIdentifier / the version stay literal and the kext will not match.
sed -e "s/\$(EXECUTABLE_NAME)/$NAME/g" \
    -e "s/\${PRODUCT_NAME:rfc1034identifier}/$NAME/g" \
    -e "s/\$(PRODUCT_NAME)/$NAME/g" \
    -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$CURVER/g" \
    -e "s/\$(MARKETING_VERSION)/$MKTVER/g" \
    -e "s/\$MODULE_VERSION/$CURVER/g" \
    "$DRV/Info.plist" > "$KEXT/Contents/Info.plist"
plutil -lint "$KEXT/Contents/Info.plist"
if grep -E '\$\{|\$\(|MODULE_VERSION|MARKETING_VERSION' "$KEXT/Contents/Info.plist" >/dev/null; then
    echo "Info.plist still contains unexpanded Xcode variables" >&2
    exit 1
fi
cp "$DRV/gpl.txt" "$KEXT/Contents/Resources/"

echo "== Signing (ad hoc) =="
codesign --force --sign - --timestamp=none "$KEXT"
codesign --verify --strict "$KEXT"

printf '%s\n' "$KEXT" > "$ROOT/latest-noxcode-build.txt"
echo
echo "BUILD OK: $KEXT ($NAME $CURVER)"
echo "Not deployed: /Library/Extensions and kernel collections were not modified."
