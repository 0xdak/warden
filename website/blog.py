"""
Blog for the static site (stdlib only, English only). Called from build.py:  sitemap += blog.build(build_module)

Sources:  src/blog/*.md
Each file starts with front matter:

    ---
    title: How to stop Claude Code from reading your .env file
    description: One or two sentences for the meta description and the index card.
    date: 2026-11-10
    slug: stop-claude-code-reading-env
    tags: claude code, secrets
    updated: 2026-11-12          (optional)
    ---

Output:   /blog/ (index) and /blog/<slug>/
Each post gets canonical, OG article tags, Article + Breadcrumb JSON-LD, a CTA box at the end and a sitemap entry.
Site tokens such as {{name}} and {{downloadUrl}} work inside posts: NEVER type the product name into a post,
use {{name}} so a rename is one config change. A literal "{{" in a post would be read as a token, so don't use it.

Markdown subset: # headings (## and ### get ids), paragraphs, - / * / 1. lists (one level), ``` fenced code,
`inline code`, **bold**, *italic*, [links](/url), ![images](/src "title"), | tables |, > callouts, ---,
and a literal <kbd>…</kbd> tag. Everything else is HTML-escaped.
"""
import html
import json
import re
import unicodedata
from datetime import date as _date

STYLESHEET = "/assets/blog.css"
WORDS_PER_MINUTE = 220
MONTHS_EN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
             "November", "December"]
S = {
    "indexTitle": "Blog — {{name}}",
    "indexH1": "Field notes on agent security",
    "indexLede": "Practical, tested guides to running AI coding agents on your own machine without handing them your secrets. Most of it works with nothing but the agents' own settings.",
    "indexDesc": "Practical guides to AI coding agent security: keeping .env files away from Claude Code, writing hooks that block dangerous commands, and what --dangerously-skip-permissions really risks.",
    "min": "{n} min read",
    "back": "All posts",
    "ctaTitle": "Rather not maintain these scripts yourself?",
    "ctaBody": "{{name}} is a native macOS menu-bar app that installs these hooks for you, across several agents, and asks you before anything risky happens. It runs locally, needs no account and is {{pricing.headline}}.",
    "tags": "Tags",
}

# ---------------------------------------------------------------- Markdown subset

def slugify(text):
    text = text.replace("ı", "i").replace("İ", "i")
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii").lower()
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-") or "section"


_CODE = re.compile(r"`([^`]+)`")
_IMG = re.compile(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;(.*?)&quot;)?\)')
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_BOLD = re.compile(r"\*\*(.+?)\*\*")
_ITAL = re.compile(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])|(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])")
_KBD = re.compile(r"&lt;kbd&gt;(.*?)&lt;/kbd&gt;")


def inline(text):
    """Escape, then apply inline markup. Code spans are protected from the other rules."""
    codes = []

    def keep_code(m):
        codes.append(f"<code>{html.escape(m.group(1), quote=False)}</code>")
        return f"\x00{len(codes) - 1}\x00"

    text = _CODE.sub(keep_code, text)
    text = html.escape(text, quote=True)
    text = _KBD.sub(r"<kbd>\1</kbd>", text)

    def img(m):
        alt, src, title = m.group(1), m.group(2), m.group(3)
        t = f' title="{title}"' if title else ""
        return f'<img src="{src}" alt="{alt}"{t} loading="lazy" decoding="async">'

    text = _IMG.sub(img, text)

    def link(m):
        label, href = m.group(1), m.group(2)
        ext = href.startswith(("http://", "https://"))
        rel = ' rel="noopener"' if ext else ""
        return f'<a href="{href}"{rel}>{label}</a>'

    text = _LINK.sub(link, text)
    text = _BOLD.sub(r"<strong>\1</strong>", text)
    text = _ITAL.sub(lambda m: f"<em>{m.group(1) or m.group(2)}</em>", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], text)


def _is_table_sep(line):
    return bool(re.fullmatch(r"\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*", line))


