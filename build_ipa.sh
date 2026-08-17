echo "Please enter the path to your decrypted BeReal IPA file:"
read -r IPA_PATH

# Remove single quotes if present
IPA_PATH=$(echo "$IPA_PATH" | sed "s/^'//;s/'$//")

if [ ! -f "$IPA_PATH" ]; then
    echo "Error: The file '$IPA_PATH' does not exist."
    exit 1
fi

echo "Using IPA: $IPA_PATH"

JAILED_DEB=$(find "$(pwd)/packages" -name "*_jailed.deb" -type f)

if [ -z "$JAILED_DEB" ]; then
    echo "Error: Could not find jailed deb file, please run ./build_release.sh first."
    echo "Contents of packages directory:"
    ls -la ./packages/
    exit 1
fi

echo "Found jailed deb: $JAILED_DEB"

# this is needed because else azule will fail
ABS_IPA_PATH=$(realpath "$IPA_PATH")
ABS_JAILED_DEB=$(realpath "$JAILED_DEB")

IPA_FILENAME=$(basename "$IPA_PATH")
# tr strips a trailing \r in case control has CRLF line endings (e.g. checked
# out on Windows) - otherwise it silently ends up embedded in OUTPUT_NAME.
TWEAK_VERSION=$(grep -E '^Version:' "$(pwd)/control" | sed 's/Version: *//' | tr -d '\r\n')
OUTPUT_NAME="${IPA_FILENAME%.*}+com.yan.minibea_${TWEAK_VERSION}"
OUTPUT_IPA="$(pwd)/${OUTPUT_NAME}.ipa"

echo "Injecting tweak into IPA..."

azule -i "$ABS_IPA_PATH" -f "$ABS_JAILED_DEB" -o "./" -n "$OUTPUT_NAME"

# The CydiaSubstrate.framework azule bundles ships armv6/armv7 slices from
# 2021 alongside arm64/arm64e. Several on-device signers (e.g. Feather) fail
# to codesign that legacy 4-slice binary. Thin it to just arm64/arm64e -
# matching the tweak's own dylib and the app's own architecture - so signing
# doesn't choke on dead 32-bit code nothing on iOS 11+ can run anyway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$OUTPUT_IPA" ] && command -v python3 >/dev/null 2>&1; then
    echo "Thinning CydiaSubstrate.framework (dropping armv6/armv7)..."
    THIN_DIR=$(mktemp -d)
    (
        cd "$THIN_DIR"
        unzip -qq "$OUTPUT_IPA"
        SUBSTRATE_BIN="Payload/BeReal.app/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
        if [ -f "$SUBSTRATE_BIN" ]; then
            python3 "$SCRIPT_DIR/thin_macho.py" "$SUBSTRATE_BIN" "$SUBSTRATE_BIN.thinned"
            mv "$SUBSTRATE_BIN.thinned" "$SUBSTRATE_BIN"
            chmod 755 "$SUBSTRATE_BIN"
            rm -f "$OUTPUT_IPA"
            zip -qry "$OUTPUT_IPA" Payload
        else
            echo "No CydiaSubstrate binary found at expected path, skipping thinning."
        fi
    )
    rm -rf "$THIN_DIR"
else
    echo "python3 not found, skipping CydiaSubstrate thinning - the IPA may fail to codesign on-device."
fi

echo "Done! Patched IPA is in: $OUTPUT_IPA"