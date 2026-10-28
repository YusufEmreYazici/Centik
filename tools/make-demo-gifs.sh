#!/bin/bash
# Records the README demo GIFs from the real app (debug build, sample data only) into
# docs/assets/. Needs ffmpeg. Scenes play slowed down, so a full run takes ~15 minutes.
#
#   tools/make-demo-gifs.sh            # every scene
#   tools/make-demo-gifs.sh hero hud   # just these
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG=${FFMPEG:-ffmpeg}
"$FFMPEG" -version >/dev/null 2>&1 || { echo "A working ffmpeg is required (brew install ffmpeg, or set FFMPEG)" >&2; exit 1; }
swift build
FRAMES=$(mktemp -d)
.build/debug/Centik --demo "$FRAMES" "$@"

mkdir -p docs/assets
# Crop per scene, in 2x stage pixels (the stage is 1100x400 points): width:height:x:y.
crop() {
    case "$1" in
        hud)        echo "1300:140:450:0" ;;
        alerts)     echo "1300:220:450:0" ;;
        *)          echo "1760:600:220:0" ;;
    esac
}
for dir in "$FRAMES"/*/; do
    scene=$(basename "$dir")
    out="docs/assets/$scene.gif"
    width=$([ "$(crop "$scene" | cut -d: -f1)" -lt 1500 ] && echo 650 || echo 880)
    "$FFMPEG" -loglevel error -y -f concat -safe 0 -i "$dir/frames.txt" -vf \
        "crop=$(crop "$scene"),fps=25,scale=$width:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
        -loop 0 "$out"
    echo "$out $(du -h "$out" | cut -f1)"
done
rm -rf "$FRAMES"
