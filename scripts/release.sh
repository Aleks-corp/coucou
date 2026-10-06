#!/usr/bin/env bash
# Builds (ad-hoc signed, no notarization) and publishes Coucou for macOS (GitHub build).
#
#   ./scripts/release.sh 0.1.2            build, sign ad-hoc, tag, publish
#   ./scripts/release.sh 0.1.2 --finish   publish a build already made
#
# Run it from a clean checkout of main. CFBundleShortVersionString in
# NotchBuddy/project.yml must match the version, and CHANGELOG.md needs a
# "## <version>" section: it becomes the release notes.
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [--finish]}"
MODE="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/coucou-release-$VERSION"
APP="$BUILD_DIR/Coucou.app"
ZIP="$BUILD_DIR/Coucou.zip"
COMMIT_FILE="$BUILD_DIR/commit"
TAG="v$VERSION"

die() { echo "error: $*" >&2; exit 1; }

case "$MODE" in
  ""|--finish) ;;
  *) die "unknown option '$MODE' (the only option is --finish)" ;;
esac

cd "$REPO_ROOT"

# ── Checks shared by both modes ───────────────────────────────────────────────
command -v gh >/dev/null || die "gh is not installed (brew install gh)"

# The "## <version>" section of CHANGELOG.md, without leading or trailing blank lines.
CHANGES=$(awk -v head="## $VERSION" '
  index($0, head " ") == 1 || $0 == head { found = 1; next }
  found && /^## / { exit }
  found {
    if ($0 ~ /^[ \t\r]*$/) { if (started) blanks++; next }
    while (blanks > 0) { print ""; blanks-- }
    print; started = 1
  }
' CHANGELOG.md)
[ -n "$CHANGES" ] || die "CHANGELOG.md has no '## $VERSION' section"

grep -q "| \[$VERSION\]" README.md || die "README.md has no row for $VERSION in the Versions table"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "tag $TAG already exists here"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists on GitHub"
fi

if [ "$MODE" != "--finish" ]; then
  # The release must match a commit: no uncommitted changes to tracked files.
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "commit or stash your changes first, the release has to match a commit"
  fi
  COMMIT=$(git rev-parse HEAD)

  # ── 2. xcodegen + Release build ─────────────────────────────────────────────
  cd "$REPO_ROOT/NotchBuddy"
  PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || true)
  [ "$PLIST_VERSION" = "$VERSION" ] || die "NotchBuddy/Resources/Info.plist is version $PLIST_VERSION, not $VERSION: run xcodegen and commit Info.plist"
  xcodegen generate
  PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  [ "$PLIST_VERSION" = "$VERSION" ] || die "project.yml says $PLIST_VERSION, not $VERSION: update CFBundleShortVersionString in NotchBuddy/project.yml"

  rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
  echo "$COMMIT" > "$COMMIT_FILE"

  xcodebuild \
    -project NotchBuddy.xcodeproj \
    -scheme NotchBuddy \
    -configuration Release \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR"

  codesign --verify --deep --strict "$APP" || die "the app's ad-hoc signature is not valid"

  # ── 3. Zip ──────────────────────────────────────────────────────────────────
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Release zip ready: $ZIP"
  cd "$REPO_ROOT"
else
  [ -d "$APP" ] && [ -f "$COMMIT_FILE" ] || die "nothing to finish in $BUILD_DIR, run ./scripts/release.sh $VERSION first"
  COMMIT=$(cat "$COMMIT_FILE")
fi

# ── 6. Tag the built commit + GitHub release ──────────────────────────────────
NOTES="Coucou $VERSION for macOS 15 or later (Apple silicon and Intel).

Ad-hoc signed, not notarized (fork build, no iCloud / iPhone sync).

## What's new

$CHANGES

## Install

1. Download Coucou.zip below and unzip it.
2. Move Coucou.app to your Applications folder, replacing the old one if you have it.
3. First launch: right-click Coucou.app → Open → Open (or run: xattr -dr com.apple.quarantine /Applications/Coucou.app).

Linux and Windows: see the [README](https://github.com/Aleks-corp/coucou#readme)."

echo
echo "──────── Release notes ────────"
echo "$NOTES"
echo "───────────────────────────────"
echo
read -r -p "Tag $(git rev-parse --short "$COMMIT") as $TAG and publish this release? [y/N] " ANSWER
case "$ANSWER" in
  y|Y|yes|oui|o|O) ;;
  *) die "stopped before tagging. Run ./scripts/release.sh $VERSION --finish to publish later." ;;
esac

git tag "$TAG" "$COMMIT"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" \
  --repo Aleks-corp/coucou \
  --title "Coucou $VERSION" \
  --latest \
  --notes "$NOTES"

echo "✓ $TAG released: https://github.com/Aleks-corp/coucou/releases/tag/$TAG"
