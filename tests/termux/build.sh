# Test-only recipe. The repository does not declare a project license.
TERMUX_PKG_HOMEPAGE=https://github.com/zimlr/zsqt
TERMUX_PKG_DESCRIPTION="SQLite terminal interface compatibility test"
TERMUX_PKG_LICENSE="test-only"
TERMUX_PKG_MAINTAINER="@zimlr"
TERMUX_PKG_VERSION="0.0.0"
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_NO_ELF_CLEANER=true
TERMUX_PKG_NO_STRIP=true

# The candidate is prebuilt. The NDK tools are used only by package checks.
termux_step_setup_toolchain() {
    local ndk_bin="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local wrapper="$TERMUX_PKG_TMPDIR/bin"
    mkdir -p "$wrapper"
    printf '#!/bin/sh\nexec "%s/%s%s-clang" "$@"\n' \
        "$ndk_bin" "$TERMUX_HOST_PLATFORM" "$TERMUX_PKG_API_LEVEL" \
        > "$wrapper/$TERMUX_HOST_PLATFORM-clang"
    chmod +x "$wrapper/$TERMUX_HOST_PLATFORM-clang"
    export PATH="$wrapper:$ndk_bin:$PATH"
    export READELF=llvm-readelf AR=llvm-ar
}

termux_step_configure() { :; }
termux_step_make() { :; }
termux_step_make_install() {
    install -Dm700 "$TERMUX_PKG_BUILDER_DIR/zsqt" "$TERMUX_PREFIX/bin/zsqt"
}
# No package is published from this test recipe.
termux_step_install_license() { :; }
