# Release procedure

The Release workflow runs only through manual dispatch. Creating a release requires an explicit request from the repository user for that release. A previous request does not authorize subsequent releases.

Agents MUST NOT start a release in response to a merge, schedule, passing test, or inferred intent. The `confirmed` input records the request but does not establish its origin. Agents must verify the request in the conversation before dispatch.

## Version policy

Release tags use a `v` prefix followed by a [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html) version. The first published release is exactly `v1.0.0`. That release uses the former `zig-sql-tui` binary and archive names, while current builds use `zsqt`.

After the initial release, select the version from the compatibility impact of all changes since the highest-precedence published release:

| Increment | Compatibility impact |
| --- | --- |
| MAJOR | Incompatible public interface changes |
| MINOR | Backward-compatible functionality or deprecations |
| PATCH | Backward-compatible fixes |

A prerelease identifier marks a prerelease, and build metadata does not affect precedence. Published versions are immutable. A candidate must have greater precedence than every published release, including prereleases. Numeric core and prerelease identifiers cannot contain leading zeroes.

The workflow validates version syntax and precedence, but it cannot determine the compatibility impact of changes. Release API input must be a regular file no larger than 64 MiB. The validation tool requires Linux `statx`. Inspect the changes before selecting the version. Request clarification when the impact or requested version is uncertain.

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

The workflow creates archives and Debian packages for x86_64 and aarch64 Linux, and a Termux package for aarch64. Each Debian package includes the executable, shell completions, security policy, documentation, logo, and SQLite license. Published `v1.0.0` and `v2.0.0` releases do not contain Debian packages. `SHA256SUMS` covers both archives, both Debian packages, and the Termux package.

The Debian version preserves SemVer precedence. Prerelease identifiers use an encoded Debian representation, and build metadata is omitted from the package version. Control field `X-Zsqt-Release` retains the complete release tag. Debian packages install under `/usr`. The Termux package declares the `aarch64` architecture and installs under `$PREFIX`.

No project license or maintainer email address is declared in the repository. The Debian package records the maintainer name without an email address and includes the SQLite license separately. It is not represented as an official Debian archive package.

The workflow creates a draft release and uploads all assets before publication. It checks the uploaded asset names and SHA-256 digests, the default branch, and published release history before publishing the draft. This sequence supports immutable published releases and has passed local simulation, but no published release has used it yet. Broader Termux compatibility remains unverified and the release notes state that limitation.

A failure during publication can leave a tag or draft release. Inspect the repository state before retrying. Do not replace or delete an existing release or tag without explicit user authorization.