def _cells(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def markdown(src):
    """Convert the Markdown subset to HTML. Returns (html, headings) where headings = [(level, id, text)]."""
    lines = src.replace("\r\n", "\n").split("\n")
    out, heads, used = [], [], set()
    i, n = 0, len(lines)

    def para_end(j):
        s = lines[j]
        return (not s.strip() or s.startswith(("#", "```", ">", "|")) or re.match(r"\s*([-*]|\d+\.)\s+", s)
                or re.fullmatch(r"\s*(-{3,}|\*{3,})\s*", s))

    while i < n:
        line = lines[i]
        s = line.strip()
        if not s:
            i += 1
            continue
        # fenced code
        m = re.match(r"```\s*([\w+-]*)\s*$", s)
        if m:
            lang = m.group(1)
            buf = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1  # closing fence
            cls = f' class="language-{lang}"' if lang else ""
            out.append(f'<pre><code{cls}>{html.escape(chr(10).join(buf), quote=False)}</code></pre>')
            continue
        # heading
        m = re.match(r"(#{1,4})\s+(.*?)\s*#*$", s)
        if m:
            level = len(m.group(1))
            text = m.group(2)
            hid = slugify(re.sub(r"[`*_\[\]]|\(.*?\)", "", text))
            base, k = hid, 2
            while hid in used:
                hid, k = f"{base}-{k}", k + 1
            used.add(hid)
            heads.append((level, hid, re.sub(r"<[^>]+>", "", inline(text))))
            out.append(f'<h{level} id="{hid}">{inline(text)}</h{level}>')
            i += 1
            continue
        # horizontal rule
        if re.fullmatch(r"(-{3,}|\*{3,})", s):
            out.append("<hr>")
            i += 1
            continue
        # callout (blockquote)
        if s.startswith(">"):
            buf = []
            while i < n and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip()[1:].strip())
                i += 1
            inner, _ = markdown("\n".join(buf))
            out.append(f'<aside class="callout">{inner}</aside>')
            continue
        # table
        if s.startswith("|") and i + 1 < n and _is_table_sep(lines[i + 1]):
            head = _cells(lines[i])
            i += 2
            rows = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append(_cells(lines[i]))
                i += 1
            th = "".join(f'<th scope="col">{inline(c)}</th>' for c in head)
            body = "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in rows)
            out.append(f'<div class="table-wrap"><table><thead><tr>{th}</tr></thead><tbody>{body}</tbody></table></div>')
            continue
        # lists
        m = re.match(r"\s*([-*]|\d+\.)\s+", line)
        if m:
            ordered = m.group(1)[0].isdigit()
            items = []
            while i < n:
                lm = re.match(r"\s*([-*]|\d+\.)\s+(.*)", lines[i])
                if lm and (lm.group(1)[0].isdigit()) == ordered:
                    items.append(lm.group(2))
                    i += 1
                elif items and lines[i].startswith(("  ", "\t")) and lines[i].strip():
                    items[-1] += " " + lines[i].strip()  # continuation line
                    i += 1
                else:
                    break
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline(t)}</li>" for t in items) + f"</{tag}>")
            continue
        # paragraph (or a standalone image)
        buf = [s]
        i += 1
        while i < n and not para_end(i):
            buf.append(lines[i].strip())
            i += 1
        text = " ".join(buf)
        if re.fullmatch(r"!\[[^\]]*\]\([^)]*\)", text):
            out.append(f"<figure>{inline(text)}</figure>")
        else:
            out.append(f"<p>{inline(text)}</p>")
    return "\n".join(out), heads


# ---------------------------------------------------------------- posts

FRONT = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.S)
REQUIRED = ("title", "description", "date", "slug", "tags")


