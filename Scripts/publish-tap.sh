#!/usr/bin/env bash
# Render (and optionally push) the Homebrew cask for a private GitHub release.
# Private assets cannot use url + header: Authorization — Homebrew strips the token.
# The tap's GitHubPrivateReleaseDownloadStrategy is what brew install actually uses.
#
# Publish:
#   CASK=tinycast VERSION=0.1.0 DMG=dist/Tinycast-0.1.0.dmg TAP_GITHUB_TOKEN=… ./Scripts/publish-tap.sh
# Render only:
#   CASK=tinycast VERSION=0.1.0 SHA256=abc ./Scripts/publish-tap.sh --render
# Check:
#   ./Scripts/publish-tap.sh --self-check
set -euo pipefail

TAP_REPO="${HOMEBREW_TAP_REPO:-odrinateur/homebrew-tap}"
APP_REPO="${APP_REPO:-${GITHUB_REPOSITORY:-odrinateur/tinycast}}"

render_cask() {
  local cask="$1" version="$2" sha="$3" app_repo="$4"
  local name app_bundle quit_id login zap_id asset arch_line conflicts_line
  case "$cask" in
    tinycast)
      name="Tinycast"
      app_bundle="Tinycast.app"
      quit_id="com.tinycast.app"
      login="Tinycast"
      zap_id="com.tinycast.app"
      asset="Tinycast-#{version}.dmg"
      arch_line=$'  depends_on arch: :arm64\n'
      conflicts_line=$'  conflicts_with cask: "tinycast-universal"\n'
      ;;
    tinycast-universal)
      name="Tinycast"
      app_bundle="Tinycast.app"
      quit_id="com.tinycast.app"
      login="Tinycast"
      zap_id="com.tinycast.app"
      asset="Tinycast-Universal-#{version}.dmg"
      arch_line=""
      conflicts_line=$'  conflicts_with cask: "tinycast"\n'
      ;;
    tinycast@beta)
      name="Tinycast Beta"
      app_bundle="Tinycast Beta.app"
      quit_id="com.tinycast.app.beta"
      login="Tinycast Beta"
      zap_id="com.tinycast.app.beta"
      asset="Tinycast-#{version}.dmg"
      arch_line=$'  depends_on arch: :arm64\n'
      conflicts_line=""
      ;;
    *)
      echo "Unknown cask: $cask" >&2
      return 1
      ;;
  esac

  cat <<RUBY
require Tap.fetch("odrinateur/tap").path/"lib/github_private_release_download_strategy"

cask "${cask}" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/${app_repo}/releases/download/v#{version}/${asset}",
      using: GitHubPrivateReleaseDownloadStrategy
  name "${name}"
  desc "Tiny, fully native launcher, hotkeys, and clipboard history"
  homepage "https://github.com/${app_repo}"

  auto_updates true
${conflicts_line}  depends_on macos: :tahoe
${arch_line}
  app "${app_bundle}"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/${app_bundle}"],
        must_succeed: false
  end

  uninstall quit: "${quit_id}"

  zap login_item: "${login}",
      trash:      [
        "~/Library/Application Support/${zap_id}",
        "~/Library/Caches/${zap_id}",
        "~/Library/Preferences/${zap_id}.plist",
        "~/Library/Saved Application State/${zap_id}.savedState",
      ]
end
RUBY
}

assert_cask() {
  local file="$1"
  grep -q 'using: GitHubPrivateReleaseDownloadStrategy' "$file" || {
    echo "missing GitHubPrivateReleaseDownloadStrategy in $file" >&2
    return 1
  }
  grep -q '{{appdir}}' "$file" || {
    echo "missing {{appdir}} install-time token in $file" >&2
    return 1
  }
  # ponytail: these four strings are how Homebrew used to (and must not) auth private URLs.
  for banned in 'header:' 'verified:' 'postflight do' 'Homebrew::EnvConfig.github_api_token' '#{appdir}'; do
    if grep -F -q "$banned" "$file"; then
      echo "banned '$banned' in $file" >&2
      return 1
    fi
  done
}

self_check() {
  local tmp dir cask
  dir="$(mktemp -d)"
  # ponytail: dummy sha; this only asserts the rendered DSL, not a real asset.
  for cask in tinycast tinycast-universal tinycast@beta; do
    tmp="${dir}/${cask}.rb"
    render_cask "$cask" "0.0.0" "deadbeef" "odrinateur/tinycast" >"$tmp"
    assert_cask "$tmp"
  done
  rm -rf "$dir"
  echo "publish-tap self-check ok"
}

if [ "${1:-}" = "--self-check" ]; then
  self_check
  exit 0
fi

CASK="${CASK:?CASK is required}"
VERSION="${VERSION:?VERSION is required}"

if [ "${1:-}" = "--render" ]; then
  SHA256="${SHA256:?SHA256 is required for --render}"
  render_cask "$CASK" "$VERSION" "$SHA256" "$APP_REPO"
  exit 0
fi

DMG="${DMG:-${DMG_FILE:-}}"
if [ -z "$DMG" ]; then
  echo "DMG (or DMG_FILE) is required" >&2
  exit 1
fi
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

if [ -z "${TAP_GITHUB_TOKEN:-}" ]; then
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning::TAP_GITHUB_TOKEN secret not set — skipping cask bump. Add it (contents:write on ${TAP_REPO})."
  else
    echo "TAP_GITHUB_TOKEN is not set — skip Homebrew tap update."
    echo "Fine-grained PAT with contents:write on ${TAP_REPO}."
  fi
  exit 0
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

git clone --depth 1 \
  "https://x-access-token:${TAP_GITHUB_TOKEN}@github.com/${TAP_REPO}.git" \
  "${WORKDIR}/tap"

mkdir -p "${WORKDIR}/tap/Casks"
CASK_FILE="${WORKDIR}/tap/Casks/${CASK}.rb"
render_cask "$CASK" "$VERSION" "$SHA256" "$APP_REPO" >"$CASK_FILE"
assert_cask "$CASK_FILE"

cd "${WORKDIR}/tap"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "Casks/${CASK}.rb"
if git diff --cached --quiet; then
  echo "Tap already at ${CASK} ${VERSION}, nothing to commit."
  exit 0
fi
git commit -m "chore(tinycast): ${CASK} ${VERSION}"
git push origin HEAD
echo "Updated ${TAP_REPO} Casks/${CASK}.rb to ${VERSION}"
