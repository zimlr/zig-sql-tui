# Building

Zig 0.17.1 is required at `tools/zig/zig`. The compiler, caches, and outputs remain inside the workspace. Builds use vendored SQLite and do not download dependencies.

## Compiler setup

The following steps provision the pinned x86_64 Linux compiler. Python 3, `tar`, `xz`, and `sha256sum` are required.

```sh
(
set -eu
mkdir -p tools/zig .zig-cache/download .zig-cache/global .zig-cache/local .zig-cache/tmp
python3 - <<'PY'
import hashlib
from pathlib import Path
from urllib.request import urlopen

url = 'https://registry.npmjs.org/@zigpm/zig-linux-x64/-/zig-linux-x64-0.17.1.tgz'
path = Path('.zig-cache/download/zig.tgz')
with urlopen(url) as response, path.open('wb') as output:
    while chunk := response.read(1024 * 1024):
        output.write(chunk)
expected = 'fa23b02630bf478a588e66aa049236e1f5b0d920e7a84dc7979400ac3eee6346'
if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
    raise SystemExit('Zig package SHA-256 mismatch')
PY
tar -xzf .zig-cache/download/zig.tgz -C tools/zig --strip-components=1
echo '3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a  tools/zig/zig.tar.xz' | sha256sum -c
tar -xJf tools/zig/zig.tar.xz -C tools/zig --strip-components=1
./tools/zig/zig version
)
```

On other build hosts, provide a matching Zig 0.17.1 compiler and its libraries at the same path. The [dependency record](../DEPENDENCIES.md) lists compiler provenance and checksums.

## Linux builds

Build the x86_64 executable with the local compiler and caches:

```sh
mkdir -p .zig-cache/global .zig-cache/local .zig-cache/tmp
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache/local" \
TMPDIR="$PWD/.zig-cache/tmp" \
./tools/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall -Dstrip=true
```

Use `-Dtarget=aarch64-linux-musl` to build for aarch64 Linux. The output is `zig-out/bin/zig-sql-tui`.

## Implementation

SQLite is compiled into the executable from the vendored amalgamation. The TUI is implemented in the repository without a third-party TUI library. In particular, libvaxis is not a dependency.
