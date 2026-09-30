#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

KITH_UNIVERSAL=1 scripts/build-app.sh

archive=Kith-macOS-universal.zip
cd dist
rm -f "$archive" SHA256SUMS.txt
ditto -c -k --sequesterRsrc --keepParent Kith.app "$archive"
unzip -t "$archive" >/dev/null
shasum -a 256 "$archive" > SHA256SUMS.txt

echo "Packaged $repo_root/dist/$archive"
