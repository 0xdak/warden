#!/usr/bin/env python3
"""
Zero-dependency static site builder (Python 3.8+ standard library only). English only.

    python3 build.py          # writes ./dist
    python3 build.py --check  # build + verify internal links, #fragments, assets, and that the
                              # product name is never hard-coded in src/ or public/assets/

Template syntax used in src/:
    {{> partial}}        include src/partials/partial.html
    {{name}}             value from site.config.json (HTML-escaped); nested keys with dots: {{company.legalName}}
    {{page.key}}         value from the page's <!--page {...} --> header (trusted HTML)
    {{raw.key}}          generated HTML (plan cards, testimonials, JSON-LD offers...) (trusted)
    {{canonical}} {{year}} {{downloadUrl}} {{siteUrl}} {{xUrl}} {{pricing.headline}} ...  computed

Each page starts with a JSON header comment:
    <!--page {"slug": "changelog", "title": "...", "description": "..."} -->
Optional header keys: "bodyClass", "noindex": true.
"""
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path
from urllib.parse import quote

import blog

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
PUBLIC = ROOT / "public"
DIST = ROOT / "dist"

cfg = json.loads((ROOT / "site.config.json").read_text(encoding="utf-8"))

# ---------------------------------------------------------------- derived config
cfg.setdefault("siteUrl", f"https://{cfg['domain']}")
cfg["siteUrl"] = cfg["siteUrl"].rstrip("/")
cfg.setdefault("downloadUrl", f"/download/{cfg['name']}.dmg")
cfg["xUrl"] = f"https://x.com/{cfg['xHandle']}"
cfg["repoUrl"] = cfg["repoUrl"].rstrip("/")
cfg["releasesUrl"] = cfg["repoUrl"] + "/releases/latest"
cfg["issuesUrl"] = cfg["repoUrl"] + "/issues"
cfg["securityUrl"] = cfg["repoUrl"] + "/security/advisories/new"
cfg["year"] = str(date.today().year)

TOKEN = re.compile(r"\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}")
PARTIAL = re.compile(r"\{\{>\s*([a-zA-Z0-9_-]+)\s*\}\}")
PAGE_HEADER = re.compile(r"\A\s*<!--page\s+(\{.*?\})\s*-->\s*", re.S)


def lookup(ctx, key):
    cur = ctx
    for part in key.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
            cur = cur[int(part)]
        else:
            raise KeyError(key)
    if isinstance(cur, (dict, list)):
        raise KeyError(f"{key} is not a scalar")
    return str(cur)


def render(text, ctx, where):
    for _ in range(5):  # partials (recursive)
        new = PARTIAL.sub(lambda m: (SRC / "partials" / f"{m.group(1)}.html").read_text(encoding="utf-8"), text)
        if new == text:
            break
        text = new

    def sub(m):
        key = m.group(1)
        try:
            val = lookup(ctx, key)
        except KeyError as e:
            sys.exit(f"[build] unknown token {{{{{key}}}}} in {where} ({e})")
        trusted = key.startswith(("page.", "raw."))
        return val if trusted else html.escape(val, quote=True)

    for _ in range(4):  # several passes so tokens inside config values (e.g. {{name}}) resolve too
        new = TOKEN.sub(sub, text)
        if new == text:
            break
        text = new
    return text


def tok(s):
    """Resolve {{tokens}} inside a config string (no escaping; caller escapes)."""
    for _ in range(3):
        s = TOKEN.sub(lambda m: lookup(cfg, m.group(1)), s)
    return s


# ---------------------------------------------------------------- pricing (config-driven)
CHECK = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>'


def plan_href(plan):
    cta = plan.get("cta") or {}
    t = cta.get("type")
    if t == "download":
        return cfg["downloadUrl"], " download"
    if t == "mailto":
        subj = quote(tok(cta.get("subject", "")))
        return f"mailto:{cfg['contactEmail']}" + (f"?subject={subj}" if subj else ""), ""
    if t == "link":
        return cta["href"], ""
    sys.exit(f"[build] plan {plan.get('id')}: unknown cta.type {t!r}")


def pricing_html():
    p = cfg["pricing"]
    esc = html.escape
    cards, offers = [], []
    for plan in p["plans"]:
        avail = plan.get("available", False)
        href, extra = plan_href(plan)
        label = esc(tok(plan["cta"]["label"]))
        cls = "plan" + (" is-featured" if plan.get("featured") else "") + ("" if avail else " is-soon")
        badge = f'<span class="plan-badge">{esc(plan["badge"])}</span>' if plan.get("badge") else ""
        btn_cls = "btn btn-primary" if avail else "btn btn-ghost"
        feats = "".join(f"<li>{CHECK}<span>{esc(tok(f))}</span></li>" for f in plan.get("features", []))
        price_cls = "plan-price" + (" is-tbd" if not re.search(r"\d", plan["price"]) else "")
        cards.append(
            f'<article class="{cls}" aria-labelledby="plan-{plan["id"]}">'
            f'<header><h3 id="plan-{plan["id"]}">{esc(plan["name"])}</h3>{badge}</header>'
            f'<p class="{price_cls}">{esc(plan["price"])}<span>{esc(tok(plan.get("period", "")))}</span></p>'
            f'<p class="plan-blurb">{esc(tok(plan.get("blurb", "")))}</p>'
            f'<ul class="plan-features">{feats}</ul>'
            f'<a class="{btn_cls}" href="{esc(href)}"{extra}>{label}</a>'
            f'</article>')
        if avail and isinstance(plan.get("amount"), (int, float)):
            offers.append({"@type": "Offer", "name": plan["name"], "price": str(plan["amount"]), "priceCurrency": "USD"})
    return {
        "planCards": f'<div class="plans">{"".join(cards)}</div>',
        "offers": json.dumps(offers or [{"@type": "Offer", "price": "0", "priceCurrency": "USD"}], separators=(",", ":")),
    }


