# Dependencies

- SQLite provides the database engine required by the application. The amalgamation is compiled in-tree and linked statically.
- Zig 0.17.1 provides the compiler and build system. It is a build tool, not a runtime dependency.
- SQLite 3.54.1 is vendored from the amalgamation mirror at commit `75e10863c10e714f2480554d7b8f344489b4c16c`. SQLite is public domain.
