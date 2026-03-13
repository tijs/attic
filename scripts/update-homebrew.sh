#!/bin/bash
# Update the Homebrew formula after a new release.
# Usage: ./scripts/update-homebrew.sh 0.1.0

set -euo pipefail

# Strip leading 'v' if present — version field in formula should be bare (e.g. "0.1.4")
VERSION="${1:?Usage: $0 <version>}"
VERSION="${VERSION#v}"
REPO="tijs/attic"
TAP_REPO="tijs/homebrew-tap"
FORMULA="Formula/attic.rb"

echo "Fetching checksums for v${VERSION}..."

ARM_URL="https://github.com/${REPO}/releases/download/v${VERSION}/attic-${VERSION}-aarch64-apple-darwin.tar.gz"
X86_URL="https://github.com/${REPO}/releases/download/v${VERSION}/attic-${VERSION}-x86_64-apple-darwin.tar.gz"

ARM_SHA=$(curl -sL "$ARM_URL" | shasum -a 256 | cut -d' ' -f1)
X86_SHA=$(curl -sL "$X86_URL" | shasum -a 256 | cut -d' ' -f1)

echo "ARM64 SHA256: ${ARM_SHA}"
echo "x86_64 SHA256: ${X86_SHA}"

TMPDIR=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TMPDIR"

cd "$TMPDIR"

# Update version
sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "$FORMULA"

# Update ARM64 sha256 (first PLACEHOLDER or sha256 after arm? block)
# Use awk for precise replacement
awk -v arm="$ARM_SHA" -v x86="$X86_SHA" '
  /Hardware::CPU.arm\?/ { in_arm=1 }
  /else/ { in_arm=0; in_x86=1 }
  /sha256/ && in_arm { sub(/sha256 ".*"/, "sha256 \"" arm "\""); in_arm=0 }
  /sha256/ && in_x86 { sub(/sha256 ".*"/, "sha256 \"" x86 "\""); in_x86=0 }
  { print }
' "$FORMULA" > "$FORMULA.tmp" && mv "$FORMULA.tmp" "$FORMULA"

echo ""
echo "Updated formula:"
cat "$FORMULA"
echo ""

git add "$FORMULA"
git commit -m "attic ${VERSION}"
git push origin main

rm -rf "$TMPDIR"

echo "Done. Homebrew formula updated to v${VERSION}."
