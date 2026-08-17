#!/usr/bin/env bash
set -euo pipefail

# pulls the latest reviewed code on
# main (which already includes whatever sync-forks.yml has brought in from
# both upstream forks and been merged - see SYNCING.md), builds a fresh
# jailed package from that code, then hands off to build_ipa.sh to inject
# it into an IPA you point it at.
#
# Requires Theos ($THEOS set) and the iPhoneOS18.0 SDK already available -
# see README.md's "Building from source" section if that's not set up yet.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if [ -n "$(git status --short)" ]; then
    echo "Error: working tree has uncommitted changes - not touching it automatically."
    echo "Commit or stash your changes, then re-run this script."
    git status --short
    exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "Currently on branch '$CURRENT_BRANCH', not 'main'."
    read -p "Switch to main to pick up the latest merged fork updates? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git checkout main
    else
        echo "Staying on '$CURRENT_BRANCH' - building whatever's currently checked out."
    fi
fi

if [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]; then
    echo "=== Updating main ==="
    git fetch origin main
    if ! git merge-base --is-ancestor HEAD origin/main; then
        echo "Error: local main has commits that origin/main doesn't have."
        echo "Not fast-forwarding automatically - resolve by hand (rebase/merge), then re-run."
        exit 1
    fi
    git merge --ff-only origin/main
    echo "Now at $(git rev-parse --short HEAD)"
fi

echo
echo "=== Building fresh jailed package ==="
rm -rf ./packages
mkdir -p ./packages
make clean > /dev/null 2>&1 || true
make package FINALPACKAGE=1 JAILED=1

JAILED_DEB_FILE=$(find ./packages -name "*.deb" -type f | head -1)
if [ -z "$JAILED_DEB_FILE" ]; then
    echo "Error: build did not produce a .deb file."
    exit 1
fi
NEW_NAME="${JAILED_DEB_FILE%.deb}_jailed.deb"
mv "$JAILED_DEB_FILE" "$NEW_NAME"
echo "Built: $NEW_NAME"

echo
echo "=== Injecting into your IPA ==="
exec ./build_ipa.sh
