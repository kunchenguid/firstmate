#!/usr/bin/env python3
"""HTML and routing helper for bin/fm-lavish-url.sh; not a user entry point.

Subcommands (all output is line-oriented `key: value` text):

  decode-eval <file>
      Decode one `chrome-devtools-axi eval --full` response into the capture
      JSON object on stdout. A truncated, error, or unparsable response exits 3.

  build --capture <json> --url <requested-url> --viewport desktop|mobile
        --viewport-size <WxH> --skill-dir <dir> --out <html> --meta-out <json>
        --captured-at <iso>
      Sanitize the captured page, select the matching enhancers, inject the
      universal layer and those enhancers, and write the snapshot and its
      metadata. Prints `enhancers: <a,b,...>`.

  match --url <url> --html <file> --skill-dir <dir>
      Print `enhancers: <a,b,...>` for an already-captured page.

  route --url <url> --registry <projects.md> --projects <dir> --domains <file>
      Resolve which registered project a URL belongs to. Prints `route:` one of
      project, inferred, ambiguous, unrouted, then `project:` or `candidates:`
      and a `basis:` line. A malformed domains file exits 2.

THE CAPTURED PAGE IS HOSTILE INPUT. The capture string comes from a page whose
own scripts ran in the capture browser and could have replaced any DOM API, so
nothing about its shape is trusted. The sanitizer rebuilds the document from
parser tokens: every script, plugin, frame, base, and http-equiv element is
dropped, every event-handler and script-URL attribute is dropped, text and
attribute values are re-escaped, and raw style text cannot open markup. The
only scripts in the output are the ones this helper injects.
"""

import html
import json
import os
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

SCHEMA = "fm-lavish-url.v1"
DOMAINS_LABEL = "config/lavish-url-domains"

# Dropped together with everything inside them.
DROP_WITH_CONTENT = {
    "script", "noscript", "object", "applet", "frameset", "noembed",
    "noframes", "plaintext", "xmp", "portal", "iframe", "frame",
}
# Dropped where they stand (void or harmless to drop without content).
DROP_VOID = {"embed", "base", "param"}
VOID = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}
URL_ATTRS = {
    "href", "src", "poster", "action", "data", "background", "cite",
    "longdesc", "xlink:href", "manifest", "codebase", "formaction",
}
SRCSET_ATTRS = {"srcset", "imagesrcset"}
DROP_ATTRS = {"srcdoc", "formaction", "nonce", "integrity", "crossorigin", "ping", "http-equiv"}
SAFE_LINK_RELS = {"stylesheet", "icon", "shortcut", "apple-touch-icon", "alternate", "mask-icon"}
ALLOWED_SCHEMES = {"http", "https", "mailto", "tel"}
TAG_NAME = re.compile(r"^[a-z][a-z0-9:-]*$")
ATTR_NAME = re.compile(r"^[a-z_:][a-z0-9_:.-]*$")
CSS_URL = re.compile(r"""url\(\s*(['"]?)(.*?)\1\s*\)""", re.IGNORECASE | re.DOTALL)
CSS_IMPORT = re.compile(r"""@import\s+(['"])(.*?)\1""", re.IGNORECASE)


def squash(value):
    """Lower-case with every whitespace and control character removed, the way
    browsers ignore them when reading a URL scheme."""
    return "".join(ch for ch in value if ord(ch) > 0x20).lower()


def scripted(value):
    flat = squash(value)
    return flat.startswith("javascript:") or flat.startswith("vbscript:") or flat.startswith("livescript:")


def safe_url(value, base):
    raw = value.strip()
    if not raw:
        return raw
    if scripted(raw):
        return None
    if raw.startswith("#"):
        return raw
    flat = squash(raw)
    if flat.startswith("data:"):
        return raw if flat.startswith("data:image/") else None
    try:
        resolved = urljoin(base, raw)
    except ValueError:
        return None
    scheme = urlsplit(resolved).scheme.lower()
    if scheme and scheme not in ALLOWED_SCHEMES:
        return None
    return resolved


