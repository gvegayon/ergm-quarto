# ergm-quarto

A [Quarto](https://quarto.org) extension that embeds the
[`ergm-js`](https://github.com/gvegayon/ergm-js) interactive
Exponential Random Graph Model (ERGM) simulator in any HTML-based Quarto
output -- `html` documents, websites, books, and `revealjs` decks.

**[Live demo and full docs →](https://gvegayon.github.io/ergm-quarto/)**

## Install

```bash
quarto add gvegayon/ergm-quarto
```

This installs the extension under `_extensions/gvegayon/ergm-quarto/` in
your project. To use it, add the shortcode anywhere in a `.qmd`:

```markdown
{{< ergm-widget n=60 theta-nodematch=2 height=420 >}}
```

See the [full reference](https://gvegayon.github.io/ergm-quarto/reference.html)
for every option, and the [gallery](https://gvegayon.github.io/ergm-quarto/gallery.html)
and [revealjs demo](https://gvegayon.github.io/ergm-quarto/slides.html) for
worked examples.

## Document-level defaults

```yaml
---
ergm-widget:
  height: 420
  layout: circle
---
```

Sets defaults for every widget on the page; a shortcode's own kwargs still
override them.

## Why no inline `<script>`?

The obvious implementation -- a `<div>` plus an inline
`ERGMWidget.mount(...)` script next to it -- breaks inside reveal.js, because
reveal.js itself loads at the *end* of `<body>`, after all slide markup. An
inline script sitting inside a slide would run while `window.Reveal` is
still undefined, sending `ergm-widget.js`'s own lazy-init logic down its
`IntersectionObserver` fallback instead of its per-slide `Reveal` branch --
the wrong behavior inside a deck, where every slide is already in the DOM.

Instead, this extension emits only a `<div>` carrying a JSON options
payload, and ships a small bootstrap script that mounts every such div at
`DOMContentLoaded` -- by which point `Reveal.initialize()` has already run,
so `ergm-widget.js` takes the correct branch. Full reasoning in
[`ergm-quarto.lua`](_extensions/ergm-quarto/ergm-quarto.lua)'s header
comment and in the [docs](https://gvegayon.github.io/ergm-quarto/).

## Known limitations

- Live theme toggling re-themes the widget's chrome but not the graph's
  node/edge colors (baked in at mount time).
- Colors accept hex forms or bare CSS keywords, not `rgb(...)`/`hsl(...)`.
- A value outside a slider's documented range still simulates correctly,
  but the on-screen slider will show clamped (a render-time warning flags
  this).

See [Theming](https://gvegayon.github.io/ergm-quarto/theming.html) and the
[docs home](https://gvegayon.github.io/ergm-quarto/) for more.

## Development

This repo's own `_quarto.yml` website consumes `_extensions/ergm-quarto/` in
place -- no install step needed to work on it.

```bash
quarto preview                    # the docs/demo site
tools/check-versions.sh           # version-consistency check
quarto render                     # render everything
python3 tools/check-render.py     # static assertions over the rendered output
```

To refresh the vendored `ergm-js` assets after an upstream release:

```bash
tools/vendor-ergm-js.sh v0.2.2
```

This prints a manual review checklist (upstream's `DEFAULTS` or injected
CSS may have changed in ways this extension needs to mirror) -- see
[`tools/vendor-ergm-js.sh`](tools/vendor-ergm-js.sh). A weekly
[GitHub Action](.github/workflows/sync-ergm-js.yml) runs this automatically
and opens a PR with the same checklist; it never auto-merges.

## License

MIT, see [LICENSE.md](LICENSE.md). Vendored `ergm-js`, `graphology`, and
`sigma.js` are each MIT-licensed; see
[`_extensions/ergm-quarto/resources/ergm-js/`](_extensions/ergm-quarto/resources/ergm-js/).
