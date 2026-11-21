#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT
app="$staging/ReforgerModDownloader"
mkdir -p "$app/lib"
install -m 755 linux/ReforgerModDownloader "$app/ReforgerModDownloader"
cp dashboard-core.ps1 download-web.ps1 make-preset.ps1 page.html preset-scenarios.ps1 \
   state.ps1 trim-config.ps1 update-mods.ps1 watchdog.ps1 workshop-api.ps1 version.txt LICENSE NOTICE "$app/lib/"
tar -czf dist/ReforgerModDownloader-linux-x64.tar.gz -C "$staging" ReforgerModDownloader
