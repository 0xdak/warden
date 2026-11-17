#!/usr/bin/env python3
"""Rasterise public/favicon.svg (the logo master) into the committed PNG/ICO icons.
Needs Google Chrome (headless) and macOS `sips`. Run after changing the logo:  python3 tools/make_icons.py"""
import base64
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from build import find_chrome, crop_png_rows  # noqa: E402

PUBLIC = ROOT / "public"


def main():
    chrome = find_chrome()
    if not chrome or not shutil.which("sips"):
        sys.exit("needs Chrome and sips")
    svg = (PUBLIC / "favicon.svg").read_text(encoding="utf-8")
    uri = "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()
    doc = f'<!doctype html><html><head><style>html,body{{margin:0;background:transparent}}img{{display:block}}</style></head><body><img src="{uri}" width="512" height="512"></body></html>'
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "i.html"
        page.write_text(doc)
        shot = Path(tmp) / "s.png"
        subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--default-background-color=00000000", "--window-size=512,812", f"--user-data-dir={tmp}/p",
                        f"--screenshot={shot}", page.as_uri()], check=True, capture_output=True, timeout=90)
        crop_png_rows(shot, 512)
        # crop width too: sips can crop to 512x512 from the top-left via --cropToHeightWidth (centered), so pad-free:
        subprocess.run(["sips", "-c", "512", "512", "--cropOffset", "0", "0", str(shot)], check=True, capture_output=True)
        shutil.copy(shot, PUBLIC / "icon-512.png")
        for size, name in ((180, "apple-touch-icon.png"), (32, "favicon-32.png")):
            out = PUBLIC / name
            shutil.copy(shot, out)
            subprocess.run(["sips", "-z", str(size), str(size), str(out)], check=True, capture_output=True)
    png = (PUBLIC / "favicon-32.png").read_bytes()
    ico = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 32, 32, 0, 0, 1, 32, len(png), 22) + png
    (PUBLIC / "favicon.ico").write_bytes(ico)
    print("icons written to public/")


if __name__ == "__main__":
    main()