def rewrite_css(text, base):
    def repl_url(match):
        quote, target = match.group(1), match.group(2)
        fixed = safe_url(target, base)
        return "url(%s%s%s)" % (quote, fixed if fixed is not None else "about:blank", quote)

    def repl_import(match):
        quote, target = match.group(1), match.group(2)
        fixed = safe_url(target, base)
        return "@import %s%s%s" % (quote, fixed if fixed is not None else "about:blank", quote)

    text = CSS_URL.sub(repl_url, text)
    text = CSS_IMPORT.sub(repl_import, text)
    # Raw style text can never open markup, even inside foreign content.
    return text.replace("<", "\\3c ")


class Sanitizer(HTMLParser):
    def __init__(self, base, html_extra_attrs):
        super().__init__(convert_charrefs=False)
        self.base = base
        self.html_extra_attrs = html_extra_attrs
        self.out = []
        self.skip = []          # stack of tag names whose content is dropped
        self.in_style = False
        self.head_start = None  # output index just after <head ...>
        self.body_end = None    # output index of the first </body>
        self.saw_html = False

    # -- helpers ---------------------------------------------------------
    def clean_attrs(self, tag, attrs):
        kept = []
        for name, value in attrs:
            name = (name or "").lower()
            value = "" if value is None else value
            if not ATTR_NAME.match(name):
                continue
            if name.startswith("on") or name in DROP_ATTRS:
                continue
            if name.startswith("data-lavish") or name.startswith("data-fm-"):
                continue
            if tag == "form" and name == "action":
                fixed = safe_url(value, self.base)
                if fixed:
                    kept.append(("data-fm-action", fixed))
                continue
            if name in URL_ATTRS:
                fixed = safe_url(value, self.base)
                if fixed is None:
                    continue
                kept.append((name, fixed))
                continue
            if name in SRCSET_ATTRS:
                parts = []
                for candidate in value.split(","):
                    bits = candidate.strip().split(None, 1)
                    if not bits:
                        continue
                    fixed = safe_url(bits[0], self.base)
                    if fixed:
                        parts.append(fixed + (" " + bits[1] if len(bits) > 1 else ""))
                kept.append((name, ", ".join(parts)))
                continue
            if name == "style":
                kept.append((name, rewrite_css(value, self.base)))
                continue
            if scripted(value):
                continue
            kept.append((name, value))
        return kept

    @staticmethod
    def render_attrs(attrs):
        return "".join(
            ' %s="%s"' % (name, html.escape(value, quote=True)) for name, value in attrs
        )

    def drop_element(self, tag, attrs):
        if tag in DROP_WITH_CONTENT or tag in DROP_VOID:
            return True
        names = {(n or "").lower(): (v or "") for n, v in attrs}
        if tag == "meta" and "http-equiv" in names:
            return True
        if tag == "link":
            rels = set(names.get("rel", "").lower().split())
            if not rels or not rels <= SAFE_LINK_RELS:
                return True
        if tag in ("animate", "set", "animatetransform", "animatemotion"):
            target = names.get("attributename", "").lower()
            if target.endswith("href") or target.startswith("on"):
                return True
        return False

    # -- parser callbacks ------------------------------------------------
    def handle_starttag(self, tag, attrs):
        self.emit_start(tag, attrs, False)

    def handle_startendtag(self, tag, attrs):
        self.emit_start(tag, attrs, True)

    def emit_start(self, tag, attrs, selfclosing):
        tag = tag.lower()
        if self.skip:
            if tag == self.skip[-1] and tag not in VOID and not selfclosing:
                self.skip.append(tag)
            return
        if not TAG_NAME.match(tag):
            return
        if self.drop_element(tag, attrs):
            if tag == "iframe":
                src = dict((n, v) for n, v in attrs).get("src") or ""
                host = urlsplit(safe_url(src, self.base) or "").hostname or "embedded content"
                self.out.append(
                    '<div data-fm-placeholder="iframe" style="border:1px dashed #b4720e;'
                    'padding:8px;font:12px system-ui,sans-serif;color:#5c4a1f">'
                    "Embedded frame omitted from the snapshot: %s</div>" % html.escape(host)
                )
            if tag not in VOID and not selfclosing and tag not in DROP_VOID:
                self.skip.append(tag)
            return
        kept = self.clean_attrs(tag, attrs)
        if tag == "html":
            if self.saw_html:
                return
            self.saw_html = True
            kept = [(n, v) for n, v in kept if n not in dict(self.html_extra_attrs)] + self.html_extra_attrs
        self.out.append("<%s%s%s>" % (tag, self.render_attrs(kept), " /" if selfclosing and tag not in VOID else ""))
        if tag == "head" and self.head_start is None:
            self.head_start = len(self.out)
        if tag == "style" and not selfclosing:
            self.in_style = True

    def handle_endtag(self, tag):
        tag = tag.lower()
        if self.skip:
            if tag == self.skip[-1]:
                self.skip.pop()
            return
        if not TAG_NAME.match(tag) or tag in VOID:
            return
        if tag in DROP_WITH_CONTENT or tag in DROP_VOID:
            return
        if tag == "style":
            self.in_style = False
        if tag == "body" and self.body_end is None:
            self.body_end = len(self.out)
        self.out.append("</%s>" % tag)

    def handle_data(self, data):
        if self.skip:
            return
        if self.in_style:
            self.out.append(rewrite_css(data, self.base))
        else:
            self.out.append(html.escape(data, quote=False))

    def handle_entityref(self, name):
        if self.skip:
            return
        if re.match(r"^[A-Za-z][A-Za-z0-9]{0,31}$", name):
            self.out.append("&%s;" % name)

    def handle_charref(self, name):
        if self.skip:
            return
        if re.match(r"^(?:[0-9]{1,7}|[xX][0-9a-fA-F]{1,6})$", name):
            self.out.append("&#%s;" % name)

    def handle_comment(self, data):
        return

    def handle_decl(self, decl):
        return

    def handle_pi(self, data):
        return

    def unknown_decl(self, data):
        return


