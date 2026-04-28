#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if ! command -v zip >/dev/null 2>&1; then
  echo "Error: zip is not installed or not in PATH" >&2
  exit 1
fi

"$script_dir/build.sh"

package_root="$repo_root/build/package/$DIST_NAME"
zip_path="$repo_root/distr/$DIST_NAME.zip"

mkdir -p "$repo_root/distr" "$repo_root/build/package"
rm -rf "$package_root"
mkdir -p "$package_root"

copy_optional_file() {
  local rel_path="$1"
  local dest_name="${2:-}"
  local src="$repo_root/$rel_path"

  if [ ! -f "$src" ]; then
    echo "Warning: $rel_path not found, skipping" >&2
    return
  fi

  if [ -n "$dest_name" ]; then
    cp "$src" "$package_root/$dest_name"
  else
    mkdir -p "$package_root/$(dirname "$rel_path")"
    cp "$src" "$package_root/$rel_path"
  fi
}

for app in "${BUILD_APPS[@]}"; do
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  exe="$repo_root/build/$upper.EXE"
  if [ -f "$exe" ]; then
    cp "$exe" "$package_root/$upper.EXE"
  else
    echo "Warning: build/$upper.EXE not found, skipping" >&2
  fi
done

for rel_path in "${DIST_DOC_FILES[@]}"; do
  copy_optional_file "$rel_path"
done

for rel_path in "${DIST_CONFIG_FILES[@]}"; do
  case "$rel_path" in
    config/NET.CFG.sample) copy_optional_file "$rel_path" "NET.CFG.sample" ;;
    *) copy_optional_file "$rel_path" ;;
  esac
done

for rel_path in "${DIST_EXTRA_FILES[@]}"; do
  copy_optional_file "$rel_path"
done

rm -f "$zip_path"
cd "$repo_root/build/package"
zip -qr "$zip_path" "$DIST_NAME"

echo "Created $zip_path"

