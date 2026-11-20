<p align="center">
  <img src="brand/zssg-logo-dark.svg?raw=true" alt="ZSSG" width="600">
</p>

A static site generator written in Zig that builds Hugo sites: the same project
layout, the same config files, the same Go template language and function
names, and unmodified Hugo themes.

ZSSG targets the behaviour of **Hugo v0.170.0** and compiles with
**Zig 0.16.x and 0.17.x**. Apart from the Zig standard library it embeds one
thing, the AVIF codec Hugo itself embeds (libavif with dav1d, libaom and
libyuv, in `vendor/`, compiled from C by `zig build`); like Hugo, some other
features call external tools (see below).

```
zssg                         # build ./ into ./public
zssg server                  # build, serve on http://localhost:1313, rebuild + reload on change
zssg new site mysite         # scaffold a project
zssg new content posts/a.md  # create a content file
zssg version
```

## Building

The AVIF codecs are in a separate repository, `zssg-vendor`, checked out as
the `vendor/` submodule:

```
git clone --recursive <zssg repo URL>           # or, in an existing clone:
git submodule update --init
```

```
zig build -Doptimize=ReleaseFast      # binary in zig-out/bin/zssg
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl   # fully static binary
zig build -Davif=false                # pure Zig, AVIF through external tools
zig build test                        # unit tests
tests/compare.sh                      # diff ZSSG against Hugo (needs hugo 0.170.0 on PATH)
```

The first build compiles the AVIF libraries (a few minutes; later builds reuse
Zig's cache). They are built exactly as Hugo builds its WebAssembly codec:
libavif 1.4.2, dav1d 1.5.4 (decoding), libaom 3.15.2 (encoding) and libyuv,
plain C code paths, one thread, no floating-point contraction. That makes
ZSSG's AVIF files byte-for-byte identical to Hugo's, 10-bit HDR images
included. `tools/vendor_avif.py` regenerates `vendor/` from the upstream
sources.

## Using a Hugo theme

Exactly as with Hugo: put the theme in `themes/<name>` and set
`theme = "<name>"` in `hugo.toml` (or pass `-t <name>`). Theme config, layouts,
assets, static files, data and i18n bundles are merged underneath the project,
project files winning.

## How compatible is it?

Compatibility was measured by building the same sites with Hugo v0.170.0 and
ZSSG and diffing the output trees.

| Site | Result |
|------|--------|
| `tests/sites/functions` (about 200 template function calls, collections, escaping contexts) | byte-identical |
| `tests/sites/markdown` (CommonMark + Goldmark extensions, TOC, summaries) | byte-identical |
| `tests/sites/multilingual` (translation by file name, per-language config, menus, i18n) | byte-identical |
| PaperMod theme, test content (also with `--minify`) | identical, including esbuild-built and minified asset fingerprints |
| Ananke theme, test content (also with `--minify`) | identical, including the `css.Build` stylesheet |
| Bear Blog theme, its example site | identical |
| hugo-book theme, its multilingual example site (3 languages, SCSS, KaTeX, Mermaid) | 51 of 52 minified pages identical; the rest differ in the service-worker asset list and one KaTeX page |
| Chroma test corpus (175 lexers) and all 74 styles | byte-identical highlighting and `gen chromastyles` |
| tdewolff/minify: 4,000+ JS files, 810 JS test cases, 1,400+ SVG, 800 XML, 400 CSS files | byte-identical to Hugo's minifier |

"Identical" ignores the `<meta name="generator">` tag, which says ZSSG.

### Implemented

- Config: `hugo.toml/yaml/json`, legacy `config.*`, `config/_default` and
  per-environment directories; theme config as defaults.
- Content: Markdown and HTML, TOML/YAML/JSON front matter, page bundles and
  page resources, sections, drafts/future/expired, `cascade`, aliases,
  permalinks patterns, `url`/`slug`, manual and automatic summaries.
- Taxonomies and terms, menus (config and front matter), pagination,
  prev/next, related content.
- Templates: the Go template language (pipelines, variables, `range`/`with`/
  `if`, `define`/`block`/`template`, `break`/`continue`, `return`, `try`),
  `baseof`, partials (including inline and cached), shortcodes, render hooks
  (link, image, heading, codeblock, blockquote), both the Hugo 0.146+ layout
  tree and the legacy `_default`/`partials`/`shortcodes` names.
- html/template style contextual auto-escaping for HTML text, attributes, URLs,
  `<script>`, `<style>` and JSON-LD, including comment stripping.
- About 300 template functions and aliases across `collections`, `compare`,
  `strings`, `math`, `time`, `urls`, `path`, `transform`, `encoding`, `crypto`,
  `hash`, `lang`, `os`, `safe`, `inflect`, `partials`, `templates`,
  `resources`, `css`, `js`, `fmt`, `debug`.
- Output formats: HTML, RSS, JSON, sitemap, robots.txt, 404, custom formats.
  Hugo's own embedded templates (RSS, sitemap, Open Graph, Twitter cards,
  schema, pagination, `figure`, `youtube`, `vimeo`, `details`, ...) are compiled
  in unmodified, see `src/embedded/README.md`.
