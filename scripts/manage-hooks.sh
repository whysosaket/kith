#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
mkdir -p "$repo_root/.build"
swiftc -o "$repo_root/.build/kith-manage-hooks" "$repo_root"/Sources/KithCore/*.swift \
    "$repo_root/scripts/hook-manager/main.swift" -lsqlite3 \
    -framework AppKit -framework ApplicationServices
"$repo_root/.build/kith-manage-hooks" "$@"
