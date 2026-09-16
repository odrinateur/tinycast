# Release

How a build reaches a user. The local development loop is in [development.md](development.md);
the signing identity itself is in [signing.md](signing.md).

## Packaging a DMG locally

```sh
./Scripts/build-dmg.sh            # -> build/Tinycast-<version>.dmg (version from project.yml)
./Scripts/build-dmg.sh 0.5.7      # -> build/Tinycast-0.5.7.dmg
```

It builds a Release `Tinycast.app` signed with `Tinycast Self-Signed` and packs it with an
`/Applications` symlink. Official per-channel releases are built by CI, below.

## Signing & Gatekeeper

Local builds can use `Tinycast Self-Signed`. CI signs ad-hoc (`-`), same as the other private tap
apps — no certificate secret. The Homebrew cask strips quarantine; a direct DMG download still needs
`xattr -dr com.apple.quarantine "…/Tinycast.app"` once. Full details in [signing.md](signing.md).

## How the in-app updater consumes a release

Every release publishes two assets from one build: `Tinycast-<version>.dmg`, which people download by
hand and which the cask installs, and `Tinycast-<version>.zip`, which the in-app updater installs. The
zip is produced with `ditto -c -k --keepParent --sequesterRsrc` — the only zip that leaves the code
signature verifiable, which matters because the updater refuses any bundle whose signature does not
prove it is ours.

A stable release publishes two more from the `universal` job, `Tinycast-Universal-<version>.dmg` and
`.zip`, built from the same commit at the same version and bundle id but with both slices. They are
uploaded *after* the thin pair, which keeps the thin zip first in the asset list so builds predating
architecture-aware selection keep choosing it.

Three things a release must keep true, or the updater skips it:

- **It carries a `.zip` asset this Mac can run.** A DMG-only release is not installable and is not
  offered, and an Intel build is offered nothing rather than a thin arm64 zip.
- **The tag parses as `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-beta.N`,** and agrees with the
  `prerelease` flag. `v0.9.7-sequoia` deliberately parses as neither, which is what keeps beta
  installs off the macOS 15 build.
- **It is not a draft.**

**Both casks declare `auto_updates true`.** That is Homebrew's flag for an app that manages its own
version, and it is what keeps `brew update && brew upgrade` from fighting an app that updated itself:
brew never reports Tinycast outdated, never re-downloads it, and never rolls a self-updated copy back.
Removing that line would reintroduce exactly those three problems. See
[features/updates.md](features/updates.md).

## Continuous integration

`.github/workflows/ci.yml` runs on every PR, on a `macos-26` runner with Xcode 26 (the same selection
step as the release workflow). One job, a merge gate; a new push cancels the in-flight run for the
same ref. Two steps, both of which shell out to a script rather than naming rules or harnesses in the
workflow, so neither can drift:

- **the harnesses** — `./Scripts/run-tests.sh`.
- **lint** — `./Scripts/lint.sh`, with `SWIFTLINT_REPORTER=github-actions-logging` so every violation
  is annotated **inline on the PR diff** instead of being buried in the log. It runs under
  `if: always()`, so a failing harness still surfaces the lint annotations in the same run. Warnings
  annotate only; **lint errors fail the job**, exactly as a local run does.

It does **not** run on pushes to `main`. `pull_request` builds the merge result, so re-running after a
merge would re-test content CI has already seen. A direct push to `main` therefore gets no run at all —
use **Actions → CI → Run workflow** if one ever needs checking.

There is **no `xcodebuild` step**: a Debug build costs minutes on every run and the release workflow
builds before it ships anyway, so CI keeps to the checks that finish in about a minute. The
consequence is that a change compiling nowhere still turns the PR green — **build locally before you
open one**. See [testing.md](testing.md#definition-of-done).

## Releasing

Releases trigger automatically on push/merge to the default branch (`strip/personal`). The workflow
automatically computes the next patch version from the latest GitHub Release (e.g. `0.2.0` -> `0.2.1`).

Manual releases can also be triggered at **Actions → Release → Run workflow**, with an optional version override.
One macOS 26 job: ad-hoc arm64 build, DMG, GitHub Release, then `Scripts/publish-tap.sh` pushes `Casks/tinycast.rb`
to [`odrinateur/homebrew-tap`](https://github.com/odrinateur/homebrew-tap). Needs `TAP_GITHUB_TOKEN`
(contents:write on the tap). Installing needs `HOMEBREW_GITHUB_API_TOKEN` or `gh auth login`.

## Website

`.github/workflows/website.yml` builds `website/` (Next.js static export + Tailwind, with Fumadocs for
the docs section) and deploys it to GitHub Pages at `https://abue-ammar.github.io/tinycast/` on every
push to `main` that touches `website/`. Enable it once via
**Settings → Pages → Source = GitHub Actions**.

```sh
cd website && npm install && npm run dev     # local preview
```

The workflow uploads `website/out` — a Next.js export lands there, not in `dist/`. `public/.nojekyll`
must stay: GitHub Pages runs Jekyll, which ignores `_`-prefixed directories, so without it every
asset under `_next/` 404s. See [website/README.md](../website/README.md).
