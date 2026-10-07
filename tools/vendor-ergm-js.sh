#!/usr/bin/env bash
# Refreshes the vendored ergm-js assets from a release published on npm
# (https://www.npmjs.com/package/ergm-js).
#
# Usage: tools/vendor-ergm-js.sh 0.2.2     (a leading "v" is accepted)
#
# Needs npm. After running, review the printed checklist AND `git diff --stat`
# before committing -- upstream may have changed DEFAULTS, added/removed a
# term, or changed its injected CSS in ways this extension needs to mirror.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <ergm-js version, e.g. 0.2.2>" >&2
  exit 1
fi

TAG="v${1#v}"
UPSTREAM_VERSION="${TAG#v}"

cd "$(dirname "$0")/.."
DST="_extensions/ergm-quarto/resources/ergm-js"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching ergm-js@${UPSTREAM_VERSION} from npm ..."

(cd "$WORK" && npm pack "ergm-js@${UPSTREAM_VERSION}" --silent >/dev/null)
tar -xzf "$WORK"/ergm-js-"${UPSTREAM_VERSION}".tgz -C "$WORK"

cp "$WORK/package/src/ergm.js" "${DST}/src/ergm.js"
cp "$WORK/package/src/ergm-widget.js" "${DST}/src/ergm-widget.js"
cp "$WORK/package/vendor/graphology.umd.min.js" "${DST}/vendor/graphology.umd.min.js"
cp "$WORK/package/vendor/sigma.min.js" "${DST}/vendor/sigma.min.js"
cp "$WORK/package/LICENSE.md" "${DST}/LICENSE.md"

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
