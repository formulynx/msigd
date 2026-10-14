#!/usr/bin/env bash
#
# Records which raw value the monitor reports for each OSD option of a setting.
#
#   contrib/map_osd_values.sh [probe-dir] [setting ...]
#
# probe-dir defaults to the newest private/probe-*/ created by probe_monitor_macos.sh
# and must contain msigd-probe. Settings default to a prompt. For every setting you
# select an option in the OSD, type its label, and the script reads the raw value.
# Pairs are appended to <probe-dir>/step3_osd_map.csv as setting,osd_label,raw_value.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ $# -gt 0 && -d "$1" ]]; then
	DIR="$1"; shift
else
	DIR="$(ls -1d private/probe-* 2>/dev/null | tail -n 1)"
fi
[[ -n "$DIR" && -x "$DIR/msigd-probe" ]] || { echo "No probe directory with msigd-probe found. Run contrib/probe_monitor_macos.sh first."; exit 1; }
CSV="$DIR/step3_osd_map.csv"
[[ -f "$CSV" ]] || echo "setting,osd_label,raw_value" > "$CSV"

ask() { local reply; read -r -p "$1" reply; printf '%s' "$reply"; }
csv_field() { printf '"%s"' "${1//\"/\"\"}"; }

# Prints the raw value, or ERROR plus msigd's messages (on stderr) if the monitor did not answer.
# Queries everything: with the ALL-series probe, --filter rejects names defined for several series.
read_raw() {
	local out
	out="$("$DIR/msigd-probe" --debug --query 2>&1 || true)"
	LC_ALL=C sed -n "s/^$1 : '\\(.*\\)'\$/\\1/p" <<< "$out" | head -n 1 | grep . && return
	echo ERROR
	# Errors for other settings are expected noise; keep this setting's and non-query errors.
	LC_ALL=C grep '^msigd:' <<< "$out" | grep -v -i serial | grep -E -v "Error querying device on " | sed 's/^/  /' >&2 || true
	LC_ALL=C grep -E "^msigd: Error querying device on $1 - " <<< "$out" | sed 's/^/  /' >&2 || true
}

SETTINGS=("$@")
if [[ ${#SETTINGS[@]} -eq 0 ]]; then
	[[ -f "$DIR/step2_answered.txt" ]] && { echo "Settings the monitor answered in step 2:"; sed 's/ : .*//' "$DIR/step2_answered.txt" | sort -u | paste -sd ' ' -; }
	read -r -a SETTINGS -p "Settings to map (space separated): "
fi

for name in "${SETTINGS[@]}"; do
	echo
	echo "== $name"
	echo "Existing definitions in src/msigd.cpp (for comparison):"
	grep -nE "\"[^\"]{5}\", \"$name\"" src/msigd.cpp | sed 's/^/  /' || echo "  (none)"
	echo "Current raw value: $(read_raw "$name")"
	while :; do
		label="$(ask "Select an option for '$name' in the OSD, then type its label (empty = next setting): ")"
		[[ -z "$label" ]] && break
		raw="$(read_raw "$name")"
		echo "  $label -> '$raw'"
		printf '%s,%s,%s\n' "$(csv_field "$name")" "$(csv_field "$label")" "$(csv_field "$raw")" >> "$CSV"
	done
done

echo
echo "Saved: $CSV"
