-- ergm-quarto.lua -- {{< ergm-widget >}}
--
-- Emits a <div> carrying a JSON options payload; resources/ergm-quarto.js
-- does the actual ERGMWidget.mount() call at DOMContentLoaded. We
-- deliberately do NOT emit a per-widget inline <script>: inside a reveal.js
-- slide such a script would run while `Reveal` is still undefined (reveal.js
-- itself loads at the end of <body>), which pushes ergm-widget.js's own
-- lazy-init logic down its IntersectionObserver fallback instead of its
-- (better) per-slide Reveal branch. See README.md "Why no inline script".

local ERGM_JS_VERSION = "0.2.1" -- vendored upstream version; tools/vendor-ergm-js.sh rewrites this line
local EXT_VERSION = "0.1.0" -- must equal _extension.yml `version`; tools/check-versions.sh enforces this

local DEP_NAME = "ergm-js"
local deps_done = false
local counter = 0

-- ---------------------------------------------------------------------------
-- string / value helpers
-- ---------------------------------------------------------------------------

-- Shortcode kwarg values arrive as plain Lua strings (Quarto's own LPEG
-- shortcode parser runs on raw source, not through Pandoc's markdown
-- reader), EXCEPT when a value came from document YAML metadata, where it
-- may already be a Lua boolean/number/table (see meta_to_lua below). Accept
-- both without assuming pandoc.utils.stringify handles a raw Lua value.
local function as_string(v)
  if v == nil then
    return nil
  elseif type(v) == "string" then
    return v
  elseif type(v) == "number" or type(v) == "boolean" then
    return tostring(v)
  else
    return pandoc.utils.stringify(v)
  end
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local TRUTHY = { ["true"] = true, ["yes"] = true, ["on"] = true, ["1"] = true }
local FALSY = { ["false"] = true, ["no"] = true, ["off"] = true, ["0"] = true }

local function as_bool(v, key)
  if type(v) == "boolean" then
    return v
  end
  local s = trim(as_string(v)):lower()
  if TRUTHY[s] then
    return true
  end
  if FALSY[s] then
    return false
  end
  return nil, ("`%s` expects true/false (also yes/no, on/off, 1/0); got %q"):format(key, as_string(v))
end

local function as_number(v, key, o)
  o = o or {}
  local x
  if type(v) == "number" then
    x = v
  else
    local t = trim(as_string(v))
    if o.px then
      t = t:gsub("[Pp][Xx]$", "")
    end
    x = tonumber(t)
  end
  if x == nil then
    return nil, ("`%s` expects a number; got %q"):format(key, as_string(v))
  end
  -- quarto.json.encode raises hard on NaN/inf, so reject them here with a
  -- useful message instead of failing deep inside the JSON encoder later.
  if x ~= x or x == math.huge or x == -math.huge then
    return nil, ("`%s` must be a finite number"):format(key)
  end
  if o.integer then
    if x ~= math.floor(x) then
      return nil, ("`%s` must be a whole number; got %q"):format(key, as_string(v))
    end
    x = math.tointeger(x) or x -- keeps json.lua's %.14g output as "40", not "40.0"
  end
  if o.min and x < o.min then
    return nil, ("`%s` must be >= %s"):format(key, o.min)
  end
  if o.max and x > o.max then
    return nil, ("`%s` must be <= %s"):format(key, o.max)
  end
  return x
end

