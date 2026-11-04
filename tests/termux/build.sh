# Test-only recipe. The repository does not declare a project license.
TERMUX_PKG_HOMEPAGE=https://github.com/zimlr/zig-sql-tui
TERMUX_PKG_DESCRIPTION="SQLite terminal interface compatibility test"
TERMUX_PKG_LICENSE="test-only"
TERMUX_PKG_MAINTAINER="@zimlr"
TERMUX_PKG_VERSION="0.0.0"
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_NO_ELF_CLEANER=true
TERMUX_PKG_NO_STRIP=true

termux_step_configure() { :; }
termux_step_make() { :; }
termux_step_make_install() {
    install -Dm700 "$TERMUX_PKG_BUILDER_DIR/zig-sql-tui" "$TERMUX_PREFIX/bin/zig-sql-tui"
}
# No package is published from this test recipe.
termux_step_install_license() { :; }
