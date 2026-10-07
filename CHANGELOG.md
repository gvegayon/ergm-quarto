# Changelog

## 0.3.0-0

Versions now follow ergm-js: `X.Y.Z` is the vendored ergm-js version and `-N`
counts releases of this extension with it.

- Vendors ergm-js 0.3.0 (new model engine and term factories; the widget
  itself is unchanged, so the exposed terms are still `edges`, `nodematch` and
  `mutual`).
- `tools/vendor-ergm-js.sh` and the weekly sync workflow now take ergm-js from
  its npm package instead of GitHub tags.

## 0.1.0

- Initial release.
- `{{< ergm-widget >}}` shortcode for `html`, websites, books, and `revealjs`.
- Vendors ergm-js 0.2.1 (graphology 0.26.0, sigma 3.0.3) so the extension
  works offline and with `embed-resources: true`.
- Document-level `ergm-widget:` YAML defaults, merged under per-shortcode
  kwargs.
- Automatic light/dark theming via a luminance probe, overridable with
  `scheme=`.
- Non-HTML fallback (`fallback=note|none|image`) for PDF/docx/typst output.
