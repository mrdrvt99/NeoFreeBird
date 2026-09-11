#!/usr/bin/env python3
"""Override vector glyphs inside the app's TwitterAppearance bundles.

Usage: override_appearance_svgs.py <app_dir> <svg_dir>
"""

import os
import shutil
import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: override_appearance_svgs.py <app_dir> <svg_dir>\n")
        return 2
    app_dir, svg_dir = sys.argv[1], sys.argv[2]

    # Index the VectorImages/main glyphs of every TwitterAppearance bundle by
    # basename (twemoji and other subfolders are intentionally left alone). Each
    # entry also records the bundle root so we can drop its stale seal later.
    # A build that keeps no loose glyphs simply leaves this empty.
    index = {}  # basename -> [(path, bundle_root)]
    for root, dirs, _files in os.walk(app_dir):
        dirs[:] = [d for d in dirs if d != "__MACOSX"]
        for d in dirs:
            if "TwitterAppearance" in d and d.endswith(".bundle"):
                broot = os.path.join(root, d)
                maindir = os.path.join(broot, "VectorImages", "main")
                if not os.path.isdir(maindir):
                    continue
                for f in os.listdir(maindir):
                    if f.lower().endswith(".svg"):
                        index.setdefault(f, []).append((os.path.join(maindir, f), broot))

    # Apply each provided svg to all matching targets.
    modified_bundles = set()
    replaced = 0
    for sroot, sdirs, sfiles in os.walk(svg_dir):
        sdirs[:] = [d for d in sdirs if d != "__MACOSX"]
        for f in sfiles:
            if f.startswith("._") or not f.lower().endswith(".svg"):
                continue
            targets = index.get(f, [])
            for path, broot in targets:
                shutil.copyfile(os.path.join(sroot, f), path)
                modified_bundles.add(broot)
            if targets:
                replaced += 1

    # A resource bundle's own _CodeSignature seals its files by hash; once we
    # replace glyphs that seal is stale. Drop it so the containing app/appex
    # re-seal (by cyan and the installer) is authoritative and nothing chokes on
    # a mismatch. The bundle stays valid, sealed by its parent's CodeResources.
    for broot in sorted(modified_bundles):
        shutil.rmtree(os.path.join(broot, "_CodeSignature"), ignore_errors=True)

    print("glyphs-replaced: %d" % replaced)
    return 0


if __name__ == "__main__":
    sys.exit(main())
