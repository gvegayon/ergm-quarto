/*!
 * ergm-quarto.js -- mounts every {{< ergm-widget >}} div emitted by
 * ergm-quarto.lua, once ERGM / ERGMWidget / Sigma / graphology (loaded just
 * before this file, in that order) are all globals.
 *
 * Deliberately does nothing at parse time: mounting happens at
 * DOMContentLoaded, which in a rendered reveal.js deck runs AFTER
 * Reveal.initialize() (both are end-of-body, parser-blocking scripts). That
 * ordering is what lets ergm-widget.js's own lazy-init logic detect
 * `window.Reveal` and take its per-slide show/hide branch instead of
 * falling through to a plain IntersectionObserver, which is what a
 * per-widget inline <script> emitted mid-parse would have caused instead.
 * See the extension README, "Why no inline script".
 */
(function () {
  "use strict";

  // Guards against the dependency being injected twice (e.g. a nested
  // embed of one Quarto doc into another).
  if (window.ERGMQuarto && window.ERGMQuarto.__loaded) {
    return;
  }

  var SELECTOR = ".ergm-quarto:not([data-ergm-mounted])";
  var instances = [];

  function log(msg) {
    if (window.console && console.error) {
      console.error("[ergm-quarto] " + msg);
    }
  }

  function showError(el, msg) {
    el.textContent = msg;
    el.classList.add("ergm-quarto-error");
    el.setAttribute("data-ergm-mounted", "error");
    log(msg);
  }

  function parseOptions(el) {
    var raw = el.getAttribute("data-ergm-options");
    if (!raw) {
      return {};
    }
    var o;
    try {
      o = JSON.parse(raw);
    } catch (e) {
      showError(el, "could not parse data-ergm-options: " + e.message);
      return null;
    }
    // Defensive: an empty Lua table would encode as "[]" (the Lua side
    // never emits the attribute in that case, but a hand-written div
    // might), and Array-shaped opts would silently fall through to
    // ERGMWidget.DEFAULTS with no explanation.
    if (o === null || typeof o !== "object" || Array.isArray(o)) {
      return {};
    }
    return o;
  }

  // ---------------------------------------------------------------------
  // theming: CSS cannot reach the sigma <canvas> -- node/edge colours are
  // JS options baked into graphology attributes at Widget's _reset(). So
  // we read the resolved custom properties off the element and fill them
  // in ONLY for keys the author did not already set in data-ergm-options.
  // ---------------------------------------------------------------------

  function cssColor(cs, name) {
    var v = cs.getPropertyValue(name);
    v = v && v.trim();
    return v || null;
  }

  function applyThemeDefaults(el, opts) {
    var cs = getComputedStyle(el);
    if (!("groupColors" in opts)) {
      var a = cssColor(cs, "--ergm-group-1");
      var b = cssColor(cs, "--ergm-group-2");
      if (a && b) {
        opts.groupColors = [a, b];
      }
    }
    if (!("edgeColorMatch" in opts)) {
      var m = cssColor(cs, "--ergm-edge-match");
      if (m) {
        opts.edgeColorMatch = m;
      }
    }
    if (!("edgeColorCross" in opts)) {
      var x = cssColor(cs, "--ergm-edge-cross");
      if (x) {
        opts.edgeColorCross = x;
      }
    }
  }

  // Walks up from `el` looking for the first non-transparent background and
  // computes its WCAG relative luminance. Deliberately NOT based on
  // prefers-color-scheme: a single-theme (light or dark) Quarto page viewed
  // by a user whose OS is set to the opposite mode would otherwise get a
  // widget that clashes with the page it's embedded in. An author override
  // via `scheme=` always wins.
  function resolveScheme(el) {
    var forced = el.getAttribute("data-ergm-scheme");
    if (forced === "light" || forced === "dark") {
      return forced;
    }
    for (var node = el; node && node.nodeType === 1; node = node.parentElement) {
      var bg = getComputedStyle(node).backgroundColor;
      if (!bg || bg === "transparent") {
        continue;
      }
      var m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+))?/.exec(bg);
      if (!m) {
        continue;
      }
      if (m[4] !== undefined && parseFloat(m[4]) < 0.1) {
        continue; // effectively transparent
      }
      var lin = function (c) {
        c /= 255;
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      };
      var L = 0.2126 * lin(+m[1]) + 0.7152 * lin(+m[2]) + 0.0722 * lin(+m[3]);
      return L < 0.4 ? "dark" : "light";
    }
    return "light";
  }

  function mountOne(el) {
    if (el.getAttribute("data-ergm-mounted")) {
      return null;
    }

    var missing = [];
    if (typeof graphology === "undefined") missing.push("graphology");
    if (typeof Sigma === "undefined") missing.push("Sigma");
    if (typeof ERGM === "undefined") missing.push("ERGM");
    if (typeof ERGMWidget === "undefined") missing.push("ERGMWidget");
    if (missing.length) {
      // Do NOT call mount() here: it would immediately wipe this message
      // (Widget._buildDOM does el.innerHTML = "").
      showError(el, "ergm-quarto: missing global(s): " + missing.join(", ") + " -- the extension's scripts did not load.");
      return null;
    }

    var opts = parseOptions(el);
    if (opts === null) {
      return null; // parseOptions already called showError
    }

    el.setAttribute("data-ergm-scheme", resolveScheme(el));
    applyThemeDefaults(el, opts);

    // Set BEFORE mount(): mount() can throw (e.g. an invalid model array
    // slipping past Lua-side validation via a hand-written div), and a
    // throwing mount must not be retried by a later mountAll() pass --
    // that would leave two IntersectionObservers / rAF loops racing against
    // the same (now partially built) DOM, and ergm-js has no destroy().
    el.setAttribute("data-ergm-mounted", "true");

    var widget;
    try {
      widget = ERGMWidget.mount(el, opts);
    } catch (e) {
      el.setAttribute("data-ergm-mounted", "error");
      showError(el, "ergm-quarto: mount() failed: " + (e && e.message ? e.message : e));
      return null;
    }

    var rec = { el: el, widget: widget };
    instances.push(rec);
    return widget;
  }

  function mountAll(root) {
    var scope = root || document;
    var nodes = scope.querySelectorAll(SELECTOR);
    for (var i = 0; i < nodes.length; i++) {
      mountOne(nodes[i]);
    }
    return instances;
  }

  // ?print-pdf: reveal.js reports a single "current" slide, so the
  // widget's own Reveal branch hides every widget that isn't on it. Force
  // them all visible once reveal is ready. Best-effort: pokes a private
  // widget method, guarded by typeof checks, and never throws.
  function forceShowForPrint() {
    if (!/(^|[?&])print-pdf($|[=&])/.test(window.location.search)) {
      return;
    }
    instances.forEach(function (rec) {
      var w = rec.widget;
      try {
        if (!w || typeof w._ensureRenderer !== "function") {
          return;
        }
        w._visible = true;
        w._ensureRenderer();
        if (w.renderer) {
          w.renderer.refresh();
        }
      } catch (e) {
        /* best effort */
      }
    });
  }

  function start() {
    mountAll(document);
    if (typeof Reveal !== "undefined" && Reveal && typeof Reveal.on === "function") {
      Reveal.on("ready", forceShowForPrint);
      forceShowForPrint();
    }
  }

  // Assigned before the readyState branch: a synchronous start() (the
  // already-interactive/complete path, e.g. `quarto preview` live reload)
  // must not run while window.ERGMQuarto is still undefined.
  window.ERGMQuarto = {
    __loaded: true,
    version: "0.1.0",
    mount: mountOne,
    mountAll: mountAll,
    instances: instances,
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
