#!/usr/bin/env bash
# Generates development placeholders. Classical assets are imported from licensed
# recordings with this recipe (SRC is the licensed recording):
#   ffmpeg -i SRC -ar 44100 -ac 2 -c:a aac -b:a 128k FULL.m4a
#   ffmpeg -i SRC -t 29 -af "afade=t=out:st=28:d=1" -ar 44100 -ac 2 -c:a pcm_s16le tmp.caf
#   afconvert -f caff -d ima4 tmp.caf EXCERPT.caf
set -euo pipefail

ffmpeg=/opt/homebrew/bin/ffmpeg
output_dir="OpenAlarm/Resources/Ringtones"
mkdir -p "$output_dir"

render_caf() {
    local output=$1
    local source=$2
    "$ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "$source" -t 20 \
        -af "afade=t=out:st=19:d=1" -ar 44100 -c:a pcm_s16le "$output"
}

render_nature_caf() {
    "$ffmpeg" -hide_banner -loglevel error -y \
        -f lavfi -i "anoisesrc=color=pink:amplitude=0.14:sample_rate=44100:duration=20" \
        -f lavfi -i "aevalsrc=if(lt(mod(t\\,3)\\,0.18)\\,0.16*sin(2*PI*(1400+1600*mod(t\\,3))*t)\\,0):s=44100:d=20" \
        -filter_complex "[0:a]highpass=f=800,lowpass=f=4200[noise];[noise][1:a]amix=inputs=2,afade=t=out:st=19:d=1" \
        -ar 44100 -c:a pcm_s16le "$output_dir/ringtone_nature_placeholder.caf"
}

asset_duration() {
    local asset=$1
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$asset" || true)
    if [ -n "$duration" ] && [ "$duration" != "N/A" ]; then
        echo "$duration"
        return
    fi

    afinfo "$asset" | awk '/estimated duration:/ { print $3; exit }'
}

# These use distinct synthesized material only as development placeholders.
render_caf "$output_dir/ringtone_classic_placeholder.caf" \
    "aevalsrc=if(lt(mod(t\\,1)\\,0.18)\\,0.28*sin(2*PI*880*t)\\,0):s=44100:d=20"
render_caf "$output_dir/ringtone_dawn_placeholder.caf" \
    "aevalsrc=0.22*sin(2*PI*(220*t+5.5*t*t))*(0.2+0.8*sin(PI*t/20)^2):s=44100:d=20"
render_nature_caf
render_caf "$output_dir/ringtone_energetic_placeholder.caf" \
    "aevalsrc=0.20*sin(2*PI*(220*pow(2\\,floor(mod(t\\,2)*4)/12))*t):s=44100:d=20"

for asset in "$output_dir"/ringtone_*; do
    echo "== $asset =="
    afinfo "$asset" | grep -E "estimated duration|duration" || true
    echo "duration=$(asset_duration "$asset")"
done

# Validation: catalog excerptDuration constants (RingtoneCatalog.swift) must match
# the encoded files, and no AlarmKit excerpt may exceed 30 seconds. Drift between a
# constant and its file silently breaks phase-aligned continuation, so fail loudly.
# (name:expected pairs — macOS bash 3.2 has no associative arrays.)
expected_durations="
ringtone_classic_placeholder.caf:20
ringtone_classical_valkyries.caf:28.993129
ringtone_classical_valkyries_full.m4a:136.945011
ringtone_classical_winter.caf:28.993129
ringtone_classical_winter_full.m4a:222.650998
ringtone_classical_bluedanube.caf:28.993129
ringtone_classical_bluedanube_full.m4a:41.137007
ringtone_classical_cellosuite.caf:28.993129
ringtone_classical_cellosuite_full.m4a:137.898005
ringtone_classical_russiandance.caf:28.993129
ringtone_classical_russiandance_full.m4a:71.291995
ringtone_dawn_placeholder.caf:20
ringtone_nature_placeholder.caf:20
ringtone_energetic_placeholder.caf:20
"

validation_failed=0
for entry in $expected_durations; do
    name=${entry%%:*}
    expected=${entry##*:}
    asset="$output_dir/$name"
    actual=$(asset_duration "$asset")
    if ! awk -v a="$actual" -v e="$expected" 'BEGIN { exit (a - e <= 0.05 && e - a <= 0.05) ? 0 : 1 }'; then
        echo "FAIL: $name duration $actual != expected $expected (max 0.05s off)" >&2
        validation_failed=1
    fi
    case $name in
    *.caf)
        if ! awk -v a="$actual" 'BEGIN { exit (a <= 30.0) ? 0 : 1 }'; then
            echo "FAIL: $name is an AlarmKit excerpt and exceeds 30 seconds ($actual)" >&2
            validation_failed=1
        fi
        ;;
    esac
done

if [ "$validation_failed" -ne 0 ]; then
    echo "Asset validation FAILED - fix the files or update the catalog constants." >&2
    exit 1
fi
echo "Asset validation passed: durations match catalog constants, excerpts <= 30s."