- Assets: `resources.Get/Match/Concat/FromString/ExecuteAsTemplate/GetRemote`,
  `fingerprint` (SRI), `minify` and `--minify` (ports of tdewolff/minify for
  HTML, CSS, JS, JSON, SVG and XML, matching Hugo byte for byte), `css.Sass`
  through Dart Sass, `js.Build`/`css.Build` through esbuild, `css.PostCSS`,
  `css.TailwindCSS` and `js.Babel` through their CLIs (as Hugo does).
- Images: decode PNG, JPEG, GIF, WebP (lossy and lossless) and AVIF; `.Resize`,
  `.Fit`, `.Fill` (including smart crop), `.Crop`, `.Process`, `.Filter`,
  `.FrameCount`, encode PNG/JPEG/WebP/AVIF. Resampling is a port of gift and
  JPEG coding a port of Go 1.27's `image/jpeg`, so resized PNG and JPEG output
  matches Hugo pixel for pixel (JPEG files byte for byte), indexed PNGs keep
  their palette (Floyd–Steinberg, as Hugo does). `reflect.IsImageResource*`,
  `reflect.IsResource`/`IsPage`/`IsSite`. JPEG XL and other image types that
  Hugo cannot process are recognised and rejected the same way.
- Page bundles: front matter `resources` (`name`, `title`, `params`,
  `:counter`), files in sub-folders of branch bundles, `build.publishResources`
  (resources of headless and unrendered bundles are published, as in Hugo).
- Syntax highlighting: a port of Chroma v2.27 (all lexers and styles, line
  numbers, `hl_lines`, anchors, classes or inline styles).
- `transform.ToMath` through KaTeX; Markdown passthrough extension with
  `render-passthrough` hooks; `templates.Defer`.
- Git info (`enableGitInfo`, `.GitInfo`, `:git` dates), front matter date
  configuration, locale-aware `time.Format` month/day names (CLDR).
- AsciiDoc (asciidoctor), Pandoc, reStructuredText (rst2html) content; Org via
  pandoc.
- Hugo Modules resolved and downloaded with the Go toolchain.
- Multilingual sites: translation by file name or by content directory,
  language prefixes, per-language config/menus/params, `i18n`, `.Translations`,
  `.Rotate`, sitemap index.
- Data files (TOML/YAML/JSON/CSV/XML) and `transform.Unmarshal`.

### Not implemented, or different from Hugo

These are the gaps to check before moving a real site over.

- **External tools.** Like Hugo, some features run other programs; ZSSG needs
  the same ones: Dart Sass (`sass`), Node.js with the `esbuild` package
  (`js.Build`, `css.Build`; esbuild 0.28.2 is the version Hugo 0.170.0
  embeds, so outputs match), the `katex` package (`transform.ToMath`; Hugo
  embeds KaTeX), `postcss`/`tailwindcss`/`babel` CLIs, `asciidoctor`, `pandoc`,
  `rst2html`, `go` (modules) and `curl` (`resources.GetRemote`). Only a
  `-Davif=false` build needs a tool for AVIF pixels: the first of
  `avifdec`/`avifenc`, Python Pillow, ImageMagick, `vips` or `ffmpeg` found on
  the PATH. When one is
  missing ZSSG says so; `js.Build`/`css.Build` and `ToMath` fall back to
  publishing the source unbundled / the TeX source with a warning.
  `security.exec.allow` and `security.http` are enforced as in Hugo.
- **Org** content is converted with pandoc, not go-org, so its HTML differs.
- **AsciiDoc** output is not re-serialised through an HTML5 parser as Hugo
  does, so attribute quoting can differ in places.
- **Image file names** use ZSSG's own hash, so processed image URLs differ from
  Hugo's. JPEG and AVIF files are byte-identical to Hugo's; PNG pixels match
  (the zlib compression differs); WebP and GIF are written by other encoders
  than Hugo's (libwebp, Go's gif), so those bytes differ.