-- "a, b ,c" -> {"a","b","c"}; "" -> {}; "a,,b" -> {"a","b"}
local function split_commas(s)
  local out = {}
  for piece in s:gmatch("[^,]+") do
    local p = trim(piece)
    if p ~= "" then
      out[#out + 1] = p
    end
  end
  return out
end

local MODEL_TERMS = { edges = true, nodematch = true, mutual = true }

local function as_model(v, key)
  local list
  if type(v) == "table" then
    list = v
  else
    list = split_commas(as_string(v))
  end
  local out = {}
  for _, term in ipairs(list) do
    local t = trim(as_string(term))
    if t ~= "" then
      if not MODEL_TERMS[t] then
        return nil, ("`%s` has unknown term %q (expected edges, nodematch, mutual)"):format(key, t)
      end
      out[#out + 1] = t
    end
  end
  return out -- may legitimately be {} -- an ERGM with no terms is valid upstream
end

-- Restricted to hex forms and bare CSS colour keywords -- deliberately, so
-- that no user-controlled byte outside [A-Za-z0-9#] can reach the HTML
-- attribute, and so a colour never contains the "," used to split lists.
local function as_color(v, key)
  local c = trim(as_string(v))
  if
    c:match("^#%x%x%x$")
    or c:match("^#%x%x%x%x$")
    or c:match("^#%x%x%x%x%x%x$")
    or c:match("^#%x%x%x%x%x%x%x%x$")
    or c:match("^%a[%a%d]*$")
  then
    return c
  end
  return nil, ("`%s` expects a hex colour (e.g. #00707a) or a CSS colour name; got %q"):format(key, c)
end

local function as_colors2(v, key)
  local list
  if type(v) == "table" then
    list = v
  else
    list = split_commas(as_string(v))
  end
  if #list ~= 2 then
    return nil, ("`%s` expects exactly two colours (got %d)"):format(key, #list)
  end
  local out = {}
  for i, c in ipairs(list) do
    local col, err = as_color(c, key)
    if err then
      return nil, err
    end
    out[i] = col
  end
  return out
end

local function as_enum(v, key, allowed)
  local s = trim(as_string(v))
  if not allowed[s] then
    local names = {}
    for name in pairs(allowed) do
      names[#names + 1] = name
    end
    table.sort(names)
    return nil, ("`%s` must be one of: %s; got %q"):format(key, table.concat(names, ", "), s)
  end
  return s
end

-- ---------------------------------------------------------------------------
-- the option spec -- single source of truth for kwargs, YAML defaults, and
-- (see reference.qmd) the documented option table
-- ---------------------------------------------------------------------------

-- path: where the value lands in the JS options object passed to mount().
-- soft: the widget's own slider range (TERM_CONTROLS / NETWORK_CONTROLS in
--   ergm-widget.js) -- a value outside it still simulates correctly, but the
--   visible <input type="range"> clamps, which looks like a bug, so it's a
--   warning, not an error.
local SPEC = {
  ["n"] = { path = { "n" }, kind = "int", min = 2, soft = { 20, 120 } },
  ["mean-degree"] = { path = { "meanDegree" }, kind = "number", min = 0, soft = { 1, 10 } },
  ["p-group"] = { path = { "pGroup" }, kind = "number", min = 0, max = 1 },
  ["seed"] = { path = { "seed" }, kind = "int" },
  ["steps-per-frame"] = { path = { "stepsPerFrame" }, kind = "int", min = 1, max = 100000 },
  ["height"] = { path = { "height" }, kind = "px", min = 40 },
  ["auto-start"] = { path = { "autoStart" }, kind = "bool" },
  ["layout"] = { path = { "layout" }, kind = "enum", enum = { force = true, circle = true } },
  ["model"] = { path = { "model" }, kind = "model" },
  ["theta-edges"] = { path = { "theta", "edges" }, kind = "number", soft = { -5, 1 } },
  ["theta-nodematch"] = { path = { "theta", "nodematch" }, kind = "number", soft = { -2, 4 } },
  ["theta-mutual"] = { path = { "theta", "mutual" }, kind = "number", soft = { -2, 4 } },
  ["controls-n"] = { path = { "controls", "n" }, kind = "bool" },
  ["controls-mean-degree"] = { path = { "controls", "meanDegree" }, kind = "bool" },
  ["group-colors"] = { path = { "groupColors" }, kind = "colors2" },
  ["edge-color-match"] = { path = { "edgeColorMatch" }, kind = "color" },
  ["edge-color-cross"] = { path = { "edgeColorCross" }, kind = "color" },
}

-- Presentation kwargs: consumed by the extension, never forwarded to mount().
-- `id` is deliberately absent from PRESENTATION's YAML-eligible set (see
-- read_doc_defaults) -- a document-wide id would duplicate on every widget.
local PRESENTATION = {
  id = true,
  class = true,
  width = true,
  scheme = true,
  fallback = true,
  ["fallback-text"] = true,
  ["fallback-image"] = true,
}

local function coerce(spec, v, key)
  if spec.kind == "int" then
    return as_number(v, key, { integer = true, min = spec.min, max = spec.max })
  elseif spec.kind == "number" then
    return as_number(v, key, { min = spec.min, max = spec.max })
  elseif spec.kind == "px" then
    return as_number(v, key, { integer = true, px = true, min = spec.min })
  elseif spec.kind == "bool" then
    return as_bool(v, key)
  elseif spec.kind == "enum" then
    return as_enum(v, key, spec.enum)
  elseif spec.kind == "model" then
    return as_model(v, key)
  elseif spec.kind == "color" then
    return as_color(v, key)
  elseif spec.kind == "colors2" then
    return as_colors2(v, key)
  end
  error("ergm-quarto: unknown SPEC kind " .. tostring(spec.kind))
end

local function soft_range_check(key, spec, value, warns)
  if spec.soft == nil or type(value) ~= "number" then
    return
  end
  local lo, hi = spec.soft[1], spec.soft[2]
  if value < lo or value > hi then
    local hint = ""
    if key == "n" or key == "mean-degree" then
      hint = (" Consider controls-%s=false to hide the slider."):format(key == "n" and "n" or "mean-degree")
    end
    warns[#warns + 1] = ("`%s` = %s is outside the slider range [%s, %s]; the on-screen input will show clamped.%s")
      :format(key, tostring(value), tostring(lo), tostring(hi), hint)
  end
end

-- Creates intermediate tables lazily, so `theta` / `controls` exist only
-- when at least one child key was actually supplied -- an empty Lua table
-- encodes to JSON as `[]`, never `{}` (json.lua's encode_table), so we must
-- never create a sub-table that ends up with nothing written into it.
local function set_path(t, path, value)
  local node = t
  for i = 1, #path - 1 do
    if node[path[i]] == nil then
      node[path[i]] = {}
    end
    node = node[path[i]]
  end
  node[path[#path]] = value
end

-- ---------------------------------------------------------------------------
-- document-level YAML defaults: an `ergm-widget:` block in the front matter
-- (or _quarto.yml) sets defaults for every widget on the page/project,
-- overridable per-shortcode. Computed once and memoised; every option is
-- still validated with the exact same coerce() as kwargs.
-- ---------------------------------------------------------------------------

-- Recursively converts a Pandoc MetaValue into a plain Lua value: booleans
-- stay booleans, Inlines/Blocks stringify, MetaList becomes an array (so
-- `model: [edges, mutual]` yields a real Lua array, not the mis-joined
-- string a bare stringify() would produce), MetaMap becomes a nested table.
local function meta_to_lua(mv)
  if mv == nil then
    return nil
  end
  local ty = pandoc.utils.type(mv)
  if ty == "boolean" then
    return mv
  elseif ty == "Inlines" or ty == "Blocks" then
    return pandoc.utils.stringify(mv)
  elseif ty == "List" then
    local out = {}
    for i, v in ipairs(mv) do
      out[i] = meta_to_lua(v)
    end
    return out
  elseif ty == "table" then -- MetaMap
    local out = {}
    for k, v in pairs(mv) do
      out[k] = meta_to_lua(v)
    end
    return out
  else
    return mv -- already a plain string/number
  end
end

-- true if every key of t is a positive integer 1..n with no gaps (i.e. t
-- came from a YAML sequence, not a mapping); an empty table counts as an
-- array so `model: []` round-trips correctly.
local function is_array(t)
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then
      return false
    end
  end
  return true
end

-- Flattens a nested map into SPEC's flat kebab keys, e.g.
-- { theta = { edges = -2.5 } } -> flat["theta-edges"] = -2.5. A key that is
-- already flat (the author wrote `theta-edges:` directly) is a no-op single
-- level. Arrays (model, group-colors) are leaves, never descended into.
local function flatten(node, prefix, out)
  if type(node) ~= "table" or is_array(node) then
    if prefix then
      out[prefix] = node
    end
    return
  end
  for k, v in pairs(node) do
    local key = prefix and (prefix .. "-" .. tostring(k)) or tostring(k)
    flatten(v, key, out)
  end
end

local doc_defaults_ready = false
local doc_defaults_pairs = {} -- list of { path = {...}, value = ... }, already coerced

local function read_doc_defaults(meta)
  if doc_defaults_ready then
    return doc_defaults_pairs
  end
  doc_defaults_ready = true
  if meta == nil then
    return doc_defaults_pairs
  end
  local block = meta["ergm-widget"]
  if block == nil then
    return doc_defaults_pairs
  end
  local flat = {}
  flatten(meta_to_lua(block), nil, flat)
  for key, raw in pairs(flat) do
    if key == "id" then
      quarto.log.warning("[ergm-widget] `id` is not valid in document-level `ergm-widget:` YAML (would duplicate on every widget) -- ignored")
    elseif PRESENTATION[key] then
      quarto.log.warning(("[ergm-widget] `%s` is a per-widget presentation option and is not read from document YAML -- ignored"):format(key))
    else
      local spec = SPEC[key]
      if spec == nil then
        quarto.log.warning(("[ergm-widget] unknown option `%s` in document-level `ergm-widget:` YAML -- ignored"):format(key))
      else
        local value, err = coerce(spec, raw, key)
        if err then
          quarto.log.warning("[ergm-widget] in document-level `ergm-widget:` YAML: " .. err .. " -- ignored")
        else
          local warns = {}
          soft_range_check(key, spec, value, warns)
          for _, w in ipairs(warns) do
            quarto.log.warning("[ergm-widget] in document-level `ergm-widget:` YAML: " .. w)
          end
          doc_defaults_pairs[#doc_defaults_pairs + 1] = { path = spec.path, value = value }
        end
      end
    end
  end
  return doc_defaults_pairs
end

-- ---------------------------------------------------------------------------
-- HTML dependency
-- ---------------------------------------------------------------------------

local function ensure_html_deps()
  if deps_done then
    return
  end
  deps_done = true
  quarto.doc.add_html_dependency({
    name = DEP_NAME,
    -- The EXTENSION's version, not ergm-js's: this string is the cache-bust
    -- key for site_libs/quarto-contrib/ergm-js-<version>/, and it must
    -- change whenever ANY shipped byte changes -- including our own
    -- ergm-quarto.js / .css, which evolve independently of upstream. The
    -- upstream version is recorded separately via `meta` below.
    version = EXT_VERSION,
    meta = { ["ergm-js-version"] = ERGM_JS_VERSION },
    -- ORDER IS LOAD-BEARING: graphology -> sigma -> ergm -> widget -> our
    -- bootstrap. Quarto preserves array order on injection and flattens
    -- every path to its basename in the output directory.
    scripts = {
      "resources/ergm-js/vendor/graphology.umd.min.js",
      "resources/ergm-js/vendor/sigma.min.js",
      "resources/ergm-js/src/ergm.js",
      "resources/ergm-js/src/ergm-widget.js",
      "resources/ergm-quarto.js",
    },
    stylesheets = { "resources/ergm-quarto.css" },
  })
end

-- ---------------------------------------------------------------------------
-- errors
-- ---------------------------------------------------------------------------

local function fail(msg, context)
  quarto.log.warning("[ergm-widget] " .. msg)
  if quarto.shortcode and quarto.shortcode.error_output then
    return quarto.shortcode.error_output("ergm-widget", msg, context or "block")
  end
  return pandoc.Blocks({
    pandoc.Para({ pandoc.Strong({ pandoc.Str("ergm-widget error:") }), pandoc.Space(), pandoc.Str(msg) }),
  })
end

-- ---------------------------------------------------------------------------
-- JSON payload
-- ---------------------------------------------------------------------------

-- quarto.json.encode (json.lua) escapes only control characters, `\` and
-- `"` -- it does NOT escape &, <, >, ' -- so escaping the encoded JSON for
-- safe placement inside an HTML attribute is entirely our job. Order
-- matters: `&` must run first, or the entities written by the later gsubs
-- get escaped a second time.
local function attr_escape(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("'", "&#39;")
  return s
end

-- ---------------------------------------------------------------------------
-- shortcode handler
-- ---------------------------------------------------------------------------

local function handler(args, kwargs, meta, raw_args, context)
  counter = counter + 1

  if #args > 0 then
    quarto.log.warning("[ergm-widget] this shortcode takes no positional arguments -- ignored")
  end

  -- Split kwargs into presentation vs widget-option keys, validating both,
  -- collecting errors so a user sees every problem at once rather than
  -- fixing one typo per render.
  local presentation = {}
  local kwarg_pairs = {}
  local errs, warns = {}, {}

  -- pairs(kwargs) yields ONLY what the author actually wrote (the metatable
  -- fallback for missing keys is only invoked on read-of-a-missing-key, not
  -- by pairs), which is exactly what lets us build a payload containing
  -- nothing but user-supplied options.
  for key, raw in pairs(kwargs) do
    local s = as_string(raw)
    if PRESENTATION[key] then
      presentation[key] = s
    else
      local spec = SPEC[key]
      if spec == nil then
        errs[#errs + 1] = ("unknown option `%s` (see the extension reference for the full list)"):format(key)
      else
        local value, err = coerce(spec, s, key)
        if err then
          errs[#errs + 1] = err
        else
          soft_range_check(key, spec, value, warns)
          kwarg_pairs[#kwarg_pairs + 1] = { path = spec.path, value = value }
        end
      end
    end
  end

  if presentation.id ~= nil and not presentation.id:match("^[A-Za-z][%w:_.-]*$") then
    errs[#errs + 1] = ("`id` must start with a letter and contain only letters, numbers, %-, _, :, . ; got %q"):format(presentation.id)
  end
  if presentation.class ~= nil then
    for cls in presentation.class:gmatch("%S+") do
      if not cls:match("^[%w_-]+$") then
        errs[#errs + 1] = ("`class` contains an invalid class name %q"):format(cls)
      end
    end
  end
  if presentation.width ~= nil and not presentation.width:match("^[%d.]+%a+$") and not presentation.width:match("^[%d.]+%%$") then
    errs[#errs + 1] = ("`width` expects a CSS length like 480px, 30em, or 100%%; got %q"):format(presentation.width)
  end
  if presentation.scheme ~= nil and presentation.scheme ~= "light" and presentation.scheme ~= "dark" and presentation.scheme ~= "auto" then
    errs[#errs + 1] = ("`scheme` must be light, dark, or auto; got %q"):format(presentation.scheme)
  end
  if presentation.fallback ~= nil and presentation.fallback ~= "note" and presentation.fallback ~= "none" and presentation.fallback ~= "image" then
    errs[#errs + 1] = ("`fallback` must be note, none, or image; got %q"):format(presentation.fallback)
  end
  if presentation.fallback == "image" and presentation["fallback-image"] == nil then
    errs[#errs + 1] = "`fallback=image` requires `fallback-image`"
  end

  for _, w in ipairs(warns) do
    quarto.log.warning("[ergm-widget] " .. w)
  end

  if #errs > 0 then
    return fail(table.concat(errs, "; "), context)
  end

  -- Non-HTML output: validate (above), then branch before touching any
  -- HTML-only machinery. A typo should fail `--to docx` too, not only the
  -- HTML render.
  if not quarto.doc.is_format("html:js") then
    local mode = presentation.fallback or "note"
    if mode == "none" then
      return pandoc.Blocks({})
    elseif mode == "image" then
      return pandoc.Blocks({
        pandoc.Para({ pandoc.Image({ pandoc.Str("Interactive ERGM network simulation") }, presentation["fallback-image"]) }),
      })
    else
      local text = presentation["fallback-text"] or "Interactive ERGM simulation \226\128\148 available in the HTML version."
      return pandoc.Blocks({ pandoc.Para({ pandoc.Emph({ pandoc.Str(text) }) }) })
    end
  end

  ensure_html_deps()

  -- Merge document-level YAML defaults, then this shortcode's own kwargs,
  -- leaf by leaf (not whole-subtree), so a document default of
  -- theta.mutual survives a per-widget theta-edges override.
  local opts = {}
  for _, item in ipairs(read_doc_defaults(meta)) do
    set_path(opts, item.path, item.value)
  end
  for _, item in ipairs(kwarg_pairs) do
    set_path(opts, item.path, item.value)
  end

  local json = nil
  if next(opts) ~= nil then
    -- model = {} is legitimate (an ERGM with no terms) and correctly
    -- encodes as "[]" -- do not special-case it away.
    json = quarto.json.encode(opts)
  end

  local id = presentation.id or ("ergm-widget-" .. tostring(counter))
  local classes = "ergm-widget ergm-quarto"
  if presentation.class then
    classes = classes .. " " .. presentation.class
  end

  local styles = {}
  if presentation.width then
    styles[#styles + 1] = "max-width:" .. presentation.width
  end
  if opts.height then
    styles[#styles + 1] = "--ergm-min-height:" .. tostring(opts.height) .. "px"
  end

  local parts = {
    '<div class="',
    attr_escape(classes),
    '" id="',
    attr_escape(id),
    '" role="group" aria-label="Interactive ERGM network simulation"',
  }
  if #styles > 0 then
    parts[#parts + 1] = ' style="' .. attr_escape(table.concat(styles, ";")) .. '"'
  end
  if presentation.scheme == "light" or presentation.scheme == "dark" then
    parts[#parts + 1] = ' data-ergm-scheme="' .. presentation.scheme .. '"'
  end
  if json then
    parts[#parts + 1] = ' data-ergm-options="' .. attr_escape(json) .. '"'
  end
  parts[#parts + 1] = "></div>"

  -- A RawBlock, not a RawInline: an inline result would be wrapped in a
  -- <p>, putting a block-level flex container inside a paragraph.
  return pandoc.Blocks({ pandoc.RawBlock("html", table.concat(parts)) })
end

return { ["ergm-widget"] = handler }
