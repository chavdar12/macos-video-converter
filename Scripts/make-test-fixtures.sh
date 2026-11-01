#!/bin/zsh
# Regenerates the sample media used by the unit and UI tests.
# Needs a full ffmpeg (e.g. `brew install ffmpeg`); it's only used to create fixtures, not by the app or tests.
#
# Every video is a flat dark picture, so burned-in (white) subtitles are easy to detect. Subtitles
# show from 0.2 to 1.0 s; the MKV's non-default track shows from 1.2 to 1.8 s instead, so tests
# can tell which track was burned in.
set -euo pipefail
root="${0:A:h}/.."
cd "$root/video-converterTests/Fixtures"

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
video=(-f lavfi -i "color=c=0x203040:size=320x240:rate=24")
mono=(-f lavfi -i "sine=frequency=440:sample_rate=48000")

cat > sidecar.srt <<'S'
1
00:00:00,200 --> 00:00:01,000
SIDECAR SUBTITLE
S
cat > early.srt <<'S'
1
00:00:00,200 --> 00:00:01,000
EARLY SUBTITLE
S
cat > late.srt <<'S'
1
00:00:01,200 --> 00:00:01,800
LATE SUBTITLE
S

# H.264 + AAC + embedded mov_text.
ff $video $mono -i early.srt -t 2 -map 0 -map 1 -map 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 64k -c:s mov_text h264-aac-movtext.mp4

# 10-bit HEVC + 5.1 AC-3 + two SRT tracks; the second (early) one is the default.
ff $video -f lavfi -i "sine=sample_rate=48000" -i late.srt -i early.srt -t 2 -map 0 -map 1 -map 2 -map 3 \
    -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p10le -c:a ac3 -ac 6 -b:a 192k \
    -c:s srt -disposition:s:0 0 -disposition:s:1 default hevc10-ac3-2srt.mkv

# MPEG-TS (named .mts: Xcode treats .ts as TypeScript and won't bundle it), which starts at ~1.4 s rather than 0, with MP2 audio.
ff $video -f lavfi -i "sine=sample_rate=44100" -t 2 -c:v libx264 -pix_fmt yuv420p -c:a mp2 h264-mp2.mts

# VP8 (software decoding) + 5.1 Opus.
ff $video -f lavfi -i "sine=sample_rate=48000" -t 2 -c:v libvpx -b:v 200k \
    -af "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a libopus -mapping_family 1 vp8-opus51.mkv

# Audio only.
ff $mono -t 2 -c:a aac -b:a 64k aac-only.m4a

rm early.srt late.srt
echo "This is not a video." > not-media.txt

# The UI tests queue one sample in the app.
cp h264-aac-movtext.mp4 "$root/video-converterUITests/Fixtures/"