def testimonials_html():
    items = (cfg.get("testimonials") or {}).get("items") or []
    esc = html.escape
    if not items:
        return ('<div class="invite"><p class="invite-lede">No quotes here yet, on purpose. {{name}} is new, '
                'and we’d rather show an empty wall than invented praise.</p>'
                '<p>If it catches something for you, or gets in your way, '
                '<a href="{{issuesUrl}}" rel="noopener">open an issue on GitHub</a> or reply on X '
                '<a href="{{xUrl}}" rel="noopener">@{{xHandle}}</a>. With your permission, real notes will go here.</p></div>')
    out = []
    for t in items:
        who = esc(t.get("name", ""))
        if t.get("url"):
            who = f'<a href="{esc(t["url"])}" rel="noopener">{who}</a>'
        out.append(f'<figure class="quote"><blockquote><p>{esc(t["quote"])}</p></blockquote>'
                   f'<figcaption>{who}<span>{esc(t.get("role", ""))}</span></figcaption></figure>')
    return f'<div class="quotes">{"".join(out)}</div>'


RAW = {**pricing_html(), "testimonials": testimonials_html()}
cfg["sha256Display"] = cfg.get("sha256") or "published here with each release"


# ---------------------------------------------------------------- pages
def url_for(slug):
    return "/" + (f"{slug}/" if slug else "")


def out_path(slug):
    if slug == "404":
        return DIST / "404.html"
    return DIST.joinpath(*slug.split("/"), "index.html") if slug else DIST / "index.html"


def page_ctx(meta, slug, head=""):
    return {
        **cfg,
        "page": {"ogType": "website", "bodyClass": "", **meta},
        "canonical": cfg["siteUrl"] + url_for(slug if slug != "404" else ""),
        "robots": "noindex" if slug == "404" or meta.get("noindex") else "index,follow",
        "raw": {**RAW, "head": head},
    }


LAYOUT = (SRC / "templates" / "layout.html").read_text(encoding="utf-8")


def render_page(meta, content, head, where):
    """Render one page into dist/. Returns its canonical URL (or None for 404/noindex) for the sitemap."""
    slug = meta.get("slug", "")
    ctx = page_ctx(meta, slug, head)
    out = render(LAYOUT.replace("{{> __content}}", content), ctx, where)
    dest = out_path(slug)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(out, encoding="utf-8")
    print(f"[build] {dest.relative_to(ROOT)}")
    return None if ctx["robots"] == "noindex" else ctx["canonical"]


def build_pages():
    sitemap = []
    for f in sorted((SRC / "pages").glob("*.html")):
        raw = f.read_text(encoding="utf-8")
        m = PAGE_HEADER.match(raw)
        if not m:
            sys.exit(f"[build] missing <!--page {{...}} --> header in {f}")
        meta = json.loads(m.group(1))
        sitemap.append(render_page(meta, raw[m.end():], "", str(f.relative_to(ROOT))))
    return sitemap


def write_generated(sitemap):
    a = cfg["accent"]
    (DIST / "assets" / "brand.css").write_text(
        "/* generated from site.config.json - do not edit */\n"
        f":root{{--accent-l:{a['light']};--on-accent-l:{a['onLight']};"
        f"--accent-d:{a['dark']};--on-accent-d:{a['onDark']};}}\n",
        encoding="utf-8",
    )
    tpl = (SRC / "templates" / "site.webmanifest").read_text(encoding="utf-8")
    (DIST / "site.webmanifest").write_text(render(tpl, cfg, "site.webmanifest"), encoding="utf-8")
    (DIST / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {cfg['siteUrl']}/sitemap.xml\n", encoding="utf-8")
    today = date.today().isoformat()
    rows = [f"  <url>\n    <loc>{loc}</loc>\n    <lastmod>{today}</lastmod>\n  </url>" for loc in sitemap if loc]
    (DIST / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "\n".join(rows) + "\n</urlset>\n",
        encoding="utf-8")


# ---------------------------------------------------------------- OG image
CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome", "chromium", "chromium-browser",
]


def find_chrome():
    for c in CHROME_CANDIDATES:
        if Path(c).exists() or shutil.which(c):
            return c
    return None


