#!/usr/bin/env bash
set -euo pipefail

# Clean up any leftover settings
if grep -q "THEOS_PACKAGE_SCHEME" Makefile; then
    sed -i '' '/THEOS_PACKAGE_SCHEME/d' Makefile 2>/dev/null || sed -i '/THEOS_PACKAGE_SCHEME/d' Makefile
    echo "Removed 'THEOS_PACKAGE_SCHEME' from Makefile"
fi

if grep -q "THEOS_DEVICE_IP" Makefile; then
    sed -i '' '/THEOS_DEVICE_IP/d' Makefile 2>/dev/null || sed -i '/THEOS_DEVICE_IP/d' Makefile
    echo "Removed 'THEOS_DEVICE_IP' from Makefile"
fi

rm -rf ./packages
mkdir -p ./packages

echo "=== Building jailed/sideload version ==="
make clean > /dev/null 2>&1 || true
make package FINALPACKAGE=1 JAILED=1

# Rename jailed deb
JAILED_DEB_FILE=$(find ./packages -name "*.deb" -type f | head -1)
if [ -n "$JAILED_DEB_FILE" ]; then
    NEW_NAME="${JAILED_DEB_FILE%.deb}_jailed.deb"
    mv "$JAILED_DEB_FILE" "$NEW_NAME"
    echo "Renamed: $JAILED_DEB_FILE -> $NEW_NAME"
else
    echo "Warning: No .deb file found for jailed build"
fi

echo "=== Building rootful package (arm64 + arm64e) ==="
make clean > /dev/null 2>&1 || true
make package FINALPACKAGE=1

echo "=== Building rootless package (arm64 only) ==="
make clean > /dev/null 2>&1 || true
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

echo "=== All packages ==="
ls -la ./packages/

if [ -f "./build_ipa.sh" ]; then
    read -p "Do you want to build an IPA? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ./build_ipa.sh
    fi
fi

echo "Finished building packages"
exit 0