def enhancer_rules(skill_dir):
    """Read each enhancer's `fm-lavish-url-match:` header lines."""
    rules = []
    directory = os.path.join(skill_dir, "enhancers")
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".js"):
            continue
        path = os.path.join(directory, name)
        matches = []
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                found = re.match(r"^//\s*fm-lavish-url-match:\s*(always|host|html)\s*(.*?)\s*$", line)
                if found:
                    matches.append((found.group(1), found.group(2)))
                elif not line.startswith("//"):
                    break
        if not matches:
            raise SystemExit("enhancer declares no fm-lavish-url-match line: %s" % path)
        rules.append((name[:-3], path, matches))
    rules.sort(key=lambda rule: (rule[0] != "default", rule[0]))
    return rules


def host_matches(host, domain):
    host = (host or "").lower().rstrip(".")
    domain = domain.lower().strip(".")
    return bool(domain) and (host == domain or host.endswith("." + domain))


def matching_enhancers(skill_dir, host, page_html):
    selected = []
    for name, path, matches in enhancer_rules(skill_dir):
        for kind, value in matches:
            if kind == "always" or (kind == "host" and host_matches(host, value)) or (
                kind == "html" and value and value in page_html
            ):
                selected.append((name, path))
                break
    return selected


def inline_script(source, label):
    if re.search(r"</script", source, re.IGNORECASE):
        raise SystemExit("refusing to inline %s: it contains a closing script tag" % label)
    return source


