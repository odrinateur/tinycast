#!/usr/bin/env bash
# Push Casks/tinycast.rb to odrinateur/homebrew-tap for a private GitHub release asset.
set -euo pipefail

TAP_REPO="${HOMEBREW_TAP_REPO:-odrinateur/homebrew-tap}"
APP_REPO="${APP_REPO:-${GITHUB_REPOSITORY:-odrinateur/tinycast}}"
CASK="${CASK:-tinycast}"

render_cask() {
  local version="$1" sha="$2" app_repo="$3"
  cat <<RUBY
require Tap.fetch("odrinateur/tap").path/"lib/github_private_release_download_strategy"

cask "tinycast" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/${app_repo}/releases/download/v#{version}/Tinycast-#{version}.dmg",
      using: GitHubPrivateReleaseDownloadStrategy
  name "Tinycast"
  desc "Tiny, fully native launcher, hotkeys, and clipboard history"
  homepage "https://github.com/${app_repo}"

  auto_updates true
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Tinycast.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/Tinycast.app"],
        must_succeed: false
  end

  uninstall quit: "com.tinycast.app"

  zap login_item: "Tinycast",
      trash:      [
        "~/Library/Application Support/com.tinycast.app",
        "~/Library/Caches/com.tinycast.app",
        "~/Library/Preferences/com.tinycast.app.plist",
        "~/Library/Saved Application State/com.tinycast.app.savedState",
      ]
end
RUBY
}

assert_cask() {
  local file="$1"
  grep -q 'using: GitHubPrivateReleaseDownloadStrategy' "$file"
  grep -q '{{appdir}}' "$file"
  for banned in 'header:' 'verified:' 'postflight do' 'Homebrew::EnvConfig.github_api_token' '#{appdir}'; do
    ! grep -F -q "$banned" "$file" || { echo "banned '$banned' in $file" >&2; return 1; }
  done
}

if [ "${1:-}" = "--self-check" ]; then
  tmp="$(mktemp)"
  render_cask "0.0.0" "deadbeef" "odrinateur/tinycast" >"$tmp"
  assert_cask "$tmp"
  rm -f "$tmp"
  echo "publish-tap self-check ok"
  exit 0
fi

if [ "${1:-}" = "--render" ]; then
  VERSION="${VERSION:?VERSION is required}"
  SHA256="${SHA256:?SHA256 is required for --render}"
  render_cask "$VERSION" "$SHA256" "$APP_REPO"
  exit 0
fi

DMG="${DMG:-${DMG_FILE:-}}"
[ -n "$DMG" ] || { echo "DMG is required" >&2; exit 1; }
VERSION="${VERSION:?VERSION is required}"
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

if [ -z "${TAP_GITHUB_TOKEN:-}" ]; then
  echo "::warning::TAP_GITHUB_TOKEN secret not set — skipping cask bump."
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
git clone --depth 1 \
  "https://x-access-token:${TAP_GITHUB_TOKEN}@github.com/${TAP_REPO}.git" \
  "${WORKDIR}/tap"

mkdir -p "${WORKDIR}/tap/Casks"
CASK_FILE="${WORKDIR}/tap/Casks/${CASK}.rb"
render_cask "$VERSION" "$SHA256" "$APP_REPO" >"$CASK_FILE"
assert_cask "$CASK_FILE"

cd "${WORKDIR}/tap"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "Casks/${CASK}.rb"
if git diff --cached --quiet; then
  echo "Tap already at ${CASK} ${VERSION}."
  exit 0
fi
git commit -m "chore(tinycast): ${VERSION}"
git push origin HEAD
echo "Updated ${TAP_REPO} Casks/${CASK}.rb to ${VERSION}"