- **Remote resources** are cached for the build only (Hugo also keeps a file
  cache), and their file names use ZSSG's own hash.
- **Hugo Modules**: `module.mounts`, `hugo mod` subcommands, replacements and
  vendoring commands are not implemented; imports are resolved with `go`.
- `js.Batch` and content adapters (`_content.gotmpl`) are not implemented.
- **Markdown.** The extras extension is not implemented; `emojify` is a no-op.
- **Cascade targets**, taxonomy term weights, segments, multihost, and the
  version and role dimensions are not implemented.
- **`.Date.Month`** yields the month name, not a `time.Month` usable as an int.
- **Sorting** by title folds case and common Latin accents; it is not full
  locale collation.
- **`zssg server`** rebuilds the whole site in a child process when a source
  file changes (checked on each request) and reloads the browser by polling.

`hugo.Version` reports `0.170.0` so that theme minimum-version checks pass;
`hugo.IsExtended` is `false`, as in Hugo 0.170.0 itself, which dropped the
separate extended edition.

## Source layout

| File | Purpose |
|------|---------|
| `src/main.zig` | command line |
| `src/site.zig` | config, themes, content loading, taxonomies, menus, layout lookup |
| `src/objs.zig` | Page/Site/Pager/Resource objects, shortcodes, render hooks, summaries |
| `src/tmpl.zig` | template parser, executor, contextual escaper |
| `src/funcs.zig` | template function library |
| `src/markdown.zig` | Markdown renderer |
| `src/highlight.zig` | Hugo's highlighting options, code blocks, `highlight` |
| `src/chroma.zig`, `src/chroma/` | port of Chroma: lexers (XML), styles, HTML formatter |
| `src/regex.zig` | RE2-syntax regular expressions (Go `regexp`) |
| `src/regex2.zig` | .NET-style regular expressions (Chroma lexers, as dlclark/regexp2) |
| `src/min*.zig`, `src/js_*.zig` | ports of tdewolff/minify and tdewolff/parse (HTML, CSS, JS, JSON, SVG, XML) |
| `src/image.zig`, `src/imgops.zig`, `src/webp*.zig`, `src/avif.zig` | image codecs, filters, smart crop |
| `src/giftx.zig` | port of gift's resampling, crops and pixel access (exact Hugo output) |
| `src/esbuild.zig`, `src/esbuild_driver.js` | `js.Build` / `css.Build` through esbuild |
| `src/locales_data.zig` | CLDR month/day names and date patterns |
| `src/data.zig` | TOML, YAML, JSON, CSV, XML |
| `src/time.zig` | dates and Go layout formatting |
| `src/builder.zig` | render and publish pipeline |
| `src/server.zig` | development server |
| `src/sys.zig` | every file system, process and clock call, in one place |
| `src/embedded/` | Hugo's embedded templates (Apache-2.0) |

`src/sys.zig` is the only file that touches `std.Io`, which is what keeps the
code building on both Zig 0.16 and 0.17.

Image operations run on a pool of worker threads (one per CPU) while pages
keep rendering; a processed image's size is known up front and its bytes are
waited for only when a template needs them. `ZSSG_IMAGE_WORKERS=n` sets the
pool size (`0` processes images in place).

Set `ZSSG_DEBUG=1` to print which layout (and baseof) each page is rendered with.

## Licence and credits

ZSSG is created by Riomoo/Alister [alister at kamikishi dot net] and licensed
under **+THYME** (Terms for Handing Your Modifications to Everyone); see
`LICENSE`. In short: you may use, modify and distribute ZSSG; files you modify
stay under +THYME with their source published; sites you build with ZSSG are
yours, with no obligations as long as ZSSG itself is unmodified.

ZSSG translates or includes code from Hugo (Apache-2.0), Go (BSD-3-Clause),
goldmark, tdewolff/minify and tdewolff/parse, Chroma, regexp2, gift and
smartcrop (MIT), Unicode CLDR data (Unicode-3.0) and the VP8 tables of
RFC 6386 (BSD-3-Clause), and bundles libavif, libaom, dav1d (BSD-2-Clause)
and libyuv (BSD-3-Clause). `NOTICE` lists each one, its copyright and where
its licence text is (`licenses/` and `vendor/*/`); each derived source file
names its origin in its header. Binary releases ship with `LICENSE`, `NOTICE`
and those licence files.
