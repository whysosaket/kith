#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
cd "$repo_root"
mkdir -p .build
swiftc -o .build/kith-core-smoke Sources/KithCore/*.swift Tests/Smoke/main.swift \
    -lsqlite3 -framework AppKit -framework ApplicationServices
.build/kith-core-smoke