def crop_png_rows(path, height):
    """Keep only the top `height` rows of a non-interlaced 8-bit PNG (pure stdlib)."""
    import struct
    import zlib
    data = Path(path).read_bytes()
    pos, chunks = 8, []
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        chunks.append((data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]))
        pos += 12 + length
    width, h0, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunks[0][1])
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    if depth != 8 or interlace or h0 < height:
        raise ValueError("unsupported PNG for cropping")
    raw = zlib.decompress(b"".join(c for t, c in chunks if t == b"IDAT"))[: height * (1 + width * channels)]

    def chunk(t, c):
        return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xFFFFFFFF)

    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def chrome_shot(chrome, html_doc, out, w, h):
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "p.html"
        page.write_text(html_doc, encoding="utf-8")
        shot = Path(tmp) / "shot.png"
        subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        f"--window-size={w},{h + 300}", f"--user-data-dir={tmp}/profile", f"--screenshot={shot}",
                        page.as_uri()], check=True, capture_output=True, timeout=90)
        crop_png_rows(shot, h)
        shutil.copy(shot, out)


def render_og_png():
    """Rasterise src/templates/og.svg -> og.png (1200x630) with headless Chrome if available; else keep the committed PNG."""
    chrome = find_chrome()
    if not chrome:
        print("[build] Chrome not found; keeping existing og.png")
        return
    svg = render((SRC / "templates" / "og.svg").read_text(encoding="utf-8"), cfg, "og.svg")
    doc = ('<!doctype html><html><head><style>html,body{margin:0;overflow:hidden;background:#0E1114}svg{display:block}</style>'
           '</head><body>' + svg + "</body></html>")
    try:
        chrome_shot(chrome, doc, DIST / "og.png", 1200, 630)
        shutil.copy(DIST / "og.png", PUBLIC / "og.png")
        print("[build] dist/og.png rendered")
    except Exception as e:  # noqa: BLE001
        print(f"[build] could not render og.png ({e}); keeping existing")


# ---------------------------------------------------------------- checks
def check_links():
    bad = []
    attr = re.compile(r'(?:href|src|content|poster|srcset)="(/[^"?]*)')
    ids_cache = {}

    def ids_of(f):
        if f not in ids_cache:
            ids_cache[f] = set(re.findall(r'\sid="([^"]+)"', f.read_text(encoding="utf-8")))
        return ids_cache[f]

    for f in DIST.rglob("*.html"):
        text = f.read_text(encoding="utf-8")
        for full in attr.findall(text):
            if full.startswith("//"):
                continue
            path, _, frag = full.partition("#")
            path = path.split(" ")[0]
            target = DIST / path.lstrip("/")
            if path.endswith("/"):
                target = target / "index.html"
            if not target.exists():
                bad.append((str(f.relative_to(DIST)), full))
            elif frag and target.suffix == ".html" and frag not in ids_of(target):
                bad.append((str(f.relative_to(DIST)), full))
        for frag in re.findall(r'href="#([^"]+)"', text):  # same-page anchors
            if frag not in ids_of(f):
                bad.append((str(f.relative_to(DIST)), "#" + frag))
    dl = cfg["downloadUrl"]
    missing = sorted(set(bad))
    placeholders = [m for m in missing if m[1] == dl]
    real = [m for m in missing if m[1] != dl]
    if placeholders:
        print(f"[check] NOTE: {dl} is not in dist/ yet (allowed placeholder until the .dmg is added to public{dl})")
    if real:
        for f, p in real:
            print(f"[check] BROKEN: {f} -> {p}")
        sys.exit(1)
    print("[check] all internal links, #fragments and assets resolve")


def check_name_not_hardcoded():
    """Renaming must be one config change: the product name may not appear literally in sources."""
    name = cfg["name"]
    pat = re.compile(rf"\b{re.escape(name)}\b")
    hits = []
    files = [*SRC.rglob("*"), *(PUBLIC / "assets").rglob("*.css"), *(PUBLIC / "assets").rglob("*.js"), ROOT / "blog.py"]
    for f in files:
        if f.is_file() and f.suffix in (".html", ".md", ".svg", ".css", ".js", ".py", ".webmanifest", ".json"):
            for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                if pat.search(line):
                    hits.append(f"{f.relative_to(ROOT)}:{i}")
    if hits:
        for h in hits:
            print(f"[check] HARD-CODED NAME '{name}': {h} (use {{{{name}}}})")
        sys.exit(1)
    print(f"[check] product name only lives in site.config.json")


def main():
    if DIST.exists():
        shutil.rmtree(DIST)
    shutil.copytree(PUBLIC, DIST)
    sitemap = build_pages()
    sitemap += blog.build(sys.modules[__name__])
    write_generated(sitemap)
    if "--no-og" not in sys.argv:
        render_og_png()
    if "--check" in sys.argv:
        check_links()
        check_name_not_hardcoded()
    print("[build] done -> dist/")


if __name__ == "__main__":
    main()
