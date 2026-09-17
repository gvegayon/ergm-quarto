# Changelog

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
