#!/usr/bin/env bash
# Validates the bundled ringtone assets and records their import recipes.
#
# Music and nature excerpts (29 seconds, mono PCM with a one-second tail fade):
#   ffmpeg -i SRC -vn -t 29 -af "afade=t=out:st=28:d=1" -ar 44100 -ac 1 -c:a pcm_s16le tmp.caf
#   afconvert -f caff -d ima4 tmp.caf EXCERPT.caf
#
# Short classic alarm loops (no trim or fade, mono PCM):
#   ffmpeg -i SRC -vn -ar 44100 -ac 1 -c:a pcm_s16le tmp.caf
#   afconvert -f caff -d ima4 tmp.caf EXCERPT.caf
#
# Full tracks (stereo AAC, 128 kbps):
#   ffmpeg -i SRC -vn -ar 44100 -ac 2 -c:a aac -b:a 128k FULL.m4a
#
# Do not generate placeholder tones here. All shipped assets are imported source
# recordings documented in OpenAlarm/Resources/Ringtones/SOURCES.md.
set -euo pipefail

output_dir="OpenAlarm/Resources/Ringtones"

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

# name:expected pairs — macOS bash 3.2 has no associative arrays. CAF values use
# afinfo precision; all _full.m4a values are the exact ffprobe results.
expected_durations="
ringtone_classic_twinbell.caf:29.000000
ringtone_classic_churchbells.caf:29.000000
ringtone_classic_ghanta.caf:29.000000
ringtone_classic_koshichime.caf:28.989841
ringtone_classic_bedsideclock.caf:1.000000
ringtone_classic_digitalalarm.caf:0.500000
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
ringtone_dawn_morning.caf:29.000000
ringtone_dawn_morning_full.m4a:153.311995
ringtone_dawn_dreamer.caf:29.000000
ringtone_dawn_dreamer_full.m4a:204.068005
ringtone_dawn_dreamculture.caf:29.000000
ringtone_dawn_dreamculture_full.m4a:214.360998
ringtone_dawn_lightthought.caf:29.000000
ringtone_dawn_lightthought_full.m4a:162.480998
ringtone_dawn_deliberatethought.caf:29.000000
ringtone_dawn_deliberatethought_full.m4a:177.456009
ringtone_dawn_magicscout.caf:29.000000
ringtone_dawn_magicscout_full.m4a:233.849002
ringtone_dawn_wisdominthesun.caf:29.000000
ringtone_dawn_wisdominthesun_full.m4a:154.566009
ringtone_dawn_motions.caf:29.000000
ringtone_dawn_motions_full.m4a:117.028005
ringtone_nature_morningbirds.caf:29.000000
ringtone_nature_morningbirds_full.m4a:174.862993
ringtone_nature_oceanwaves.caf:29.000000
ringtone_nature_oceanwaves_full.m4a:120.000000
ringtone_nature_rain.caf:29.000000
ringtone_nature_rain_full.m4a:84.000000
ringtone_nature_foreststream.caf:29.000000
ringtone_nature_foreststream_full.m4a:71.303991
ringtone_nature_rooster.caf:29.000000
ringtone_nature_rooster_full.m4a:54.000000
ringtone_energetic_clouddancer.caf:29.000000
ringtone_energetic_clouddancer_full.m4a:219.871995
ringtone_energetic_voxelrevolution.caf:29.000000
ringtone_energetic_voxelrevolution_full.m4a:129.907007
ringtone_energetic_newerwave.caf:29.000000
ringtone_energetic_newerwave_full.m4a:174.601995
ringtone_energetic_ravingenergy.caf:29.000000
ringtone_energetic_ravingenergy_full.m4a:243.643991
ringtone_energetic_glitterblast.caf:29.000000
ringtone_energetic_glitterblast_full.m4a:177.815011
ringtone_energetic_hearwhattheysay.caf:29.000000
ringtone_energetic_hearwhattheysay_full.m4a:137.639002
ringtone_energetic_avemarimba.caf:29.000000
ringtone_energetic_avemarimba_full.m4a:169.770000
"

validation_failed=0
for entry in $expected_durations; do
    name=${entry%%:*}
    expected=${entry##*:}
    asset="$output_dir/$name"

    if [ ! -f "$asset" ]; then
        echo "FAIL: missing asset $name" >&2
        validation_failed=1
        continue
    fi

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

echo "Asset validation passed: 31 CAF excerpts and 25 full tracks match expected durations."
