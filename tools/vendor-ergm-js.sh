#!/usr/bin/env bash
# Refreshes the vendored ergm-js assets from an upstream release tag.
#
# Usage: tools/vendor-ergm-js.sh v0.2.2
#
# After running, review the printed checklist AND `git diff --stat` before
# committing -- upstream may have changed DEFAULTS, added/removed a term, or
# changed its injected CSS in ways this extension needs to mirror.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <upstream-tag, e.g. v0.2.2>" >&2
  exit 1
fi

TAG="$1"
UPSTREAM_VERSION="${TAG#v}"
RAW_BASE="https://raw.githubusercontent.com/gvegayon/ergm-js/${TAG}"

cd "$(dirname "$0")/.."
DST="_extensions/ergm-quarto/resources/ergm-js"

echo "Fetching ergm-js ${TAG} from ${RAW_BASE} ..."

curl -fsSL "${RAW_BASE}/src/ergm.js" -o "${DST}/src/ergm.js"
curl -fsSL "${RAW_BASE}/src/ergm-widget.js" -o "${DST}/src/ergm-widget.js"
curl -fsSL "${RAW_BASE}/vendor/graphology.umd.min.js" -o "${DST}/vendor/graphology.umd.min.js"
curl -fsSL "${RAW_BASE}/vendor/sigma.min.js" -o "${DST}/vendor/sigma.min.js"
curl -fsSL "${RAW_BASE}/LICENSE.md" -o "${DST}/LICENSE.md"

downloaded_version="$(grep -o 'const VERSION = "[^"]*"' "${DST}/src/ergm.js" | sed -E 's/.*"([^"]*)"/\1/')"
if [ "$downloaded_version" != "$UPSTREAM_VERSION" ]; then
  echo "ERROR: downloaded ergm.js reports VERSION=\"$downloaded_version\", expected \"$UPSTREAM_VERSION\" (from tag $TAG)" >&2
  echo "Refusing to update VERSION/ERGM_JS_VERSION with a mismatched pair." >&2
  exit 1
fi

echo "$UPSTREAM_VERSION" > "${DST}/VERSION"

sed -i.bak -E "s/local ERGM_JS_VERSION = \"[^\"]*\"/local ERGM_JS_VERSION = \"${UPSTREAM_VERSION}\"/" \
  "_extensions/ergm-quarto/ergm-quarto.lua"
rm -f "_extensions/ergm-quarto/ergm-quarto.lua.bak"

cat <<EOF

Vendored assets updated to ergm-js ${TAG}.

Manual checklist before committing (this script cannot verify these):
  [ ] Did DEFAULTS in src/ergm-widget.js gain or lose any keys?
      -> update the SPEC table in ergm-quarto.lua and the tables in
         reference.qmd to match.
  [ ] Did DEFAULTS.height change from 360?
      -> update the min-height fallback in resources/ergm-quarto.css.
  [ ] Did the injected CSS string (ensureCSS / const CSS) in
      src/ergm-widget.js gain new selectors or rules?
      -> re-check the specificity table in resources/ergm-quarto.css's
         header comment, and add overrides if needed.
  [ ] Did ERGM.TERMS in src/ergm.js change?
      -> update the model-term whitelist (MODEL_TERMS) in ergm-quarto.lua.
  [ ] Bump _extension.yml's \`version\`, EXT_VERSION in ergm-quarto.lua, and
      the version string in resources/ergm-quarto.js -- together, since
      they must always agree (tools/check-versions.sh enforces this).
  [ ] Add a CHANGELOG.md entry.

Then review the diff:
  git diff --stat
  tools/check-versions.sh
EOF
