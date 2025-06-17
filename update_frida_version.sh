#!/bin/sh
# Updates the Frida version in Makefile to the latest release

# Exit immediately if a command exits with a non-zero status.
set -e

[ -n "$1" ] && {
    echo "This script updates the Frida version in Makefile to the latest release. It takes no arguments." >&2
    exit 1
}

[ ! -f "Makefile" ] && {
    echo "Error: Makefile not found" >&2
    exit 1
}

# Get current version from Makefile
OLD_RAW_LINE=$(grep -E '^FRIDA_VERSION[[:space:]]*:?=' Makefile | head -n 1)
[ -z "$OLD_RAW_LINE" ] && {
    echo "Error: Could not find FRIDA_VERSION line in Makefile" >&2
    exit 1
}

OLD=$(echo "$OLD_RAW_LINE" | sed 's/.*:*=[[:space:]]*//' | tr -d '[:space:]')
[ -z "$OLD" ] && {
    echo "Error: Could not parse FRIDA_VERSION from Makefile line: $OLD_RAW_LINE" >&2
    exit 1
}

echo "Current version: $OLD"

# Get latest version from GitHub API
NEW=$(curl -s "https://api.github.com/repos/frida/frida/releases/latest" |
          grep '"tag_name":' |
          sed -E 's/.*"([^"]+)".*/\1/')

[ -z "$NEW" ] && {
    echo "Error: Failed to get latest version tag from GitHub API." >&2
    exit 1
}

# Validate the new version format
if ! echo "$NEW" | grep -qE '^[0-9]+[.][0-9]+([.][0-9]+)?([.][0-9]+)?$'; then
    echo "Error: Fetched version '$NEW' is not a valid version number." >&2
    exit 1
fi

echo "Latest version: $NEW"

# Write version information to files for GitHub workflow
echo "$OLD" > .frida_old_version
echo "$NEW" > .frida_new_version

if [ "$OLD" = "$NEW" ]; then
    echo "Already up to date (version $OLD)."
    echo "false" > .frida_version_changed
    exit 0
fi

echo "true" > .frida_version_changed

OLD_ESCAPED=$(echo "$OLD" | sed 's/[.]/\\./g')

# Create backup
cp Makefile Makefile.bak
echo "Makefile backed up to Makefile.bak"

# Update version in Makefile
PATTERN_TO_REPLACE="s/FRIDA_VERSION := $OLD_ESCAPED/FRIDA_VERSION := $NEW/"

if sed --version 2>/dev/null | grep -q "GNU"; then
    if ! sed -i "$PATTERN_TO_REPLACE" Makefile; then
        echo "GNU sed command failed." >&2
        mv Makefile.bak Makefile
        echo "Restored Makefile from backup." >&2
        exit 1
    fi
else
    if ! sed -i '' "$PATTERN_TO_REPLACE" Makefile; then
        echo "BSD sed command failed." >&2
        mv Makefile.bak Makefile
        echo "Restored Makefile from backup." >&2
        exit 1
    fi
fi

# Verify update
if grep -q "FRIDA_VERSION := $NEW" Makefile; then
    echo "Successfully updated Makefile from $OLD to $NEW"
    rm Makefile.bak
    echo "Removed backup Makefile.bak"
else
    echo "Update verification failed. Makefile content after attempted sed:" >&2
    grep "^FRIDA_VERSION" Makefile || echo "FRIDA_VERSION line not found after sed." >&2
    echo "Restoring backup..." >&2
    mv Makefile.bak Makefile
    exit 1
fi

exit 0