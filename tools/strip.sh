#!/bin/bash
# On the pod: six evenly spaced frames of a video side by side -> /tmp/strip_<name>.jpg
f=$1; n=$(basename "$f" .mp4); d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
args=(); i=0
for k in 1 2 3 4 5 6; do t=$(python3 -c "print(round($d*($k-0.5)/6,2))"); ffmpeg -v error -y -ss $t -i "$f" -frames:v 1 -vf scale=256:-1 /tmp/_s$k.jpg; args+=(-i /tmp/_s$k.jpg); done
ffmpeg -v error -y "${args[@]}" -filter_complex hstack=inputs=6 /tmp/strip_$n.jpg && echo /tmp/strip_$n.jpg
