#!/usr/bin/env python3
"""IPA branding modifications applied to a freshly built .ipa/.tipa.

This is a standalone port of the former ipa-branding.sh. rebrand.sh invokes it
as a subprocess on an already built IPA/TIPA:

    RESOURCE_PACK=... TWITTER_BRANDING=1 python3 ipa_branding.py <ipa_path>

It unpacks the IPA once, applies every enabled step — the theme pack in
RESOURCE_PACK and, when TWITTER_BRANDING=1, the "Twitter" display name — then
repackages once. When no branding is enabled it exits 0 without touching the
IPA. A non-zero exit means a requested step failed; rebrand.sh treats that as
fatal.

The sibling helper scripts live alongside this file in branding/, so they are
resolved relative to this file rather than the caller.
"""

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

BRANDING_DIR = Path(__file__).resolve().parent

# Pinned scar release used for Assets.car work when no binary is available
# locally (https://github.com/theacrat/scar).
SCAR_VERSION = "v0.1.0"
SCAR_URL = "https://github.com/theacrat/scar/releases/download/{v}/scar-{v}-{triple}.tar.gz"

# Pinned resvg release, used to rasterize a pack's glyphs into the bitmap
# renditions that back a catalog's vector glyphs (https://github.com/linebender/resvg).
RESVG_VERSION = "v0.48.1"
RESVG_URL = "https://github.com/linebender/resvg/releases/download/{v}/resvg-{asset}"

def err(message):
    print(f"Error: {message}", file=sys.stderr)


class BrandingError(Exception):
    """Raised for a failed branding step; maps to a fatal non-zero exit."""


def _have(cmd):
    return shutil.which(cmd) is not None


def _run(args, **kwargs):
    """Run a command, returning True on success (exit 0)."""
    return subprocess.run(args, **kwargs).returncode == 0


def _run_counting(args, **kwargs):
    """Run a helper that ends its output with "glyphs-replaced: N".

    Returns the count, or None if the helper failed. Its output is echoed so
    progress and warnings still reach the console.
    """
    marker = "glyphs-replaced:"
    res = subprocess.run(args, capture_output=True, text=True, **kwargs)
    count = None
    for line in res.stdout.splitlines():
        if line.startswith(marker):
            count = int(line.split(":", 1)[1])
        else:
            print(line)
    sys.stderr.write(res.stderr)
    return None if res.returncode != 0 else count


def _find(root, predicate):
    """True if any file under root satisfies predicate(Path)."""
    root = Path(root)
    if not root.exists():
        return False
    for path in root.rglob("*"):
        if path.is_file() and predicate(path):
            return True
    return False


def _is_apple_double(path):
    return path.name.startswith("._")


# --- display name -----------------------------------------------------------

def _set_display_name_in_app(appdir):
    """Force the on-device app name back to "Twitter"."""
    plist = appdir / "Info.plist"
    if not plist.is_file():
        raise BrandingError("Branding: could not locate app Info.plist")

    # plistlib reads/writes both binary and XML plists, so no macOS-only plist
    # tools are needed. IPA Info.plists are binary, so we write binary back.
    with open(plist, "rb") as f:
        data = plistlib.load(f)
    data["CFBundleDisplayName"] = "Twitter"
    with open(plist, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)


# --- resource pack ----------------------------------------------------------

