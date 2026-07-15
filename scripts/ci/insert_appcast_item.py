#!/usr/bin/env python3
"""Insert a new <item> at the top of appcast.xml (newest first).

Standalone counterpart of the inline Python in scripts/release.sh, so both the
local release and the GitHub Actions cloud release build identical appcast
entries. Keep the two in sync if you change the item format.

Usage:
    insert_appcast_item.py <appcast> <tag> <short_ver> <build> \
        <ed_sig> <length> <dl_url> <notes_link> <prerelease> <notes_md_file>

Bilingual notes: the notes_md_file may carry several language sections delimited
by "<!-- lang:xx -->" lines. Each becomes its own <description xml:lang="xx">.
No markers → a single unlocalized <description> (back-compat).
"""
import sys
import html
import re
from datetime import datetime, timezone

(appcast, tag, short_ver, build, ed_sig, length,
 dl_url, notes_link, prerelease, notes_md_file) = sys.argv[1:]

pub_date = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
channel_line = f"      <sparkle:channel>{prerelease}</sparkle:channel>\n" if prerelease else ""


# ── Minimal Markdown → HTML for the release-notes pane ──────────────
def md_to_html(md):
    def inline(s):
        s = html.escape(s, quote=False)
        s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)   # bold first…
        s = re.sub(r'\*([^*\n]+?)\*', r'<em>\1</em>', s)          # …then *italic*
        s = re.sub(r'`(.+?)`', r'<code>\1</code>', s)
        s = re.sub(r'(https?://[^\s<]+)', r'<a href="\1">\1</a>', s)  # bare URLs → links
        return s
    out, in_list = [], False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append('</ul>')
            in_list = False
    for raw in md.splitlines():
        line = raw.rstrip()
        heading = re.match(r'^(#{1,6})\s+(.*)$', line)
        bullet = re.match(r'^[-*]\s+(.*)$', line)
        if bullet:
            if not in_list:
                out.append('<ul>')
                in_list = True
            out.append(f'<li>{inline(bullet.group(1))}</li>')
        elif re.match(r'^([-*_])\1{2,}\s*$', line):   # --- *** ___ → rule
            close_list()
            out.append('<hr>')
        elif heading:
            close_list()
            lvl = min(len(heading.group(1)) + 1, 6)  # bump so top-level "#" isn't huge
            out.append(f'<h{lvl}>{inline(heading.group(2))}</h{lvl}>')
        elif line:
            close_list()
            out.append(f'<p>{inline(line)}</p>')
        else:
            close_list()
    close_list()
    return '\n'.join(out)


# ── Localized notes: split on "<!-- lang:xx -->" markers ────────────
def split_langs(md):
    parts = re.split(r'(?im)^[ \t]*<!--[ \t]*lang:([a-z]{2})[ \t]*-->[ \t]*$', md)
    if len(parts) == 1:
        return [(None, md)]            # no markers
    it = iter(parts[1:])               # parts[0] = preamble before first marker
    return [(lang.lower(), chunk) for lang, chunk in zip(it, it) if chunk.strip()]


FOOTER = {'en': 'View full release on GitHub →', 'zh': '在 GitHub 查看完整更新 →'}


def build_description(lang, chunk):
    notes_html = md_to_html(chunk)
    foot = FOOTER.get(lang or 'en', FOOTER['en'])
    notes_html += f'\n<p><a href="{html.escape(notes_link)}">{foot}</a></p>'
    notes_html = notes_html.replace(']]>', ']]&gt;')   # CDATA can't hold "]]>"
    lang_attr = f' xml:lang="{lang}"' if lang else ''
    return (f"      <description{lang_attr}><![CDATA[\n"
            f"{notes_html}\n"
            "      ]]></description>\n")


with open(notes_md_file, 'r', encoding='utf-8') as f:
    description = "".join(build_description(l, c) for l, c in split_langs(f.read()))

item = (
    "    <item>\n"
    f"      <title>{tag}</title>\n"
    f"      <pubDate>{pub_date}</pubDate>\n"
    f"      <sparkle:version>{build}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{short_ver}</sparkle:shortVersionString>\n"
    "      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n"
    f"{channel_line}"
    f"{description}"
    f"      <enclosure url=\"{dl_url}\" length=\"{length}\" "
    f"type=\"application/octet-stream\" sparkle:edSignature=\"{ed_sig}\" />\n"
    "    </item>\n"
)

with open(appcast, 'r', encoding='utf-8') as f:
    src = f.read()

marker = "<!-- BEGIN-ITEMS (release.sh inserts new entries here, newest first) -->\n"
if marker not in src:
    sys.exit(f"ERROR: marker line not found in {appcast}; refuse to mangle it.")

new_src = src.replace(marker, marker + item, 1)
with open(appcast, 'w', encoding='utf-8') as f:
    f.write(new_src)

print(f"Inserted appcast item for {tag} (build {build}).")
