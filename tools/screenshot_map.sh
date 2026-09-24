#!/usr/bin/env bash
# Renders one of this game's modes to screenshots/ so a person can look at the level.
#
#   tools/screenshot_map.sh warrens
#   tools/screenshot_map.sh reef --at=632,1180 --name=lagoon   # stand somewhere else
#   tools/screenshot_map.sh warrens --admin   # also a beacon and a blind
#
# Uses xvfb-run because this needs a rendering context: --headless gives a null renderer
# and a 64 x 64 viewport, and every frame it saves is empty — which is worse than no
# screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
exec xvfb-run -a godot --path . --resolution 1280x800 \
    --script tools/screenshot_map.gd -- "${@:-warrens}"
