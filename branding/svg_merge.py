#!/usr/bin/env python3
"""Rebuild an asset catalog with its vector glyphs replaced, using scar + resvg.

Usage: svg_merge.py <Assets.car> <svg_dir> <out.car> --workdir DIR
                    [--scar BIN] [--resvg BIN]

Twitter used to ship its UI glyphs as loose .svg files inside
TwitterAppearance_TwitterAppearance.bundle/VectorImages/main (see
override_appearance_svgs.py). Recent builds compile them into asset catalogs
instead -- mainly XIcons_XIconsAssets.bundle/Assets.car, plus a small private
copy in some appexes -- so a loose-file overlay silently matches nothing.

In the catalog each glyph is one asset holding:
  - a "data" rendition (pixel_format SVG) with the vector source, and
  - one rasterized bitmap per scale, usually a crop of a packed atlas.

The app resolves glyphs with imageNamed:inBundle:, i.e. through the bitmaps, so
replacing only the vector source would change nothing on screen. For every
glyph named by the pack we therefore swap the vector source *and* re-render the
bitmaps from the new art with resvg at each rendition's exact pixel size.

Prints "glyphs-replaced: N" as its last line so the caller can tell a real
merge from a silent no-op.
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys

from PIL import Image

_ROOT_SVG = re.compile(rb"<svg\b[^>]*>", re.I)
_ROOT_FILL_NONE = re.compile(rb'\sfill\s*=\s*(["\'])none\1', re.I)


def run(cmd, *args):
    res = subprocess.run([cmd, *args], capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write("%s %s failed:\n%s\n%s\n"
                         % (os.path.basename(cmd), args[0], res.stdout, res.stderr))
        raise SystemExit(1)
    return res


_svg_cache = {}
_render_cache = {}


def normalized(svg):
    if svg not in _svg_cache:
        with open(svg, "rb") as fh:
            data = fh.read()
        m = _ROOT_SVG.search(data)
        if m:
            root = _ROOT_FILL_NONE.sub(b"", m.group(0))
            if root != m.group(0):
                data = data[:m.start()] + root + data[m.end():]
        _svg_cache[svg] = data
    return _svg_cache[svg]


def render(resvg, svg, w, h):
    key = (svg, w, h)
    if key not in _render_cache:
        res = subprocess.run(
            [resvg, "-w", str(w), "-h", str(h),
             "--resources-dir", os.path.dirname(os.path.abspath(svg)), "-", "-c"],
            input=normalized(svg), capture_output=True)
        if res.returncode != 0 or not res.stdout:
            sys.stderr.write("resvg failed on %s at %dx%d:\n%s\n"
                             % (svg, w, h, res.stderr.decode("utf-8", "replace")))
            raise SystemExit(1)
        im = Image.open(io.BytesIO(res.stdout)).convert("RGBA")
        if im.size != (w, h):
            canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            canvas.paste(im, ((w - im.width) // 2, (h - im.height) // 2))
            im = canvas
        _render_cache[key] = im
    return _render_cache[key]


def install(catalog, rend, svg, resvg):
    c = rend["content"]
    if c["type"] == "data":
        # The vector source itself. Only touch it when it really is one.
        target = c.get("file", "")
        if rend.get("pixel_format") != "SVG" and not target.lower().endswith(".svg"):
            return False
        with open(os.path.join(catalog, target), "wb") as dst:
            dst.write(normalized(svg))
        return True
    if c["type"] == "image":
        target, w, h = c["file"], rend["width"], rend["height"]
    elif c["type"] == "raw-payload" and c.get("preview") and c.get("edit_hash"):
        target, w, h = c["preview"], rend["width"], rend["height"]
    elif c["type"] == "link" and c.get("preview") and c.get("edit_hash"):
        target, (w, h) = c["preview"], c["rect"][2:4]
    else:
        return False
    if w < 1 or h < 1:
        return False
    render(resvg, svg, w, h).save(os.path.join(catalog, target))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("car")
    ap.add_argument("svg_dir")
    ap.add_argument("out_car")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--scar", default=os.environ.get("NFB_SCAR", "scar"))
    ap.add_argument("--resvg", default=os.environ.get("NFB_RESVG", "resvg"))
    args = ap.parse_args()

    # Pack glyphs by asset name (the file stem), first one wins.
    svgs = {}
    for root, dirs, files in os.walk(args.svg_dir):
        dirs[:] = [d for d in dirs if d != "__MACOSX"]
        for f in sorted(files):
            if f.startswith("._") or not f.lower().endswith(".svg"):
                continue
            svgs.setdefault(os.path.splitext(f)[0], os.path.join(root, f))

    catalog = os.path.join(args.workdir, "catalog")
    run(args.scar, "decompile", args.car, "--out", catalog)
    with open(os.path.join(catalog, "manifest.json")) as fh:
        manifest = json.load(fh)

    by_ident = {}
    for r in manifest["renditions"]:
        by_ident.setdefault(r["key"].get("identifier"), []).append(r)

    replaced = 0
    for facet in manifest["facets"]:
        svg = svgs.get(facet["name"])
        if not svg:
            continue
        count = sum(install(catalog, r, svg, args.resvg)
                    for r in by_ident.get(facet["attributes"].get("identifier"), []))
        if count:
            replaced += 1

    if replaced:
        run(args.scar, "compile", catalog, "--out", args.out_car)
    print("glyphs-replaced: %d" % replaced)
    return 0


if __name__ == "__main__":
    sys.exit(main())
