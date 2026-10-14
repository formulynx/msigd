#!/usr/bin/env bash
#
# Collects identification and query data for an unsupported MSI monitor on macOS.
#
#   Step 1: run 'msigd --info --debug --query' and extract the s140/s150 id bytes
#   Step 2: build a temporary msigd that maps those ids to ALL series (read-only)
#           and query every known setting to see which ones the monitor answers
#
# Results go to private/probe-<timestamp>/ (git-ignored). Serial numbers are masked.
# The source tree is not modified; step 2 builds from a copy in $TMPDIR and keeps the
# resulting binary as msigd-probe in the result directory for contrib/map_osd_values.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BREW_PREFIX="$(brew --prefix)"
MAKE_ARGS=(TARGETOS=osx CXX=clang++ "CXXEXTRAFLAGS=-I$BREW_PREFIX/include" "LDFLAGS=-L$BREW_PREFIX/lib")
OUT="$ROOT/private/probe-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

ask() { local reply; read -r -p "$1" reply; printf '%s' "$reply"; }

# Byte-safe: the id bytes may be non-ASCII, so never let the shell re-encode them.
mask_serials() {
	LC_ALL=C sed -E \
		-e 's/^(Serial: +).*/\1<masked>/' \
		-e 's/(with serial <)[^>]*>/\1<masked>>/' \
		-e "s/^(serial : ').*'\$/\\1<masked>'/" \
		"$1" > "$2"
}

# Prints the bytes between <...> of the given id line as space-separated hex.
id_hex() (
	export LC_ALL=C
	sed -n "s/^$1: *<\\(.*\\)>\$/\\1/p" "$2" | head -n 1 | tr -d '\n' | od -An -tx1 -v | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
)

# "30 30 7c" -> "\x30\x30\x7c" (each escape ends at the next backslash, so no greedy-hex issue)
c_escape() { local out=""; for h in $1; do out+="\\x$h"; done; printf '%s' "$out"; }

echo "== Build msigd"
brew list hidapi >/dev/null 2>&1 || { echo "hidapi is not installed: brew install hidapi libusb-compat"; exit 1; }
make "${MAKE_ARGS[@]}" >/dev/null

echo
echo "Connect the monitor's USB upstream port to this Mac and power the monitor on."
ask "Press Enter when ready... " >/dev/null
echo
FW="$(ask "Firmware version shown in the OSD (e.g. FW.011, empty if unknown): ")"
MODEL="$(ask "Monitor model name [MAG 275CQRXF]: ")"
MODEL="${MODEL:-MAG 275CQRXF}"
printf 'model: %s\nfirmware: %s\ndate: %s\n' "$MODEL" "${FW:-unknown}" "$(date -u +%FT%TZ)" > "$OUT/notes.txt"

echo
echo "== Step 1: msigd --info --debug --query"
RAW="$OUT/.step1.raw"
set +e
./msigd --info --debug --query > "$RAW" 2>&1
STEP1_RC=$?
set -e
mask_serials "$RAW" "$OUT/step1_info_debug_query.txt"
rm -f "$RAW"
echo "exit code: $STEP1_RC" >> "$OUT/notes.txt"

S140_HEX="$(id_hex s140 "$OUT/step1_info_debug_query.txt")"
S150_HEX="$(id_hex s150 "$OUT/step1_info_debug_query.txt")"
if [[ -z "$S140_HEX" || -z "$S150_HEX" ]]; then
	echo "Could not read s140/s150. See $OUT/step1_info_debug_query.txt"
	exit 1
fi
SERIES="$(LC_ALL=C sed -n 's/^Monitor Series: *//p' "$OUT/step1_info_debug_query.txt" | head -n 1)"
{
	echo "s140 hex: $S140_HEX"
	echo "s150 hex: $S150_HEX"
	echo "s140 C:   \"$(c_escape "$S140_HEX")\""
	echo "s150 C:   \"$(c_escape "$S150_HEX")\""
	echo "detected series: $SERIES"
} | tee "$OUT/ids.txt"

if [[ "$SERIES" != "Unknown Series" ]]; then
	echo
	echo "msigd already identifies this monitor as '$SERIES'."
	[[ "$(ask "Continue with step 2 anyway? [y/N]: ")" == [yY]* ]] || { echo "Results: $OUT"; exit 0; }
fi

echo
echo "== Step 2: query all known settings with a temporary read-only build"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/msigd-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp -R src makefile "$WORK/"
# make 3.81 compares mtimes in whole seconds, so a copied object would look up to date.
rm -f "$WORK"/src/*.o

# Appended last in known_models because the identification loop keeps the last match.
ENTRY="	{ ALL, \"$(c_escape "$S140_HEX")\", \"$(c_escape "$S150_HEX")\", \"PROBE\", LT_NONE, true },"
# ENVIRON instead of -v: awk -v would interpret the \x escapes meant for the C source.
ENTRY="$ENTRY" awk '/^static std::vector<identity_t> known_models/ { m = 1 } m && /^};/ { print ENVIRON["ENTRY"]; m = 0; n++ } { print } END { exit n == 1 ? 0 : 1 }' \
	src/msigd.cpp > "$WORK/src/msigd.cpp" || { echo "Anchor line for known_models not found in src/msigd.cpp"; exit 1; }
make -C "$WORK" "${MAKE_ARGS[@]}" >/dev/null
grep -q -a PROBE "$WORK/msigd" || { echo "Probe entry is missing from the temporary build"; exit 1; }
cp "$WORK/msigd" "$OUT/msigd-probe"

RAW="$OUT/.step2.raw"
set +e
"$OUT/msigd-probe" --info --debug --query > "$RAW" 2>&1
STEP2_RC=$?
set -e
mask_serials "$RAW" "$OUT/step2_all_settings.txt"
rm -f "$RAW"
echo "step2 exit code: $STEP2_RC" >> "$OUT/notes.txt"

ANSWERED="$(LC_ALL=C grep -cE "^[a-z0-9_]+ : '" "$OUT/step2_all_settings.txt" || true)"
FAILED="$(LC_ALL=C grep -c "Error querying device on" "$OUT/step2_all_settings.txt" || true)"
LC_ALL=C grep -E "^[a-z0-9_]+ : '" "$OUT/step2_all_settings.txt" > "$OUT/step2_answered.txt" || true
LC_ALL=C grep "Error querying device on" "$OUT/step2_all_settings.txt" > "$OUT/step2_failed.txt" || true

echo
echo "answered: $ANSWERED, failed: $FAILED (counted from step2_all_settings.txt)"
echo "Results: $OUT"
ls -1 "$OUT"
