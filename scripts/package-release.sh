#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

KITH_UNIVERSAL=1 scripts/build-app.sh

archive=Kith-macOS-universal.zip
image=Kith-macOS-universal.dmg
cd dist
rm -f "$archive" "$image" SHA256SUMS.txt
ditto -c -k --sequesterRsrc --keepParent Kith.app "$archive"
unzip -t "$archive" >/dev/null
python3 - "$PWD/Kith.app" "$PWD/$image" <<'PY'
import pathlib
import subprocess
import sys
import tempfile

app = pathlib.Path(sys.argv[1])
image = pathlib.Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix="kith-dmg-") as directory:
    root = pathlib.Path(directory)
    subprocess.run(["ditto", str(app), str(root / "Kith.app")], check=True)
    (root / "Applications").symlink_to("/Applications")
    subprocess.run(["hdiutil", "create", "-volname", "Kith", "-srcfolder", str(root),
                    "-format", "UDZO", "-ov", str(image)], check=True)
PY
hdiutil verify "$image"
shasum -a 256 "$image" "$archive" > SHA256SUMS.txt

echo "Packaged $repo_root/dist/$image and $archive"
