#!/usr/bin/env python3
"""Builds the GitHub Pages site: one page per language from site/template.html and site/i18n/<lang>.json.

English goes to the root, every other language to /<lang>/. Every language must translate every string the
template uses, so a missing translation fails the build instead of leaving a {{placeholder}} on the page.

Usage: scripts/build-site.py [output dir, default .build/site]
"""

import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
# Order of the language menu. English first, the rest as the app lists them.
LANGUAGES = ["en", "ru", "de", "es", "fr", "it", "ja", "ko", "zh-Hans"]
DEFAULT = "en"

# Sends a first-time visitor of the English root page to their own language; a language picked from the menu wins.
REDIRECT = """  <script>
    try {
      var supported = %s;
      if (!localStorage.getItem("escapp-language")) {
        var wanted = (navigator.languages || [navigator.language]).map(function (l) {
          l = l.toLowerCase();
          return l.indexOf("zh") === 0 ? "zh-Hans" : l.split("-")[0];
        });
        for (var i = 0; i < wanted.length; i++) {
          if (wanted[i] === "en") break;
          if (supported.indexOf(wanted[i]) >= 0) { location.replace(wanted[i] + "/"); break; }
        }
      }
    } catch (e) {}
  </script>"""

REMEMBER = ' onclick="try{localStorage.setItem(\'escapp-language\',\'%s\')}catch(e){}"'


def path_of(lang):
    return "" if lang == DEFAULT else lang + "/"


def render(template, lang, strings, names):
    root = "" if lang == DEFAULT else "../"
    links = []
    alternates = []
    for other in LANGUAGES:
        href = root + path_of(other) if path_of(other) else root or "./"
        current = ' aria-current="true"' if other == lang else ""
        links.append(
            f'              <li><a href="{href}" lang="{other}" hreflang="{other}"{current}'
            f"{REMEMBER % other}>{names[other]}</a></li>"
        )
        alternates.append(f'  <link rel="alternate" hreflang="{other}" href="{href}">')
    values = dict(strings)
    values.update(
        lang=lang,
        root=root,
        languages="\n".join(links),
        alternates="\n".join(alternates),
        redirect=REDIRECT % json.dumps([l for l in LANGUAGES if l != DEFAULT]) if lang == DEFAULT else "",
    )

    def fill(match):
        key = match.group(1)
        if key not in values:
            sys.exit(f"{lang}.json has no {key!r}")
        return values[key]

    return re.sub(r"\{\{(\w+)\}\}", fill, template)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".build" / "site"
    template = (SITE / "template.html").read_text()
    strings = {lang: json.loads((SITE / "i18n" / f"{lang}.json").read_text()) for lang in LANGUAGES}
    names = {lang: strings[lang]["language_name"] for lang in LANGUAGES}
    expected = set(strings[DEFAULT])
    for lang, table in strings.items():
        missing = expected - set(table)
        extra = set(table) - expected
        if missing or extra:
            sys.exit(f"{lang}.json: missing {sorted(missing)}, unknown {sorted(extra)}")
        for kind in ("library", "setup"):
            if not (SITE / "screens" / f"{kind}-{lang}.webp").exists():
                sys.exit(f"site/screens/{kind}-{lang}.webp is missing")

    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(SITE, out, ignore=shutil.ignore_patterns("template.html", "i18n", ".DS_Store"))
    for lang in LANGUAGES:
        page = out / path_of(lang) / "index.html"
        page.parent.mkdir(parents=True, exist_ok=True)
        page.write_text(render(template, lang, strings[lang], names))
    print(f"Built {len(LANGUAGES)} languages into {out}")


if __name__ == "__main__":
    main()
