#!/usr/bin/env python3
"""Records the README demo GIF and the light/dark popover screenshots.

Launches the app in demo mode (INDICATORS_DEMO=1), captures its windows with `screencapture -l`
(so nothing else on your desktop ends up in the recording), composites them on a clean gradient
background and encodes a GIF with ffmpeg.

Requires: Pillow, ffmpeg. Output: docs/demo.gif, docs/popover-light.png, docs/popover-dark.png
"""
import os, re, subprocess, sys, tempfile, time, pathlib
from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = ROOT / "build/Indicators.app/Contents/MacOS/Indicators"
DOCS = ROOT / "docs"
CANVAS = (1000, 720)
FPS = 6
START, DURATION = 3.5, 13.0  # demo script: expand @5s, settings @8s, keys @11.5s, close @15s


def launch(mode):
    subprocess.run(["pkill", "-x", "Indicators"], check=False)
    time.sleep(1)
    env = dict(os.environ, INDICATORS_DEMO="1", INDICATORS_APPEARANCE=mode)
    log = tempfile.NamedTemporaryFile("w+", delete=False, suffix=".log")
    proc = subprocess.Popen([str(BIN)], env=env, stdout=log, stderr=subprocess.STDOUT)
    return proc, log


def window_ids(log):
    log.seek(0)
    text = log.read()
    preview = re.search(r"WINDOW (\d+)", text)
    settings = re.search(r"SETTINGS_WINDOW (\d+)", text)
    return (int(preview.group(1)) if preview else None, int(settings.group(1)) if settings else None)


def capture(window_id, path):
    r = subprocess.run(["screencapture", "-x", "-o", "-l", str(window_id), str(path)], capture_output=True)
    return r.returncode == 0 and path.exists()


def background(mode):
    img = Image.new("RGB", CANVAS)
    draw = ImageDraw.Draw(img)
    top, bottom = ((28, 32, 46), (10, 12, 20)) if mode == "dark" else ((236, 240, 248), (204, 214, 232))
    for y in range(CANVAS[1]):
        t = y / CANVAS[1]
        draw.line([(0, y), (CANVAS[0], y)], fill=tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3)))
    return img


def compose(bg, preview, settings):
    frame = bg.copy()
    x = 40
    if preview:
        frame.paste(preview, (x, 40), preview if preview.mode == "RGBA" else None)
        x += preview.width + 24
    if settings:
        frame.paste(settings, (x, 40), settings if settings.mode == "RGBA" else None)
    return frame


def shrink(img, max_h=CANVAS[1] - 80):
    if img.height > max_h:
        ratio = max_h / img.height
        img = img.resize((int(img.width * ratio), max_h), Image.LANCZOS)
    return img


def record_gif():
    proc, log = launch("dark")
    frames_dir = pathlib.Path(tempfile.mkdtemp())
    bg = background("dark")
    time.sleep(START)
    frames = []
    t0 = time.time()
    i = 0
    while time.time() - t0 < DURATION:
        preview_id, settings_id = window_ids(log)
        preview = settings = None
        if preview_id and capture(preview_id, frames_dir / "p.png"):
            preview = shrink(Image.open(frames_dir / "p.png").convert("RGBA"))
        if settings_id and capture(settings_id, frames_dir / "s.png"):
            settings = shrink(Image.open(frames_dir / "s.png").convert("RGBA"))
        out = frames_dir / f"frame_{i:04d}.png"
        compose(bg, preview, settings).save(out)
        frames.append(out)
        i += 1
        time.sleep(max(0, 1 / FPS - 0.05))
    proc.kill()
    DOCS.mkdir(exist_ok=True)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(frames_dir / "frame_%04d.png"),
        "-vf", "scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
        str(DOCS / "demo.gif"),
    ], check=True)
    print(f"wrote {DOCS / 'demo.gif'} ({len(frames)} frames)")


def screenshot(mode):
    proc, log = launch(mode)
    time.sleep(7)
    preview_id, _ = window_ids(log)
    out = DOCS / f"popover-{mode}.png"
    if preview_id and capture(preview_id, out):
        print(f"wrote {out}")
    proc.kill()


if __name__ == "__main__":
    if not BIN.exists():
        sys.exit("build the app first: make app")
    record_gif()
    for mode in ("light", "dark"):
        screenshot(mode)
    subprocess.run(["pkill", "-x", "Indicators"], check=False)
