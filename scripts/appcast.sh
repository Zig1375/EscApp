#!/bin/sh
# Prints appcast.xml for a release zip: the one update Sparkle (AppUpdater) offers, signed with the EdDSA key, with
# the release's notes (release-notes/v<version>.md, rendered to HTML) shown in Sparkle's update window.
#   SPARKLE_PRIVATE_KEY=… scripts/appcast.sh MagicKettle-1.0.7.zip 1.0.7 7 notes.html > appcast.xml
# The release job attaches it to the release, and SUFeedURL (project.yml) reads it from the newest one. The key is
# the private half of SUPublicEDKey; it lives in the MagicKettle account of the maintainer's keychain
# (Sparkle's generate_keys --account MagicKettle) and in the repository secret SPARKLE_PRIVATE_KEY.
set -eu

zip=$1 version=$2 build=$3 notes=$4
[ -n "${SPARKLE_PRIVATE_KEY:-}" ] || { echo "SPARKLE_PRIVATE_KEY is not set" >&2; exit 1; }

# Sparkle's own tools, the same version as the app's package, checked before they run.
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
tools=$(mktemp -d)
trap 'rm -rf "$tools"' EXIT
curl -fsSL -o "$tools/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
echo "$sparkle_sha256  $tools/sparkle.tar.xz" | shasum -a 256 -c - >&2
tar -xf "$tools/sparkle.tar.xz" -C "$tools" ./bin/sign_update

signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/bin/sign_update" --ed-key-file - -p "$zip")
length=$(stat -f %z "$zip")
url="https://github.com/Zig1375/MagicKettle/releases/download/v$version/$(basename "$zip")"
release="https://github.com/Zig1375/MagicKettle/releases/tag/v$version"
grep -q ']]>' "$notes" && { echo "$notes can't hold ]]> inside CDATA" >&2; exit 1; }

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Magic Kettle</title>
    <item>
      <title>Magic Kettle $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$release</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$(cat "$notes")
]]></description>
      <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
EOF