def decode_eval(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    if re.search(r"^\s*(error:|code:)", text, re.MULTILINE) and not re.search(r"^result:", text, re.MULTILINE):
        sys.stderr.write("capture browser reported an error:\n" + text[:2000] + "\n")
        sys.exit(3)
    if "Result was truncated" in text:
        sys.stderr.write("capture was truncated by the browser tool\n")
        sys.exit(3)
    found = re.search(r"^result:\s?(.*)$", text, re.MULTILINE)
    if not found:
        sys.stderr.write("capture response carries no result line\n")
        sys.exit(3)
    value = found.group(1).strip()
    try:
        for _ in range(3):
            if isinstance(value, str):
                value = json.loads(value)
            else:
                break
    except ValueError:
        sys.stderr.write("capture result is not decodable JSON\n")
        sys.exit(3)
    if not isinstance(value, dict) or not isinstance(value.get("html"), str):
        sys.stderr.write("capture result carries no html string\n")
        sys.exit(3)
    json.dump(value, sys.stdout)
    sys.stdout.write("\n")


def opt(args, name, default=None):
    if name in args:
        index = args.index(name)
        if index + 1 >= len(args):
            raise SystemExit("missing value for %s" % name)
        return args[index + 1]
    if default is None:
        raise SystemExit("missing %s" % name)
    return default


def build(args):
    capture_path = opt(args, "--capture")
    url = opt(args, "--url")
    viewport = opt(args, "--viewport")
    viewport_size = opt(args, "--viewport-size")
    skill_dir = opt(args, "--skill-dir")
    out_path = opt(args, "--out")
    meta_path = opt(args, "--meta-out")
    captured_at = opt(args, "--captured-at")
    with open(capture_path, encoding="utf-8") as handle:
        capture = json.load(handle)
    requested = urlsplit(url)
    host = (requested.hostname or "").lower()
    reported = capture.get("url") if isinstance(capture.get("url"), str) else ""
    base_hint = capture.get("baseURI") if isinstance(capture.get("baseURI"), str) else ""
    base = url
    if urlsplit(base_hint).scheme in ("http", "https"):
        base = base_hint
    elif urlsplit(reported).scheme in ("http", "https"):
        base = reported
    html_attrs = [("data-fm-lavish-url", "snapshot"), ("data-fm-viewport", viewport)]
    sanitizer = Sanitizer(base, html_attrs)
    sanitizer.feed(capture["html"])
    sanitizer.close()
    body = sanitizer.out
    page_html = "".join(body)
    selected = matching_enhancers(skill_dir, host, page_html)
    title = capture.get("title") if isinstance(capture.get("title"), str) else ""
    title = re.sub(r"\s+", " ", title).strip()[:200]
    context = {
        "schema": SCHEMA,
        "url": url,
        "host": host,
        "viewport": viewport,
        "viewport_size": viewport_size,
        "captured_at": captured_at,
        "enhancers": [name for name, _ in selected],
    }
    with open(os.path.join(skill_dir, "assets", "core.css"), encoding="utf-8") as handle:
        css = handle.read().replace("<", "\\3c ")
    with open(os.path.join(skill_dir, "assets", "core.js"), encoding="utf-8") as handle:
        core = inline_script(handle.read(), "core.js")
    head_inject = '<style id="fm-lavish-url-style">\n%s</style>' % css
    context_json = json.dumps(context).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    tail = [
        '<script id="fm-lavish-url-context" type="application/json">%s</script>' % context_json,
        '<script id="fm-lavish-url-core">\n%s</script>' % core,
    ]
    for name, path in selected:
        with open(path, encoding="utf-8") as handle:
            tail.append('<script data-fm-enhancer="%s">\n%s</script>' % (html.escape(name), inline_script(handle.read(), path)))
    tail_html = "\n".join(tail) + "\n"
    if sanitizer.body_end is not None:
        body = body[: sanitizer.body_end] + [tail_html] + body[sanitizer.body_end:]
    else:
        body = body + [tail_html]
    if sanitizer.head_start is not None:
        body = body[: sanitizer.head_start] + [head_inject] + body[sanitizer.head_start:]
    else:
        body = [head_inject] + body
    document = "<!DOCTYPE html>\n" + "".join(body) + "\n"
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(document)
    meta = dict(context)
    meta["title"] = title
    meta["reported_url"] = reported[:2000]
    meta["snapshot"] = os.path.abspath(out_path)
    with open(meta_path, "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=2)
        handle.write("\n")
    print("enhancers: %s" % ",".join(name for name, _ in selected))


def match(args):
    url = opt(args, "--url")
    page = opt(args, "--html")
    skill_dir = opt(args, "--skill-dir")
    with open(page, encoding="utf-8", errors="replace") as handle:
        page_html = handle.read()
    host = (urlsplit(url).hostname or "").lower()
    print("enhancers: %s" % ",".join(name for name, _ in matching_enhancers(skill_dir, host, page_html)))


# -- routing ---------------------------------------------------------------

DOMAIN_TOKEN = re.compile(
    r"(?<![a-z0-9.@-])((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63})(?![a-z0-9-])"
)
# Extensions that look like top-level domains in prose but name files.
FILE_SUFFIXES = {
    "md", "py", "sh", "js", "ts", "json", "yml", "yaml", "xml", "toml", "txt",
    "html", "css", "scss", "csv", "lock", "cfg", "ini", "conf", "sql", "png",
    "jpg", "jpeg", "svg", "gif", "webp", "log", "env", "rst", "go", "rb", "pl",
}


def registered_projects(registry):
    projects = {}
    if not os.path.isfile(registry):
        return projects
    with open(registry, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            found = re.match(r"^- (.+?)(?: \[| - )(.*)$", line.rstrip("\n"))
            if found:
                projects[found.group(1).strip()] = line
    return projects


def site_of(host):
    host = (host or "").lower().rstrip(".")
    return host[4:] if host.startswith("www.") else host


def domain_tokens(text):
    tokens = set()
    for token in DOMAIN_TOKEN.findall(text.lower()):
        if token.rsplit(".", 1)[-1] in FILE_SUFFIXES:
            continue
        tokens.add(site_of(token))
    return tokens


def token_matches(host, token):
    return host_matches(site_of(host), token)


def read_domains(path, projects):
    entries = []
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8", errors="replace") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            fields = line.split()
            if len(fields) != 2:
                sys.stderr.write("%s:%d: expected `<domain>[:<port>] <project>`\n" % (path, number))
                sys.exit(2)
            domain, project = fields[0].lower(), fields[1]
            if not re.match(r"^[a-z0-9.-]+(?::[0-9]{1,5})?$", domain):
                sys.stderr.write("%s:%d: invalid domain %r\n" % (path, number, fields[0]))
                sys.exit(2)
            if project not in projects:
                sys.stderr.write("%s:%d: %r is not a registered project\n" % (path, number, project))
                sys.exit(2)
            entries.append((domain, project))
    return entries


def route(args):
    url = opt(args, "--url")
    registry = opt(args, "--registry")
    projects_dir = opt(args, "--projects")
    domains_file = opt(args, "--domains")
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    port = parts.port
    projects = registered_projects(registry)

    def emit(kind, names, basis):
        print("route: %s" % kind)
        print("host: %s" % host)
        if kind == "project":
            print("project: %s" % names[0])
        elif names:
            print("candidates: %s" % ",".join(names))
        print("basis: %s" % basis)

    # 1. Explicit domain map: the longest matching entry wins.
    best_len = -1
    best = set()
    for domain, project in read_domains(domains_file, projects):
        if ":" in domain:
            name, entry_port = domain.split(":", 1)
            hit = host == name and port is not None and str(port) == entry_port
            weight = len(domain) + 1000
        else:
            hit = host_matches(host, domain)
            weight = len(domain)
        if not hit:
            continue
        if weight > best_len:
            best_len, best = weight, {project}
        elif weight == best_len:
            best.add(project)
    if best:
        names = sorted(best)
        if len(names) == 1:
            emit("project", names, "domain map %s" % DOMAINS_LABEL)
        else:
            emit("ambiguous", names, "domain map %s lists one domain for several projects" % DOMAINS_LABEL)
        return

    if not host or host == "localhost" or re.match(r"^[0-9.]+$|^[0-9a-f]*:[0-9a-f:.]*$", host):
        emit("unrouted", [], "a local or address-only host names no project; map it in %s" % DOMAINS_LABEL)
        return

    # 2. Registry lines that mention the site.
    hits = sorted(name for name, line in projects.items() if any(token_matches(host, t) for t in domain_tokens(line)))
    if len(hits) == 1:
        emit("project", hits, "project registry entry mentions %s" % site_of(host))
        return
    if hits:
        emit("ambiguous", hits, "several project registry entries mention %s" % site_of(host))
        return

    # 3. Project docs that mention the site: evidence, not a mapping.
    doc_hits = []
    for name in sorted(projects):
        for doc in ("AGENTS.md", "README.md"):
            path = os.path.join(projects_dir, name, doc)
            if not os.path.isfile(path):
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                if any(token_matches(host, t) for t in domain_tokens(handle.read())):
                    doc_hits.append(name)
                    break
    if len(doc_hits) == 1:
        emit("inferred", doc_hits, "only %s's AGENTS.md or README.md mentions %s; confirm before mapping it in %s" % (doc_hits[0], site_of(host), DOMAINS_LABEL))
        return
    if doc_hits:
        emit("ambiguous", doc_hits, "several projects' docs mention %s" % site_of(host))
        return
    emit("unrouted", [], "no registered project mentions %s" % site_of(host))


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    command, args = argv[1], argv[2:]
    if command == "decode-eval" and len(args) == 1:
        decode_eval(args[0])
    elif command == "build":
        build(args)
    elif command == "match":
        match(args)
    elif command == "route":
        route(args)
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
