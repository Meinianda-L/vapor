#!/bin/bash
# Headless VaporBoost test suite. No windows are created.
set -u
cd "$(dirname "$0")"
DYLIB="$PWD/../VaporBoost.dylib"
OUT="$PWD/out"; rm -rf "$OUT"; mkdir -p "$OUT"
FRAMES=60

run() {  # name, harness binary, mode, appW appH layerW layerH
    local name=$1 bin=$2 mode=$3; shift 3
    mkdir -p "$OUT/$name"
    echo "=== $name (mode=$mode, $(file -b "$bin" | cut -d' ' -f3-4))"
    if [ "$mode" = none ]; then
        ./"$bin" $FRAMES "$@" 2>&1
    else
        env DYLD_INSERT_LIBRARIES="$DYLIB" VAPOR_BOOST="$mode" \
            VAPOR_BOOST_STATS="$OUT/$name/stats.json" VAPOR_BOOST_CAPTURE="$OUT/$name" \
            VAPOR_BOOST_CAPTURE_FRAMES=20,21 ./"$bin" $FRAMES "$@" 2>&1 | grep -v "^$"
        python3 -c "import json;d=json.load(open('$OUT/$name/stats.json'));print('stats:',{k:v for k,v in d.items() if k!='mode'})"
        if ls "$OUT/$name"/f020_real_* >/dev/null 2>&1; then python3 analyze.py "$OUT/$name" 20 21; fi
    fi
}

run baseline        harness     none             1280 720 2560 1440
run off             harness     off              1280 720 2560 1440
run upscale         harness     upscale          1280 720 2560 1440
run framegen        harness     framegen         1280 720 1280 720
run upscale_fg      harness     upscale,framegen 1280 720 2560 1440
run upscale_fg_x86  harness_x86 upscale,framegen 1280 720 2560 1440