def _apply_resource_pack_to_app(appdir, workdir, zip_path):
    """Overlay replacement images/glyphs from a zip onto the app.

    The pack is a .zip with two optional subfolders plus optional root files:
      icons/  loose images merged into the app's Assets.car (see
              scar_merge.py). A flat zip (images at the root, no icons/
              folder) is still treated as icons.
      svgs/   vector glyphs copied over matching TwitterAppearance files (see
              override_appearance_svgs.py).
      <root>  non-image files at the zip root (e.g. LaunchScreen.nib) overwrite
              the same-named file in the app root.
    """
    zip_path = Path(zip_path)
    if not zip_path.is_file():
        raise BrandingError(f"Branding: image pack not found: {zip_path}")
    if not _have("unzip"):
        raise BrandingError("Branding: 'unzip' is required for --resource-pack")

    zip_path = zip_path.resolve()
    plist = appdir / "Info.plist"
    car = appdir / "Assets.car"

    pack = workdir / "pack"
    if not _run(["unzip", "-q", "-o", str(zip_path), "-d", str(pack)]):
        raise BrandingError(f"Branding: failed to unpack image pack {zip_path}")

    icons_dir = pack / "icons"
    if not icons_dir.is_dir():
        icons_dir = pack  # back-compat: flat zip
    svgs_dir = pack / "svgs"

    have_icons = _find(
        icons_dir,
        lambda p: p.suffix.lower() in (".png", ".jpg", ".jpeg") and not _is_apple_double(p),
    )
    have_svgs = svgs_dir.is_dir() and _find(
        svgs_dir, lambda p: p.suffix.lower() == ".svg" and not _is_apple_double(p)
    )
    # Non-image files at the pack root overwrite the same-named file in the app
    # root. (Root images belong to the flat-zip icons back-compat path.)
    root_files = [
        p for p in pack.iterdir()
        if p.is_file()
        and p.suffix.lower() not in (".png", ".jpg", ".jpeg", ".svg")
        and not _is_apple_double(p)
    ]
    have_root = bool(root_files)

    if not (have_icons or have_svgs or have_root):
        raise BrandingError(
            "Branding: image pack has no icons/ images, svgs/ glyphs, or root files"
        )

    # --- icons/: merge into Assets.car ---
    if have_icons:
        if not car.is_file():
            raise BrandingError("Branding: app has no Assets.car to merge into")
        scar = _ensure_scar(workdir)
        python = _python_with_pillow()

        new_car = workdir / "new.car"
        if not _run([
            str(python), str(BRANDING_DIR / "scar_merge.py"),
            str(car), str(icons_dir), str(new_car),
            "--workdir", str(workdir), "--scar", str(scar),
        ]):
            raise BrandingError("Branding: failed to rebuild Assets.car")
        shutil.copyfile(new_car, car)

        # The merged catalog directory holds the final decoded art.
        catalog = workdir / "catalog"

        if plist.is_file():
            if not _run([
                sys.executable, str(BRANDING_DIR / "update_bundle_icons.py"),
                str(plist), str(catalog),
            ]):
                raise BrandingError("Branding: failed to update CFBundleIcons")

        # Sync the loose fallback icons in the app root (used by SpringBoard) to
        # the rebuilt catalog, else the home-screen icon stays stale.
        _run([
            sys.executable, str(BRANDING_DIR / "overwrite_loose_icons.py"),
            str(appdir), str(catalog),
        ])

    # --- svgs/: override the app's vector glyphs ---
    if have_svgs:
        _apply_glyphs_to_app(appdir, workdir, svgs_dir)

    # --- root files (e.g. LaunchScreen.nib): overwrite the same file in app root ---
    if have_root:
        for rf in root_files:
            dest = appdir / rf.name
            if dest.exists():
                if dest.is_dir():
                    shutil.rmtree(dest)
                else:
                    dest.unlink()
                shutil.copyfile(rf, dest)
            else:
                err(f"Branding: '{rf.name}' is not present in the app root; skipped.")


# Rendition names in a compiled catalog keep the glyph's original file name, so
# a cheap scan of the raw .car tells us which catalogs are worth decompiling.
_CAR_SVG_NAME = re.compile(rb"[A-Za-z0-9_.@%+\-]{1,120}\.svg")


def _glyph_catalogs(appdir, svgs_dir):
    """Asset catalogs under appdir holding vector glyphs the pack replaces."""
    wanted = {p.stem for p in Path(svgs_dir).rglob("*.svg") if not _is_apple_double(p)}
    hits = []
    for car in sorted(Path(appdir).rglob("Assets.car")):
        names = {m[:-4].decode("ascii", "replace")
                 for m in _CAR_SVG_NAME.findall(car.read_bytes())}
        if names & wanted:
            hits.append(car)
    return hits


