# Releasing `GravitySDK` (Swift Package)

Swift Package Manager has no central registry — Xcode installs packages directly from a git repo. Since this monorepo is private, releases are published by mirroring `sdk-ios/` into the **public** [`Try-Gravity/gravity-swift-sdk`](https://github.com/Try-Gravity/gravity-swift-sdk) repo via the [`publish-sdk-ios.yml`](../.github/workflows/publish-sdk-ios.yml) workflow. Only the SDK source is public; the monorepo stays private. (This mirror pattern is standard — Stripe, Firebase, etc. do the same.)

Developers install with: Xcode → File → Add Package Dependencies → `https://github.com/Try-Gravity/gravity-swift-sdk`.

## One-time setup (repo maintainers)

1. **Create the public mirror repo** `Try-Gravity/gravity-swift-sdk` (empty, public, with a `main` branch).
2. **Fine-grained PAT.** Create a fine-grained personal access token scoped to only `Try-Gravity/gravity-swift-sdk` with **Contents: Read and write** permission.
3. **GitHub Environment.** Create a `swift-sdk-mirror` environment under Settings → Environments in this repo with the secret:
   - `SWIFT_SDK_MIRROR_TOKEN` — the PAT from step 2.

## Normal release (release-triggered)

1. Make sure `sdk-ios/` on `main` is in the state you want to ship.
2. Create a GitHub Release with tag `sdk-ios-vX.Y.Z` targeting `main`.
3. The workflow copies `sdk-ios/` into the mirror repo, commits, and pushes tag `vX.Y.Z` there. Xcode picks up the new version immediately.

Can also be run manually via workflow_dispatch with a `version` input.

## Troubleshooting

- **403 pushing to mirror**: the PAT expired or lacks Contents write on the mirror repo.
- **Mirror out of sync**: re-run the workflow via workflow_dispatch — it fully replaces the mirror contents with the current `sdk-ios/`.
