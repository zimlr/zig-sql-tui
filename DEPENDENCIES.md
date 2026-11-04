# Dependencies

- SQLite 3.54.1 provides the required database engine. Its vendored amalgamation is compiled in-tree and linked statically. SQLite is public domain.
- SQLite source files come from [the amalgamation mirror](https://github.com/fascinatingwind/sqlite3-amalgamation) at commit `75e10863c10e714f2480554d7b8f344489b4c16c`. Verify their SHA-256 digests with `sha256sum -c vendor/sqlite/SHA256SUMS`.
- Zig 0.17.1 provides the compiler and build system. It is not a runtime dependency. The [x86_64 Linux compiler archive](https://github.com/vx-org/mirrors/releases/tag/zig-0.17.1) has SHA-256 `3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a`.
- CI obtains the compiler archive from [the Zig 0.17.1 npm package](https://registry.npmjs.org/@zigpm/zig-linux-x64/-/zig-linux-x64-0.17.1.tgz). The package has SHA-256 `fa23b02630bf478a588e66aa049236e1f5b0d920e7a84dc7979400ac3eee6346`. Verify both archives before extraction and use.
- CI uses [actions/checkout 7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) at Git commit `3d3c42e5aac5ba805825da76410c181273ba90b1`. GitHub Actions requires a full Git commit identifier rather than a SHA-256 archive digest.
- CI uses the GitHub-hosted `ubuntu-26.04` runner image and its preinstalled utilities. The label is a version fallback. GitHub does not expose an immutable image digest in `runs-on`, and installed utility versions can change.
