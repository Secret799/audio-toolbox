#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPOSITORY_ROOT/Tests/AudioToolboxIntegrationTests/Fixtures"

mkdir -p "$OUT"

ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.25 -metadata title='Fixture Title' -metadata artist='Original Artist' -metadata album='Original Album' "$OUT/sample.mp3"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.25 -c:a aac -metadata title='Fixture Title' -metadata artist='Original Artist' -metadata album='Original Album' "$OUT/sample.m4a"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.25 -metadata title='Fixture Title' -metadata artist='Original Artist' -metadata album='Original Album' "$OUT/sample.flac"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.25 -metadata title='Fixture Title' -metadata artist='Original Artist' -metadata album='Original Album' "$OUT/sample.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.25 -c:a libvorbis -metadata title='Fixture Title' -metadata artist='Original Artist' -metadata album='Original Album' "$OUT/sample.ogg"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 2 -c:a libvorbis -map_metadata -1 "$OUT/sample-long.ogg"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 0.25 -c:a aac -f adts "$OUT/sample.aac"
