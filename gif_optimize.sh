#!/usr/bin/env bash
set -euo pipefail

# Optimize GIFs for iPixel-ESPHome safe mode (<= 12 KB by default).
# Requires: ffmpeg
# Optional: gifsicle (for extra compression)
#
# Usage:
#   ./gif_optimize.sh <input_url_or_file> [output.gif] [target_bytes]
#
# Examples:
#   ./gif_optimize.sh "http://example.com/anim.gif"
#   ./gif_optimize.sh ./in.gif ./bin/optimized.gif 12000

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not found. Please install ffmpeg first." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <input_url_or_file> [output.gif] [target_bytes]" >&2
  exit 1
fi

INPUT="$1"
OUTPUT="${2:-./bin/optimized.gif}"
TARGET_BYTES="${3:-12000}"

WORKDIR="$(mktemp -d /tmp/ipixel_gif_opt.XXXXXX)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

INPUT_FILE="$WORKDIR/input.gif"

if [[ "$INPUT" =~ ^https?:// ]]; then
  echo "Downloading GIF from URL..."
  curl -L --fail --silent --show-error "$INPUT" -o "$INPUT_FILE"
else
  if [[ ! -f "$INPUT" ]]; then
    echo "Error: input file not found: $INPUT" >&2
    exit 1
  fi
  cp "$INPUT" "$INPUT_FILE"
fi

mkdir -p "$(dirname "$OUTPUT")"

has_gifsicle=0
if command -v gifsicle >/dev/null 2>&1; then
  has_gifsicle=1
fi

best_file=""
best_size=999999999

# Conservative search space tuned for small matrix displays.
widths=(32 28 24 20 16)
fps_values=(12 10 8 6 5)
colors=(64 48 32 24 16)

echo "Optimizing to target <= ${TARGET_BYTES} bytes..."

for w in "${widths[@]}"; do
  for fps in "${fps_values[@]}"; do
    for c in "${colors[@]}"; do
      cand="$WORKDIR/cand_w${w}_f${fps}_c${c}.gif"

      ffmpeg -v error -y -i "$INPUT_FILE" \
        -filter_complex "fps=${fps},scale=${w}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=${c}[p];[s1][p]paletteuse=dither=bayer" \
        "$cand"

      if [[ $has_gifsicle -eq 1 ]]; then
        opt="$cand.opt.gif"
        gifsicle -O3 --careful "$cand" -o "$opt" || cp "$cand" "$opt"
        cand="$opt"
      fi

      size="$(wc -c < "$cand" | tr -d ' ')"
      echo "  w=${w} fps=${fps} colors=${c} -> ${size} bytes"

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
done

if [[ -n "$best_file" ]]; then
  cp "$best_file" "$OUTPUT"
  echo "No candidate reached target ${TARGET_BYTES} bytes." >&2
  echo "Best effort written: $OUTPUT (${best_size} bytes)" >&2
  exit 2
fi

echo "Optimization failed: no output generated." >&2
exit 3