def load_posts(src_dir):
    posts = []
    for f in sorted(src_dir.glob("*.md")):
        raw = f.read_text(encoding="utf-8")
        m = FRONT.match(raw)
        if not m:
            raise SystemExit(f"[blog] {f}: missing front matter")
        meta = {}
        for line in m.group(1).splitlines():
            if line.strip() and not line.lstrip().startswith("#"):
                k, _, v = line.partition(":")
                meta[k.strip()] = v.strip().strip('"')
        missing = [k for k in REQUIRED if not meta.get(k)]
        if missing:
            raise SystemExit(f"[blog] {f}: front matter needs {', '.join(missing)}")
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", meta["slug"]):
            raise SystemExit(f"[blog] {f}: slug must be lowercase ascii words joined by '-'")
        try:
            meta["dateObj"] = _date.fromisoformat(meta["date"])
        except ValueError:
            raise SystemExit(f"[blog] {f}: date must be YYYY-MM-DD")
        meta["tagList"] = [t.strip() for t in meta["tags"].split(",") if t.strip()]
        body = raw[m.end():]
        meta["html"], meta["heads"] = markdown(body)
        text = re.sub(r"```.*?```", " ", body, flags=re.S)
        meta["words"] = len(re.findall(r"[\w’'-]+", re.sub(r"[#*`>|\[\]()!_]", " ", text)))
        meta["file"] = f
        posts.append(meta)
    slugs = [p["slug"] for p in posts]
    dup = {s for s in slugs if slugs.count(s) > 1}
    if dup:
        raise SystemExit(f"[blog] duplicate slugs: {', '.join(sorted(dup))}")
    return sorted(posts, key=lambda p: (p["dateObj"], p["slug"]), reverse=True)


def fmt_date(d):
    return f"{MONTHS_EN[d.month - 1]} {d.day}, {d.year}"


def reading_min(words):
    return max(1, round(words / WORDS_PER_MINUTE))


