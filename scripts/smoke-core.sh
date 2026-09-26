#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
cd "$repo_root"
swiftc -o /tmp/kith-core-smoke Sources/KithCore/*.swift Tests/Smoke/main.swift \
    -lsqlite3 -framework AppKit -framework ApplicationServices
/tmp/kith-core-smoke
