#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/swift build --package-path Packages/NetUnstickKit --configuration release --product NetUnstickUpdateFeed >&2
tool_dir="$(/usr/bin/swift build --package-path Packages/NetUnstickKit --configuration release --show-bin-path)"
tool="$tool_dir/NetUnstickUpdateFeed"
# A stable designated requirement preserves access to the tool's own Keychain item
# after recompilation. Never grant arbitrary unsigned executables access to this key.
/usr/bin/codesign --force --sign "${NETUNSTICK_SIGN_IDENTITY:-D6CDD9E6748C6D2AE7D9FAF9D48D5CCAC992630E}" \
    --identifier org.netunstick.UpdateFeedTool --options runtime --timestamp "$tool"
exec "$tool" "$@"
