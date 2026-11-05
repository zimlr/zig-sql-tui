# Dependencies

## Runtime and build

- SQLite 3.54.1 supplies the database engine. The vendored amalgamation is linked statically and remains in the public domain.
- The [SQLite amalgamation mirror](https://github.com/fascinatingwind/sqlite3-amalgamation) supplies the source at commit `75e10863c10e714f2480554d7b8f344489b4c16c`. Verify file digests with `sha256sum -c vendor/sqlite/SHA256SUMS`.
- Zig 0.17.1 supplies the compiler and build system without a runtime dependency. The [x86_64 compiler archive](https://github.com/vx-org/mirrors/releases/tag/zig-0.17.1) has SHA-256 `3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a`.
- The [Zig npm package](https://registry.npmjs.org/@zigpm/zig-linux-x64/-/zig-linux-x64-0.17.1.tgz) supplies the compiler archive for CI. Its SHA-256 is `fa23b02630bf478a588e66aa049236e1f5b0d920e7a84dc7979400ac3eee6346`. Verify both archives before extraction and use.

## CI actions

GitHub Actions requires full Git commit identifiers instead of SHA-256 archive digests for actions.

- [actions/checkout 7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) uses commit `3d3c42e5aac5ba805825da76410c181273ba90b1`.
- [actions/upload-artifact 7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) uses commit `cf430e030ddbb5b0abf93d22962f4752f3646cd9`.
- [actions/download-artifact 8.0.2](https://github.com/actions/download-artifact/releases/tag/v8.0.2) uses commit `9000827ccba6bdab643e8b6fd33ac0654aef8333`.

## CI environments

The GitHub-hosted `ubuntu-26.04` and `ubuntu-26.04-arm` labels identify mutable runner images. GitHub does not expose an immutable image digest in `runs-on`. Preinstalled utility versions can change.

The Termux diagnostic uses [termux-packages](https://github.com/termux/termux-packages) at commit `d51f6edc0aa165feb9e13de6b6bbe0d483a4fa7e`. Its source archive has SHA-256 `47e80a0cf47daad7e10d657ad2ed18a6d75e4b558b32e5581851508a48076763`. The [package-builder image](https://github.com/termux/termux-packages/pkgs/container/package-builder) uses amd64 digest `sha256:35692c4bf40ff2f5389a39897584765236baa3ae5bf6906a2f1cd0ace3d3c502`.
