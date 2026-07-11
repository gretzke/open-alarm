#!/usr/bin/env bash
# Generates development placeholders. For production, source appropriately licensed
# recordings, trim a <=30s alert excerpt, bake a ~1s fade-out, encode it as 44.1kHz
# linear-PCM CAF, and keep the uncut classical recording as an AAC .m4a full track.
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

# These use distinct synthesized material only as development placeholders.
render_caf "$output_dir/ringtone_classic_placeholder.caf" \
    "aevalsrc=if(lt(mod(t\\,1)\\,0.18)\\,0.28*sin(2*PI*880*t)\\,0):s=44100:d=20"
render_caf "$output_dir/ringtone_dawn_placeholder.caf" \
    "aevalsrc=0.22*sin(2*PI*(220*t+5.5*t*t))*(0.2+0.8*sin(PI*t/20)^2):s=44100:d=20"
render_nature_caf
render_caf "$output_dir/ringtone_energetic_placeholder.caf" \
    "aevalsrc=0.20*sin(2*PI*(220*pow(2\\,floor(mod(t\\,2)*4)/12))*t):s=44100:d=20"

# A small repeating sine melody. Rendering the first 20s with the same generator
# keeps the excerpt aligned to the full track before its excerpt-only tail fade.
classical_source="aevalsrc=0.20*sin(2*PI*(if(lt(mod(t\\,4)\\,0.5)\\,261.63\\,if(lt(mod(t\\,4)\\,1)\\,293.66\\,if(lt(mod(t\\,4)\\,1.5)\\,329.63\\,if(lt(mod(t\\,4)\\,2)\\,392\\,if(lt(mod(t\\,4)\\,2.5)\\,329.63\\,if(lt(mod(t\\,4)\\,3)\\,293.66\\,if(lt(mod(t\\,4)\\,3.5)\\,261.63\\,196))))))))*t):s=44100:d=60"
render_caf "$output_dir/ringtone_classical_placeholder.caf" "$classical_source"
"$ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "$classical_source" -t 60 -ar 44100 -c:a aac -b:a 128k \
    "$output_dir/ringtone_classical_placeholder_full.m4a"

for asset in "$output_dir"/ringtone_*; do
    echo "== $asset =="
    afinfo "$asset" | grep -E "estimated duration|duration" || true
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$asset"
done

# Validation: catalog excerptDuration constants (RingtoneCatalog.swift) must match
# the encoded files, and no AlarmKit excerpt may exceed 30 seconds. Drift between a
# constant and its file silently breaks phase-aligned continuation, so fail loudly.
# (name:expected pairs — macOS bash 3.2 has no associative arrays.)
expected_durations="
ringtone_classic_placeholder.caf:20
ringtone_classical_placeholder.caf:20
ringtone_classical_placeholder_full.m4a:60
ringtone_dawn_placeholder.caf:20
ringtone_nature_placeholder.caf:20
ringtone_energetic_placeholder.caf:20
"

validation_failed=0
for entry in $expected_durations; do
    name=${entry%%:*}
    expected=${entry##*:}
    asset="$output_dir/$name"
    actual=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$asset")
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