def _apply_glyphs_to_app(appdir, workdir, svgs_dir):
    """Replace the app's UI glyphs with the pack's, wherever they live.

    Builds up to ~2023 kept them as loose files under
    TwitterAppearance_TwitterAppearance.bundle/VectorImages/main; newer ones
    compile them into asset catalogs (XIcons_XIconsAssets.bundle, plus a small
    private copy in some appexes). Both are attempted, and it is a failure only
    if neither replaced anything -- otherwise a layout change silently leaves
    the in-app icons untouched, which is exactly how this broke before.
    """
    replaced = _run_counting([
        sys.executable, str(BRANDING_DIR / "override_appearance_svgs.py"),
        str(appdir), str(svgs_dir),
    ])
    if replaced is None:
        raise BrandingError("Branding: failed to override TwitterAppearance glyphs")
    if replaced:
        print("glyphs: %d loose TwitterAppearance glyph(s) replaced" % replaced)

    catalogs = _glyph_catalogs(appdir, svgs_dir)
    if catalogs:
        scar = _ensure_scar(workdir)
        resvg = _ensure_resvg(workdir)
        python = _python_with_pillow()
        for index, car in enumerate(catalogs):
            # Each catalog gets its own scratch dir, since scar decompiles into
            # <workdir>/catalog and the icons step already claimed that one.
            sub = workdir / ("glyphs%d" % index)
            sub.mkdir(parents=True, exist_ok=True)
            new_car = sub / "new.car"
            where = car.relative_to(appdir.parent)
            count = _run_counting([
                str(python), str(BRANDING_DIR / "svg_merge.py"),
                str(car), str(svgs_dir), str(new_car),
                "--workdir", str(sub), "--scar", str(scar), "--resvg", str(resvg),
            ])
            if count is None:
                raise BrandingError("Branding: failed to rebuild %s" % where)
            if not count:
                continue
            shutil.copyfile(new_car, car)
            replaced += count
            print("glyphs: %d glyph(s) replaced in %s" % (count, where))
            # A resource bundle's own _CodeSignature seals its files by hash; the
            # rebuilt catalog makes that seal stale, so drop it and let the parent
            # app/appex re-seal be authoritative (same as the loose-glyph path).
            if car.parent.suffix == ".bundle":
                shutil.rmtree(car.parent / "_CodeSignature", ignore_errors=True)

    if not replaced:
        raise BrandingError(
            "Branding: none of the pack's svgs/ glyphs matched anything in this "
            "app (no loose TwitterAppearance glyphs and no matching asset "
            "catalog); the pack may be for a different app version"
        )


def _python_with_pillow():
    """Interpreter for the Pillow-dependent steps: a cached venv, bootstrapped
    with Pillow on first use (plain `pip install` is refused on
    externally-managed Pythons, e.g. Homebrew and Debian)."""
    devnull = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "neofreebird"
    venv = cache / "venv"
    venv_python = venv / "bin" / "python3"
    if venv_python.is_file() and _run([str(venv_python), "-c", "import PIL"], **devnull):
        return venv_python

    print("Branding: setting up a Python venv with Pillow (one-time)...")
    cache.mkdir(parents=True, exist_ok=True)
    if not _run([sys.executable, "-m", "venv", "--clear", str(venv)]):
        raise BrandingError(
            "Branding: could not create a venv for Pillow; install the venv "
            "module (e.g. python3-venv) or install Pillow for %s yourself" % sys.executable
        )
    if not _run([str(venv_python), "-m", "pip", "install", "--quiet", "Pillow"]):
        raise BrandingError(
            "Branding: could not install Pillow into %s; install Pillow for "
            "%s yourself" % (venv, sys.executable)
        )
    return venv_python


def _scar_triple():
    machine = os.uname().machine.lower()
    if sys.platform == "darwin" and machine == "arm64":
        return "aarch64-apple-darwin"
    if sys.platform.startswith("linux") and machine in ("x86_64", "amd64"):
        return "x86_64-unknown-linux-musl"
    if sys.platform.startswith("linux") and machine in ("aarch64", "arm64"):
        return "aarch64-unknown-linux-musl"
    return None


def _ensure_scar(workdir):
    """Locate the scar binary: $NFB_SCAR, then PATH, then download the pinned
    release build for this platform."""
    env = os.environ.get("NFB_SCAR")
    if env:
        if Path(env).is_file():
            return Path(env)
        raise BrandingError(f"Branding: NFB_SCAR points to a missing file: {env}")
    found = shutil.which("scar")
    if found:
        return Path(found)

    triple = _scar_triple()
    if not triple:
        raise BrandingError(
            "Branding: no scar release build for this platform; install scar "
            "(https://github.com/theacrat/scar) and put it in PATH or NFB_SCAR"
        )
    url = SCAR_URL.format(v=SCAR_VERSION, triple=triple)
    tgz = workdir / "scar.tar.gz"
    try:
        urllib.request.urlretrieve(url, tgz)
        with tarfile.open(tgz) as tf:
            tf.extract("scar", workdir)
    except (OSError, tarfile.TarError) as exc:
        raise BrandingError(f"Branding: failed to download scar from {url}: {exc}")
    scar = workdir / "scar"
    scar.chmod(0o755)
    return scar


