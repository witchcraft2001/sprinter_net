#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

if ! command -v mformat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
  echo "Error: mtools is required (mformat and mcopy were not found)." >&2
  exit 1
fi

"$script_dir/build.sh"

image_path="${1:-$repo_root/distr/$DIST_NAME.img}"

mkdir -p "$(dirname "$image_path")"
rm -f "$image_path"

mformat -C -i "$image_path" -f 1440 ::

copy_to_image_root() {
  local src="$1"
  local dest="$2"

  if [ ! -f "$src" ]; then
    echo "Warning: $src not found, skipping" >&2
    return
  fi

  mcopy -i "$image_path" -o "$src" "::$dest"
}

for app in "${BUILD_APPS[@]}"; do
  upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
  copy_to_image_root "$repo_root/build/$upper.EXE" "$upper.EXE"
done

for rel_path in "${DIST_DOC_FILES[@]}"; do
  src="$repo_root/$rel_path"
  base="$(basename "$rel_path")"
  upper_base="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"

  case "$upper_base" in
    README.MD) image_name="README.TXT" ;;
    SPECS.MD) image_name="SPECS.TXT" ;;
    *.MD) image_name="${upper_base%.MD}.TXT" ;;
    *) image_name="$upper_base" ;;
  esac

  copy_to_image_root "$src" "$image_name"
done

for rel_path in "${DIST_CONFIG_FILES[@]}"; do
  src="$repo_root/$rel_path"
  base="$(basename "$rel_path")"
  upper_base="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"

  case "$upper_base" in
    NET.CFG.SAMPLE) image_name="NETCFG.TXT" ;;
    *) image_name="$upper_base" ;;
  esac

  copy_to_image_root "$src" "$image_name"
done

for rel_path in "${DIST_EXTRA_FILES[@]}"; do
  src="$repo_root/$rel_path"
  base="$(basename "$rel_path")"
  image_name="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"
  copy_to_image_root "$src" "$image_name"
done

echo "Created FAT12 image: $image_path"

