# Release procedure

The Release workflow runs only through manual dispatch. Creating a release requires an explicit request from the repository user for that release. A previous request does not authorize subsequent releases.

Agents MUST NOT start a release in response to a merge, schedule, passing test, or inferred intent. The `confirmed` input records the request but does not establish its origin. Agents must verify the request in the conversation before dispatch.

## Version policy

Release tags use a `v` prefix followed by a [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) version. The first published release is exactly `v1.0.0`. That release uses the former `zig-sql-tui` binary and archive names, while current builds use `zsqt`.

After the initial release, select the version from the compatibility impact of all changes since the highest-precedence published release:

- Increment MAJOR for incompatible public interface changes.
- Increment MINOR for backward-compatible functionality or deprecations.
- Increment PATCH for backward-compatible fixes.

A prerelease identifier marks a prerelease, and build metadata does not affect precedence. Published versions are immutable. A candidate must have greater precedence than every published release, including prereleases. Numeric core and prerelease identifiers cannot contain leading zeroes.

The workflow validates version syntax and precedence, but it cannot determine the compatibility impact of changes. Inspect the changes before selecting the version. Request clarification when the impact or requested version is uncertain.

## Dispatch

1. Confirm that the repository user explicitly requested a new release and review the intended version.
2. Ensure the release workflow and intended changes are merged into the default branch. Review the changes since the highest-precedence published release.
3. Verify that tracked contents differ from that release and that its tag is an ancestor of the default branch. When no published release exists, use `v1.0.0`.
4. Dispatch the workflow on the default branch with the version and confirmation inputs. Replace `v1.0.0` with the reviewed version for subsequent releases.

```sh
branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
gh workflow run release.yml --ref "$branch" -f version=v1.0.0 -f confirmed=true
```

The workflow rechecks release history and the default branch immediately before publication. It rejects existing tags, unchanged tracked contents, invalid history, and versions without increased precedence. A release cannot be dispatched from a non-default branch.

## Validation and assets

The workflow verifies the pinned compiler and SQLite sources, runs the security and integration tests, and builds static PIE binaries for x86_64 and aarch64 Linux. A native Linux ARM runner also tests the aarch64 binary.

Release assets contain the binary, project documentation, logo, and SQLite license for each architecture. `SHA256SUMS` contains checksums for both archives. Broader Termux compatibility remains unverified and the release notes state that limitation.

A failure during publication can leave a tag or draft release. Inspect the repository state before retrying. Do not replace or delete an existing release or tag without explicit user authorization.
