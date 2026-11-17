#!/usr/bin/env bash
# Round-flow regression suite.
#
# The bot bugs this project actually hit were all "the round never resolves":
# a carrier that wedged, goals that were re-randomised every frame, spawns with
# no floor under them.  Checking that a round *ends* catches all of those, and
# it is the only check that survives the nondeterminism of a bot match, so the
# suite asserts exactly that: on every map, a round reaches a result.
#
#   tools/check_rounds.sh                     # all 15 maps
#   tools/check_rounds.sh de_dust2 de_inferno # a subset
#   FRAMES=30000 tools/check_rounds.sh        # longer window
#
# Exits non-zero if any map fails to resolve a round.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
FRAMES="${FRAMES:-26000}"
TELEMETRY="${TELEMETRY:-6}"
BOTS="${BOTS:-8}"
# Spectator mode is the honest test: with a human in the round the human never
# plants (no input in headless), so a T-side round can only stall.
SPECTATE="${SPECTATE:-1}"

ALL_MAPS=(
  de_aztec de_cbble de_chateau de_dust de_dust2 de_inferno de_nuke
  de_piranesi de_prodigy de_storm de_survivor de_torn de_train de_vegas
  de_vertigo
)

if [ "$#" -gt 0 ]; then
  MAPS=("$@")
else
  MAPS=("${ALL_MAPS[@]}")
fi

if ! command -v "$GODOT" > /dev/null 2>&1 && [ ! -x "$GODOT" ]; then
  echo "godot binary not found: set GODOT=/path/to/godot" >&2
  exit 2
fi

failed=()
passed=0

for map in "${MAPS[@]}"; do
  printf '%-14s ' "$map"
  extra=()
  [ "$SPECTATE" = "1" ] && extra+=(--spectate)
  output="$("$GODOT" --headless --path "$REPO_ROOT" \
      --quit-after "$FRAMES" -- \
      --map="$map" --bots="$BOTS" --telemetry="$TELEMETRY" "${extra[@]}" 2>&1)"

  # A round resolving means the bomb went off, was defused, or one side was
  # eliminated -- and every one of those moves the score.  Counting score
  # increments is therefore the one check that does not depend on the
  # telemetry sample landing next to the event.
  events="$(printf '%s\n' "$output" | grep -oE 'score=[0-9]+:[0-9]+' \
      | awk -F'[=:]' '$2 + $3 > 0' | sort -u | wc -l)"
  scores="$(printf '%s\n' "$output" | grep -oE 'score=[0-9]+:[0-9]+' | sort -u | tr '\n' ' ')"
  # Script errors mean the run is meaningless even if a round happened to end.
  errors="$(printf '%s\n' "$output" | grep -c 'SCRIPT ERROR')"

  if [ "$errors" -gt 0 ]; then
    printf 'FAIL  (%d script errors)\n' "$errors"
    printf '%s\n' "$output" | grep 'SCRIPT ERROR' | head -3 | sed 's/^/    /'
    failed+=("$map")
    continue
  fi

  if [ "$events" -eq 0 ]; then
    printf 'FAIL  (no round resolved in %s frames)\n' "$FRAMES"
    failed+=("$map")
    continue
  fi

  printf 'ok    %s\n' "$scores"
  passed=$((passed + 1))
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all ${passed} maps resolved a round"
