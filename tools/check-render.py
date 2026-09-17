#!/usr/bin/env python3
"""Static assertions over the rendered _site/ output of this repo's own
website project. Run `quarto render` first, then:

    python3 tools/check-render.py

Each check function returns a list of failure strings (empty = pass).
"""
import html
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "_site"

EXPECTED_SCRIPT_SUFFIXES = [
    "graphology.umd.min.js",
    "sigma.min.js",
    "ergm.js",
    "ergm-widget.js",
    "ergm-quarto.js",
]


def read(path):
    return path.read_text(encoding="utf-8")


def check_script_order(html_path):
    text = read(html_path)
    found = re.findall(r"quarto-contrib/ergm-js-[^/\"]*/([A-Za-z0-9._-]+\.js)", text)
    if found != EXPECTED_SCRIPT_SUFFIXES:
        return [f"{html_path.name}: dependency script order is {found}, expected {EXPECTED_SCRIPT_SUFFIXES}"]
    return []


def check_stylesheet_and_meta(html_path):
    errs = []
    text = read(html_path)
    css_hits = re.findall(r"ergm-js-[^/\"]*/ergm-quarto\.css", text)
    if len(css_hits) != 1:
        errs.append(f"{html_path.name}: expected exactly 1 ergm-quarto.css link, found {len(css_hits)}")
    version_file = ROOT / "_extensions/ergm-quarto/resources/ergm-js/VERSION"
    expected_version = version_file.read_text().strip()
    meta = re.search(r'<meta name="ergm-js-version" content="([^"]*)"', text)
    if not meta:
        errs.append(f"{html_path.name}: missing <meta name=\"ergm-js-version\">")
    elif meta.group(1) != expected_version:
        errs.append(f"{html_path.name}: meta ergm-js-version={meta.group(1)!r}, expected {expected_version!r}")
    return errs


def check_no_inline_mount(html_path):
    text = read(html_path)
    # Strip embed-resources-inlined <script> bodies that ARE one of our
    # five dependency files (identified by a signature string unique to
    # each) before searching for a stray inline mount call.
    signatures = [
        "ERGMWidget.mount",  # appears inside ergm-quarto.js itself (the bootstrap's own call site)
    ]
    scripts = re.findall(r"<script(?:(?!</script>).)*</script>", text, re.S)
    offenders = []
    for s in scripts:
        if "ERGMWidget.mount" in s and "ERGMQuarto" not in s:
            offenders.append(s[:120])
    if offenders:
        return [f"{html_path.name}: found an inline ERGMWidget.mount() call outside the bootstrap: {offenders}"]
    return []


def check_reveal_ordering(html_path):
    text = read(html_path)
    lines = text.splitlines()

    def first_line(pattern):
        for i, line in enumerate(lines, start=1):
            if pattern in line:
                return i
        return None

    bootstrap_line = None
    for i, line in enumerate(lines, start=1):
        if re.search(r"quarto-contrib/ergm-js-[^/\"]*/ergm-quarto\.js", line):
            bootstrap_line = i
            break
    last_options_line = None
    for i, line in enumerate(lines, start=1):
        if "data-ergm-options" in line or 'class="ergm-widget' in line:
            last_options_line = i
    reveal_js_line = first_line("dist/reveal.js")
    reveal_init_line = first_line("Reveal.initialize")

    errs = []
    if None in (bootstrap_line, reveal_js_line, reveal_init_line):
        return []  # not a revealjs doc, or nothing to check
    if not (bootstrap_line < reveal_js_line):
        errs.append(f"{html_path.name}: bootstrap script (line {bootstrap_line}) is not before reveal.js (line {reveal_js_line})")
    if last_options_line and not (last_options_line < reveal_js_line):
        errs.append(f"{html_path.name}: last widget div (line {last_options_line}) is not before reveal.js (line {reveal_js_line})")
    if not (reveal_js_line < reveal_init_line):
        errs.append(f"{html_path.name}: reveal.js (line {reveal_js_line}) is not before Reveal.initialize (line {reveal_init_line})")
    return errs


def check_embed_resources(html_path):
    text = read(html_path)
    errs = []
    if re.search(r"site_libs|_files/libs", text):
        errs.append(f"{html_path.name}: found site_libs/_files reference in an embed-resources build")
    if "graphology" not in text:
        errs.append(f"{html_path.name}: expected inlined 'graphology' text, found none")
    div_count = len(re.findall(r'<div class="ergm-widget ergm-quarto"', text))
    if div_count < 1:
        errs.append(f"{html_path.name}: expected at least 1 widget div, found {div_count}")
    return errs


def check_edge_cases(html_path):
    text = read(html_path)
    errs = []

    def payload_for(marker_id_prefix, must_equal=None, must_be_absent_near=None):
        return None

    # 1. the very first widget (no kwargs) must carry no data-ergm-options.
    m = re.search(r'<div class="ergm-widget ergm-quarto" id="ergm-widget-1"[^>]*>', text)
    if not m or "data-ergm-options" in m.group(0):
        errs.append("edge-cases.html: widget #1 (no kwargs) unexpectedly has data-ergm-options")

    expectations = {
        "ergm-widget-2": {"model": []},
        "ergm-widget-3": {"theta": {"edges": -2.5}},
        "ergm-widget-4": {"n": 40},
        "ergm-widget-5": {"groupColors": ["#00707a", "#c0491f"]},
    }
    for widget_id, expected in expectations.items():
        m = re.search(rf'<div class="ergm-widget ergm-quarto" id="{widget_id}"[^>]*data-ergm-options="([^"]*)"', text)
        if not m:
            errs.append(f"edge-cases.html: widget #{widget_id} missing data-ergm-options")
            continue
        raw = html.unescape(m.group(1))
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as e:
            errs.append(f"edge-cases.html: widget #{widget_id} data-ergm-options did not parse as JSON: {e}")
            continue
        if payload != expected:
            errs.append(f"edge-cases.html: widget #{widget_id} payload {payload} != expected {expected}")

    if "&quot;" not in text:
        errs.append("edge-cases.html: expected at least one &quot;-escaped JSON attribute")

    return errs


def check_fallback_docx(docx_path):
    errs = []
    with zipfile.ZipFile(docx_path) as z:
        doc = z.read("word/document.xml").decode("utf-8")
    if "available in the HTML version" not in doc:
        errs.append("fallback.docx: default fallback note text not found")
    if "live version at the project website" not in doc:
        errs.append("fallback.docx: custom fallback-text not found")
    if "unknown option" not in doc:
        errs.append("fallback.docx: expected the validation error to still surface in docx output")
    return errs


def main():
    errs = []

    examples = SITE / "examples"
    if (SITE / "slides.html").exists():
        errs += check_script_order(SITE / "slides.html")
        errs += check_stylesheet_and_meta(SITE / "slides.html")
        errs += check_no_inline_mount(SITE / "slides.html")
        errs += check_reveal_ordering(SITE / "slides.html")
    if (examples / "edge-cases.html").exists():
        errs += check_edge_cases(examples / "edge-cases.html")
    if (examples / "embed-resources.html").exists():
        errs += check_embed_resources(examples / "embed-resources.html")
    if (examples / "fallback.docx").exists():
        errs += check_fallback_docx(examples / "fallback.docx")

    if not SITE.exists():
        print(f"error: {SITE} does not exist -- run `quarto render` first", file=sys.stderr)
        return 2

    if errs:
        print("FAILED:")
        for e in errs:
            print(f"  - {e}")
        return 1

    print("All render assertions passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
