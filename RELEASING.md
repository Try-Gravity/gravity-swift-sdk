# Releasing `GravitySDK` (Swift Package)

`VERSION` holds the SDK version. When a push to `main` changes it to a version that has no `v<VERSION>` tag on the public mirror, `sdk-release.yml` prepares a release PR; a version ending in `-unpublished` never ships. Source changes belong in this monorepo; do not edit the public mirror separately.

Swift Package Manager has no central registry — Xcode installs packages directly from a git repo. Since this monorepo is private, releases are published by mirroring `sdk-ios/` into the **public** [`Try-Gravity/gravity-swift-sdk`](https://github.com/Try-Gravity/gravity-swift-sdk) repo via the [`publish-sdk-ios.yml`](../.github/workflows/publish-sdk-ios.yml) workflow. Only the SDK source is public; the monorepo stays private. (This mirror pattern is standard — Stripe, Firebase, etc. do the same.)

Developers install with: Xcode → File → Add Package Dependencies → `https://github.com/Try-Gravity/gravity-swift-sdk`.

## One-time setup (repo maintainers)

1. **Create the public mirror repo** `Try-Gravity/gravity-swift-sdk` (empty, public, with a `main` branch).
2. **Fine-grained PAT.** Create a fine-grained personal access token scoped to only `Try-Gravity/gravity-swift-sdk` with **Contents: Read and write** and **Pull requests: Read and write** permissions.
3. **GitHub Environment.** Create a `swift-sdk-mirror` environment under Settings → Environments in this repo with the secret:
   - `SWIFT_SDK_MIRROR_TOKEN` — the PAT from step 2.

## Normal release (prepare, then finalize)

1. Make sure `sdk-ios/` on `main` is in the state you want to ship.
2. The automatic version-change dispatch, a published GitHub Release tagged `sdk-ios-vX.Y.Z`, or a manual dispatch of `publish-sdk-ios.yml` with `version` and the full source `sha` prepares the release. Dispatch from `main`; an explicit SHA must be on monorepo `main`.
3. The workflow preserves the mirror's `.github/`, pushes SDK contents to `release/vX.Y.Z`, and opens or reuses its PR to mirror `main`. Let required mirror CI pass and merge through the normal PR process; the publisher never pushes to `main` or bypasses rulesets.
4. Dispatch `publish-sdk-ios.yml` from monorepo `main` again with the same `version` and `finalize=true`. It refuses an unmerged PR, otherwise tags that PR's merge commit on mirror `main` as `vX.Y.Z`. Existing tags are never overwritten; finalizing the same commit twice is safe. Xcode can then install the version.

Preparation can be retried while its PR is open. A merged or closed PR cannot be prepared again; finalize a merged PR instead.

## Troubleshooting

- **403 opening a PR or pushing to mirror**: the PAT expired or lacks the permissions above.
- **Mirror out of sync**: re-run preparation with the intended source SHA while the PR is open; mirror-owned `.github/` files remain intact.
- **Finalize says the PR has not merged**: finish the mirror's required CI and normal PR merge before retrying finalization.
