#!/usr/bin/env bash
set -euo pipefail

# Use godot-builds repository which has ALL releases (dev, beta, rc, stable)
# Pass PAGE=N environment variable to fetch different pages (default: 1)
# Pass GITHUB_TOKEN=<token> to avoid rate limiting
PAGE="${PAGE:-1}"
LIMIT="${LIMIT:-5}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
API_URL="https://api.github.com/repos/godotengine/godot-builds/releases?per_page=${LIMIT}&page=${PAGE}"

mark_lazy() {
  # Remove any existing .lazy lines to avoid duplicates, then add after each .hash
  sed -i '/\.lazy = true,$/d' build.zig.zon
  sed -i 's/\.hash = "\([^"]*\)",$/\.hash = "\1",\n            .lazy = true,/' build.zig.zon
}

echo "Fetching Godot releases from GitHub (godot-builds)..."

if [[ -n "$GITHUB_TOKEN" ]]; then
  releases=$(curl -s -H "Accept: application/vnd.github.v3+json" -H "Authorization: Bearer $GITHUB_TOKEN" "$API_URL")
else
  releases=$(curl -s -H "Accept: application/vnd.github.v3+json" "$API_URL")
fi

# Check for API errors (rate limiting, etc.)
if echo "$releases" | jq -e '.message' >/dev/null 2>&1; then
  echo "Error from GitHub API: $(echo "$releases" | jq -r '.message')" >&2
  echo "Try setting GITHUB_TOKEN environment variable to avoid rate limiting." >&2
  exit 1
fi

# Get existing dependencies from build.zig.zon
existing=$(grep -oE '\.godot_[a-z0-9_]+' build.zig.zon 2>/dev/null | sed 's/^\.//' | sort -u || echo "")

echo "Processing releases..."

echo "$releases" | jq -r '
  .[] |
  .tag_name as $tag |
  # Parse version and prerelease from tag (e.g., "4.6-beta2" -> version="4.6", prerelease="beta2")
  # Format: major.minor[.patch]-prerelease
  ($tag | capture("^(?<ver>[0-9]+\\.[0-9]+(\\.[0-9]+)?)-(?<pre>.+)$")) as $parsed |
  select($parsed != null) |
  $parsed.ver as $ver |
  $parsed.pre as $pre |
  ($ver | split(".")[0] | tonumber) as $major |
  ($ver | split(".")[1] | tonumber) as $minor |
  .assets[] |
  select(.name | test("^Godot_v.*\\.(zip)$")) |
  select(.name | test("mono|export_templates|debug_symbols|web_editor|android|godot-lib|SHA512") | not) |
  {
    name: .name,
    url: .browser_download_url,
    version: $ver,
    prerelease: $pre,
  } |
  # Normalize version to always have 3 components (4.5 -> 4.5.0)
  .version as $v |
  .normalized_version = (if ($v | split(".") | length) == 2 then $v + ".0" else $v end) |
  # Parse platform and arch from filename
  if .name | test("_linux\\.x86_64\\.zip$") then . + {platform: "linux", arch: "x86_64"}
  elif .name | test("_linux\\.x86_32\\.zip$") then . + {platform: "linux", arch: "x86"}
  elif .name | test("_linux\\.arm64\\.zip$") then . + {platform: "linux", arch: "aarch64"}
  elif .name | test("_linux\\.arm32\\.zip$") then . + {platform: "linux", arch: "arm"}
  elif .name | test("_macos\\.universal\\.zip$") then . + {platform: "macos", arch: "universal"}
  elif .name | test("_win64\\.exe\\.zip$") then . + {platform: "windows", arch: "x86_64"}
  elif .name | test("_win32\\.exe\\.zip$") then . + {platform: "windows", arch: "x86"}
  elif .name | test("_windows_arm64\\.exe\\.zip$") then . + {platform: "windows", arch: "aarch64"}
  # Godot 3.x patterns
  elif .name | test("_x11\\.64\\.zip$") then . + {platform: "linux", arch: "x86_64"}
  elif .name | test("_x11\\.32\\.zip$") then . + {platform: "linux", arch: "x86"}
  elif .name | test("_osx\\.universal\\.zip$") then . + {platform: "macos", arch: "universal"}
  else empty
  end |
  # Create dependency name: godot_4_6_0_beta2_linux_x86_64
  .dep_name = "godot_" + (.normalized_version | gsub("\\."; "_")) + "_" + .prerelease + "_" + .platform + "_" + .arch |
  "\(.dep_name) \(.url)"
' | while read -r dep_name url; do
  if grep -qx "$dep_name" <<< "$existing"; then
    echo "  Skipping $dep_name (already exists)"
  else
    echo "  Adding $dep_name..."
    if zig fetch --save="$dep_name" "$url" < /dev/null; then
      mark_lazy
    else
      echo "    Failed: $dep_name"
    fi
  fi
done

echo "Done!"
