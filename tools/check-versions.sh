#!/usr/bin/env bash
# Fails if any of the version strings that must agree have drifted apart.
# Run from the repo root: tools/check-versions.sh
set -euo pipefail

cd "$(dirname "$0")/.."

EXT_DIR="_extensions/ergm-quarto"
VERSION_FILE="$EXT_DIR/resources/ergm-js/VERSION"
LUA_FILE="$EXT_DIR/ergm-quarto.lua"
ERGM_JS_FILE="$EXT_DIR/resources/ergm-js/src/ergm.js"
BOOTSTRAP_JS="$EXT_DIR/resources/ergm-quarto.js"
EXTENSION_YML="$EXT_DIR/_extension.yml"

fail=0

vendored_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
lua_ergm_js_version="$(grep -o 'ERGM_JS_VERSION = "[^"]*"' "$LUA_FILE" | sed -E 's/.*"([^"]*)"/\1/')"
ergm_js_const_version="$(grep -o 'const VERSION = "[^"]*"' "$ERGM_JS_FILE" | sed -E 's/.*"([^"]*)"/\1/')"

ext_yml_version="$(grep -E '^version:' "$EXTENSION_YML" | sed -E 's/^version:[[:space:]]*//')"
lua_ext_version="$(grep -o 'EXT_VERSION = "[^"]*"' "$LUA_FILE" | sed -E 's/.*"([^"]*)"/\1/')"
bootstrap_version="$(grep -o 'version: "[^"]*"' "$BOOTSTRAP_JS" | sed -E 's/.*"([^"]*)"/\1/')"

check() {
  local label_a="$1" val_a="$2" label_b="$3" val_b="$4"
  if [ "$val_a" != "$val_b" ]; then
    echo "MISMATCH: $label_a ($val_a) != $label_b ($val_b)" >&2
    fail=1
  else
    echo "OK: $label_a == $label_b ($val_a)"
  fi
}

check "VERSION file" "$vendored_version" "ergm-quarto.lua ERGM_JS_VERSION" "$lua_ergm_js_version"
check "VERSION file" "$vendored_version" "vendored ergm.js VERSION const" "$ergm_js_const_version"
check "_extension.yml version" "$ext_yml_version" "ergm-quarto.lua EXT_VERSION" "$lua_ext_version"
check "_extension.yml version" "$ext_yml_version" "ergm-quarto.js version" "$bootstrap_version"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Version check FAILED. See MISMATCH lines above." >&2
  exit 1
fi

echo ""
echo "All version strings agree."
