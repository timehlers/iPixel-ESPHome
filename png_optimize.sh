#!/usr/bin/env bash
set -euo pipefail

# Optimize PNGs for iPixel-ESPHome safe mode (<= 12 KB by default).
# Requires: ffmpeg
# Optional: oxipng
#
# Usage:
#   ./png_optimize.sh <input_url_or_file> [output.png] [target_bytes]
#
# Examples:
#   ./png_optimize.sh "http://example.com/image.png"
#   ./png_optimize.sh ./in.png ./bin/optimized.png 12000

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not found. Please install ffmpeg first." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <input_url_or_file> [output.png] [target_bytes]" >&2
  exit 1
fi

INPUT="$1"
OUTPUT="${2:-./bin/optimized.png}"
TARGET_BYTES="${3:-12000}"

WORKDIR="$(mktemp -d /tmp/ipixel_png_opt.XXXXXX)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

INPUT_FILE="$WORKDIR/input.png"

if [[ "$INPUT" =~ ^https?:// ]]; then
  echo "Downloading PNG from URL..."
  curl -L --fail --silent --show-error "$INPUT" -o "$INPUT_FILE"
else
  if [[ ! -f "$INPUT" ]]; then
    echo "Error: input file not found: $INPUT" >&2
    exit 1
  fi
  cp "$INPUT" "$INPUT_FILE"
fi

mkdir -p "$(dirname "$OUTPUT")"

has_oxipng=0
if command -v oxipng >/dev/null 2>&1; then
  has_oxipng=1
fi

best_file=""
best_size=999999999

# iPixel PNG rendering is most reliable with exact 32x32 RGB PNG.
widths=(32)
comp_levels=(9 7 5)

echo "Optimizing to target <= ${TARGET_BYTES} bytes..."

for w in "${widths[@]}"; do
  for cl in "${comp_levels[@]}"; do
    cand="$WORKDIR/cand_w${w}_cl${cl}.png"

    ffmpeg -v error -y -i "$INPUT_FILE" \
      -vf "scale=${w}:${w}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${w}:${w}:(ow-iw)/2:(oh-ih)/2:black,format=rgb24" \
      -frames:v 1 -compression_level "$cl" -pix_fmt rgb24 "$cand"

    if [[ $has_oxipng -eq 1 ]]; then
      oxipng -q -o 3 "$cand" || true
    fi

    size="$(wc -c < "$cand" | tr -d ' ')"
    echo "  w=${w} comp=${cl} rgb24 -> ${size} bytes"

    if (( size < best_size )); then
      best_size="$size"
      best_file="$cand"
    fi

    if (( size <= TARGET_BYTES )); then
      cp "$cand" "$OUTPUT"
      echo "Success: wrote $OUTPUT (${size} bytes)"
      exit 0
    fi
  done
done

if [[ -n "$best_file" ]]; then
  cp "$best_file" "$OUTPUT"
  echo "No candidate reached target ${TARGET_BYTES} bytes." >&2
  echo "Best effort written: $OUTPUT (${best_size} bytes)" >&2
  exit 2
fi

echo "Optimization failed: no output generated." >&2
exit 3
