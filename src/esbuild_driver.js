// ZSSG's bridge to esbuild for js.Build and css.Build. It mirrors Hugo's
// internal/js/esbuild options and resolver plugins (Hugo embeds esbuild as a
// Go library; ZSSG drives the same esbuild version through its npm package).
const fs = require('fs');
const path = require('path');
const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));

function out(o) { process.stdout.write(JSON.stringify(o)); }
function load(name) {
  const tries = [path.join(cfg.absWorkingDir, 'node_modules', name), name];
  for (const p of (process.env.NODE_PATH || '').split(path.delimiter)) if (p) tries.push(path.join(p, name));
  for (const p of ['/usr/local/lib/node_modules', '/usr/lib/node_modules', '/opt/homebrew/lib/node_modules',
    path.join(process.env.HOME || '', '.npm-global/lib/node_modules'), '/opt/npm-tools/node_modules']) tries.push(path.join(p, name));
  for (const t of tries) { try { return require(t); } catch (e) {} }
  return null;
}
const esbuild = load('esbuild');
if (!esbuild) { out({ noesbuild: true }); process.exit(0); }

const assets = cfg.assetsDirs;
function stat(rel) {
  for (const d of assets) {
    const p = path.join(d, rel);
    try { const st = fs.statSync(p); return { filename: p, isDir: st.isDirectory() }; } catch (e) {}
  }
  return null;
}
const commonExtensions = ['.js', '.ts', '.tsx', '.jsx'];
const cache = new Map();
function resolveComponent(imp, direct) {
  const key = (direct ? 'd:' : 'c:') + imp;
  if (cache.has(key)) return cache.get(key);
  let r = null;
  if (direct) {
    const s = stat(imp);
    r = s && !s.isDir ? s : null;
  } else {
    const findFirst = (base) => {
      for (const ext of commonExtensions) {
        if (imp.endsWith(ext)) continue;
        const s = stat(base + ext);
        if (s) return s;
      }
      return null;
    };
    r = findFirst(imp);
    const base = path.basename(imp);
    if (!r && base === 'index') r = findFirst(imp + '.esm');
    if (!r) {
      const s = stat(imp);
      if (s && s.isDir) r = findFirst(path.join(imp, 'index')) || findFirst(path.join(imp, 'index.esm'));
      else if (s) r = s;
    }
    if (!r && base.endsWith('.js')) r = findFirst(imp.slice(0, -3));
  }
  cache.set(key, r);
  return r;
}
function makePathRelative(filename) {
  for (const d of assets) {
    const dd = d.endsWith(path.sep) ? d : d + path.sep;
    if (filename.startsWith(dd)) return filename.slice(dd.length);
  }
  return null;
}
const extensionToLoaderMapJS = { '.js': 'js', '.mjs': 'js', '.cjs': 'js', '.jsx': 'jsx', '.ts': 'ts', '.tsx': 'tsx', '.json': 'json', '.txt': 'text', '.css': 'css' };
function loaderFromFilename(filename) {
  const ext = path.extname(filename);
  if (cfg.loader && cfg.loader[ext]) return cfg.loader[ext];
  if (!cfg.isCSS && extensionToLoaderMapJS[ext]) return extensionToLoaderMapJS[ext];
  return 'default';
}

const importResolver = {
  name: 'hugo-import-resolver',
  setup(build) {
    build.onResolve({ filter: /.*/ }, (args) => {
      let imp = args.path;
      const isCSSToken = args.kind === 'import-rule' || args.kind === 'url-token';
      let shimmed = false;
      if (cfg.shims && Object.prototype.hasOwnProperty.call(cfg.shims, imp)) { imp = cfg.shims[imp]; shimmed = true; }
      if ((cfg.external || []).includes(imp)) return { path: imp, external: true };
      const importer = args.importer;
      let relDir;
      if (importer !== '<stdin>') {
        const rel = makePathRelative(importer);
        if (rel === null) {
          if (shimmed) relDir = cfg.sourceDir; else return undefined;
        } else relDir = path.dirname(rel);
      } else relDir = cfg.sourceDir;
      const tries = [];
      if (relDir !== '') {
        if (imp.startsWith('.')) tries.push(path.join(relDir, imp));
        else if (isCSSToken && !imp.startsWith('/')) tries.push(path.join(relDir, imp), imp);
        else tries.push(imp);
      }
      for (const p of tries) {
        const m = resolveComponent(p, isCSSToken);
        if (m) return { path: m.filename, namespace: 'ns-hugo-imp' };
      }
      return undefined;
    });
    build.onLoad({ filter: /.*/, namespace: 'ns-hugo-imp' }, (args) => ({
      resolveDir: cfg.resolveDir,
      contents: fs.readFileSync(args.path, 'utf8'),
      loader: loaderFromFilename(args.path),
    }));
  },
};
const paramsPlugin = {
  name: 'hugo-params-plugin',
  setup(build) {
    build.onResolve({ filter: /^@params(\/config)?$/ }, (args) => ({
      path: args.path === '@params/config' ? '@params/config' : args.importer,
      namespace: 'ns-hugo-params',
    }));
    build.onLoad({ filter: /.*/, namespace: 'ns-hugo-params' }, () => ({ contents: cfg.params || '{}', loader: 'json' }));
  },
};
const varsPlugin = {
  name: 'hugo-vars-plugin',
  setup(build) {
    build.onResolve({ filter: /^hugo:vars(\/|$)/ }, (args) => ({ path: args.path, namespace: 'ns-hugo-vars' }));
    build.onLoad({ filter: /.*/, namespace: 'ns-hugo-vars' }, (args) => {
      let vars = cfg.vars || {};
      const sub = args.path.replace(/^hugo:vars\/?/, '');
      if (sub) vars = (vars[sub] && typeof vars[sub] === 'object') ? vars[sub] : {};
      const lines = [];
      for (const [k0, v] of Object.entries(vars)) {
        if (v !== null && typeof v === 'object') continue;
        const k = k0.startsWith('--') ? k0 : '--' + k0;
        lines.push(`  ${k}: ${v};`);
      }
      lines.sort();
      return { contents: lines.length ? ':root {\n' + lines.join('\n') + '\n}\n' : '', loader: 'css' };
    });
  },
};

const o = cfg.options;
o.bundle = true;
o.write = false;
o.logLevel = 'silent';
o.absWorkingDir = cfg.absWorkingDir;
o.outdir = cfg.outdir;
o.stdin = { contents: cfg.contents, resolveDir: cfg.resolveDir, loader: cfg.stdinLoader };
o.plugins = [importResolver, paramsPlugin, varsPlugin];
if (cfg.loader) o.loader = cfg.loader;

esbuild.build(o).then((result) => {
  out({ files: result.outputFiles.map((f) => ({ path: f.path, contents: Buffer.from(f.contents).toString('base64') })) });
}).catch((e) => {
  const errs = (e.errors || []).map((m) => {
    let file = m.location ? m.location.file : '';
    for (const ns of ['ns-hugo-imp:', 'ns-hugo-imp-func:', 'ns-hugo-params:', 'ns-hugo-vars:']) {
      if (file.startsWith(ns)) file = file.slice(ns.length);
    }
    if (file === '<stdin>') file = cfg.stdinSourcePath;
    let text = m.text;
    for (const ns of ['ns-hugo-imp:', 'ns-hugo-imp-func:', 'ns-hugo-params:', 'ns-hugo-vars:']) text = text.split(ns).join('');
    return m.location ? `"${file}:${m.location.line}:${m.location.column + 1}": ${text}` : text;
  });
  out({ error: errs.length ? errs[0] : String(e && e.message || e), errors: errs });
});