def _jsonld(obj):
    return ('<script type="application/ld+json">\n'
            + json.dumps(obj, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/") + "\n</script>")


def _tags_html(tags):
    return "".join(f'<li>{html.escape(t)}</li>' for t in tags)


def _toc(heads):
    items = [f'<li><a href="#{hid}">{text}</a></li>' for level, hid, text in heads if level == 2]
    if len(items) < 3:
        return ""
    return ('<nav class="toc" aria-labelledby="toc-h"><p class="toc-h" id="toc-h">On this page</p>'
            f'<ol>{"".join(items)}</ol></nav>')


def build(b):
    """b = the build module (cfg, SRC, ROOT, page_ctx, render_page, url_for)."""
    src_dir = b.SRC / "blog"
    if not src_dir.is_dir():
        return []
    site = b.cfg["siteUrl"].rstrip("/")
    posts = load_posts(src_dir)
    css = f'<link rel="stylesheet" href="{STYLESHEET}">'
    sitemap = []
    index_slug = "blog"
    name_tok = "{{name}}"

    for p in posts:
        slug = f"blog/{p['slug']}"
        url = site + b.url_for(slug)
        mins = S["min"].replace("{n}", str(reading_min(p["words"])))
        title = html.escape(p["title"])
        article = {
            "@context": "https://schema.org", "@type": "Article",
            "headline": p["title"], "description": p["description"],
            "datePublished": p["date"], "dateModified": p.get("updated", p["date"]),
            "inLanguage": "en", "mainEntityOfPage": url, "url": url,
            "image": site + "/og.png", "keywords": ", ".join(p["tagList"]), "wordCount": p["words"],
            "author": {"@type": "Organization", "name": b.cfg["company"]["name"], "url": b.cfg["company"]["url"]},
            "publisher": {"@type": "Organization", "name": b.cfg["company"]["name"], "url": b.cfg["company"]["url"],
                          "logo": {"@type": "ImageObject", "url": site + "/icon-512.png"}},
        }
        crumbs = {
            "@context": "https://schema.org", "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Blog", "item": site + b.url_for(index_slug)},
                {"@type": "ListItem", "position": 2, "name": p["title"], "item": url},
            ],
        }
        head = "\n".join([
            css,
            f'<meta property="article:published_time" content="{p["date"]}">',
            *[f'<meta property="article:tag" content="{html.escape(t)}">' for t in p["tagList"]],
            _jsonld(article), _jsonld(crumbs),
        ])
        updated = ""
        if p.get("updated") and p["updated"] != p["date"]:
            updated = f'<span aria-hidden="true"> · </span>Updated <time datetime="{p["updated"]}">{fmt_date(_date.fromisoformat(p["updated"]))}</time>'
        content = f"""<article class="post">
<header class="page-head post-head">
  <div class="wrap narrow">
    <p class="post-back"><a href="{b.url_for(index_slug)}">← {S["back"]}</a></p>
    <h1>{title}</h1>
    <p class="post-lede">{html.escape(p["description"])}</p>
    <p class="post-meta"><time datetime="{p["date"]}">{fmt_date(p["dateObj"])}</time><span aria-hidden="true"> · </span>{mins}{updated}</p>
  </div>
</header>
<div class="wrap narrow prose post-body">
{_toc(p["heads"])}
{p["html"]}
  <aside class="post-cta" aria-labelledby="post-cta-h">
    <h2 id="post-cta-h">{S["ctaTitle"]}</h2>
    <p>{S["ctaBody"]}</p>
    <div class="cta-row">
      <a class="btn btn-primary" href="{{{{downloadUrl}}}}" download>Download {name_tok}</a>
      <a class="btn btn-ghost" href="/#stops">What it blocks</a>
    </div>
    <p class="post-cta-fine">{{{{requirements}}}} · v{{{{version}}}}</p>
  </aside>
  <ul class="post-tags" aria-label="{S['tags']}">{_tags_html(p["tagList"])}</ul>
</div>
</article>"""
        meta = {"slug": slug, "title": f"{title} — {name_tok}", "description": html.escape(p["description"]),
                "ogType": "article"}
        sitemap.append(b.render_page(meta, content, head, f"blog/{p['slug']}.md"))

    cards = []
    for p in posts:
        href = b.url_for(f"blog/{p['slug']}")
        mins = S["min"].replace("{n}", str(reading_min(p["words"])))
        cards.append(f"""  <li class="post-card">
    <p class="post-meta"><time datetime="{p["date"]}">{fmt_date(p["dateObj"])}</time><span aria-hidden="true"> · </span>{mins}</p>
    <h2><a href="{href}">{html.escape(p["title"])}</a></h2>
    <p>{html.escape(p["description"])}</p>
    <ul class="post-tags" aria-label="{S['tags']}">{_tags_html(p["tagList"])}</ul>
  </li>""")
    index_url = site + b.url_for(index_slug)
    blog_ld = {
        "@context": "https://schema.org", "@type": "Blog", "name": f"{b.cfg['name']} Blog", "url": index_url,
        "inLanguage": "en",
        "blogPost": [{"@type": "BlogPosting", "headline": p["title"], "datePublished": p["date"],
                      "url": site + b.url_for(f"blog/{p['slug']}")} for p in posts],
    }
    head = "\n".join([css, _jsonld(blog_ld)])
    content = f"""<header class="page-head blog-head">
  <div class="wrap narrow">
    <p class="kicker">Blog</p>
    <h1>{S["indexH1"]}</h1>
    <p>{S["indexLede"]}</p>
  </div>
</header>
<div class="wrap narrow blog-index">
<ol class="post-list" reversed>
{chr(10).join(cards)}
</ol>
</div>"""
    meta = {"slug": index_slug, "title": S["indexTitle"], "description": S["indexDesc"]}
    sitemap.append(b.render_page(meta, content, head, "blog/index"))
    return sitemap


def word_counts(src_dir):
    """Helper: python3 -c 'import blog,pathlib; blog.word_counts(pathlib.Path("src/blog"))'"""
    for p in load_posts(src_dir):
        print(f"{p['words']:5d}  {p['slug']}")
