#!/bin/zsh
# Runs the unit tests and the core smoke checks. Command Line Tools ship Swift Testing
# outside the default search paths, so point the build at it when Xcode is not selected.
set -euo pipefail
repo_root="${0:A:h:h}"
cd "$repo_root"
flags=()
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libraries="$developer_dir/Library/Developer/usr/lib"
    flags=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks"
           -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libraries")
fi
swift test "${flags[@]}"
scripts/smoke-core.sh