def _resvg_asset():
    """resvg's release asset for this platform, or None if it ships none."""
    machine = os.uname().machine.lower()
    if sys.platform == "darwin":
        if machine == "arm64":
            return "macos-aarch64.zip"
        if machine == "x86_64":
            return "macos-x86_64.zip"
    elif sys.platform.startswith("linux") and machine in ("x86_64", "amd64"):
        return "linux-x86_64.tar.gz"
    return None


def _ensure_resvg(workdir):
    """Locate the resvg binary: $NFB_RESVG, then PATH, then download the pinned
    release build for this platform."""
    env = os.environ.get("NFB_RESVG")
    if env:
        if Path(env).is_file():
            return Path(env)
        raise BrandingError(f"Branding: NFB_RESVG points to a missing file: {env}")
    found = shutil.which("resvg")
    if found:
        return Path(found)

    asset = _resvg_asset()
    if not asset:
        raise BrandingError(
            "Branding: no resvg release build for this platform; install resvg "
            "(https://github.com/linebender/resvg) and put it in PATH or NFB_RESVG"
        )
    url = RESVG_URL.format(v=RESVG_VERSION, asset=asset)
    archive = workdir / ("resvg-" + asset)
    try:
        urllib.request.urlretrieve(url, archive)
        if asset.endswith(".zip"):
            with zipfile.ZipFile(archive) as zf:
                zf.extract("resvg", workdir)
        else:
            with tarfile.open(archive) as tf:
                tf.extract("resvg", workdir)
    except (OSError, KeyError, tarfile.TarError, zipfile.BadZipFile) as exc:
        raise BrandingError(f"Branding: failed to download resvg from {url}: {exc}")
    resvg = workdir / "resvg"
    resvg.chmod(0o755)
    return resvg


# --- entry point ------------------------------------------------------------

def apply_ipa_branding(ipa):
    """Unpack the IPA once, apply every enabled step, repackage once."""
    resource_pack = os.environ.get("RESOURCE_PACK", "")
    twitter_branding = os.environ.get("TWITTER_BRANDING", "0") == "1"
    if not resource_pack and not twitter_branding:
        return

    ipa = Path(ipa)
    if not ipa.is_file():
        raise BrandingError(f"Branding: IPA not found: {ipa}")
    if not _have("unzip"):
        raise BrandingError("Branding: 'unzip' is required")
    if not _have("zip"):
        raise BrandingError("Branding: 'zip' is required")

    workdir = Path(tempfile.mkdtemp())
    try:
        ipa_root = workdir / "ipa"
        if not _run(["unzip", "-q", str(ipa), "-d", str(ipa_root)]):
            raise BrandingError(f"Branding: failed to unpack {ipa}")

        payload = ipa_root / "Payload"
        apps = sorted(payload.glob("*.app")) if payload.is_dir() else []
        appdir = next((a for a in apps if a.is_dir()), None)
        if appdir is None:
            raise BrandingError(f"Branding: could not locate .app inside {ipa}")

        if resource_pack:
            _apply_resource_pack_to_app(appdir, workdir, resource_pack)
        if twitter_branding:
            _set_display_name_in_app(appdir)

        # Repackage once. Use the zip binary (not zipfile) to preserve symlinks
        # and permissions exactly as the original build produced them.
        ipa = ipa.resolve()
        tmp_ipa = ipa.with_name(ipa.name + ".branding.tmp")
        if tmp_ipa.exists():
            tmp_ipa.unlink()
        if not _run(["zip", "-qr", str(tmp_ipa), "Payload"], cwd=str(ipa_root)):
            if tmp_ipa.exists():
                tmp_ipa.unlink()
            raise BrandingError(f"Branding: failed to repackage {ipa}")
        os.replace(tmp_ipa, ipa)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main(argv):
    if len(argv) != 2:
        err("usage: ipa_branding.py <ipa_path>")
        return 2
    try:
        apply_ipa_branding(argv[1])
    except BrandingError as exc:
        err(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
