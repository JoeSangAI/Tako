#!/usr/bin/env python3
"""Make review strips from Tako's off-screen, time-stamped showcase frames.

Usage: python3 scripts/showcase_strips.py /tmp/frames
The PNGs in the supplied temporary directory remain the originals.
"""
from pathlib import Path
import argparse
from PIL import Image, ImageOps, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument("folder", type=Path)
args = parser.parse_args()

for scene in ("doodle", "highfive-hit", "highfive-miss"):
    paths = []
    for index in range(1, 9):
        candidates = list(args.folder.glob(f"seq-{scene}-{index:02d}-*s.png"))
        if not candidates:
            raise SystemExit(f"{scene}: missing frame {index}")
        paths.append(max(candidates, key=lambda path: path.stat().st_mtime_ns))
    panels = []
    for path in paths:
        image = Image.open(path).convert("RGB")
        # Renderer produces a 2x bitmap of 960x500 points; the action is at the lower centre or left edge.
        crop = image.crop((720, 680, 1200, 1000))
        label = path.stem.rsplit("-", 1)[-1]
        ImageDraw.Draw(crop).text((8, 5), label, fill=(80, 80, 80))
        panels.append(crop)
    for scale, suffix in ((0.5, "real"), (1, "2x")):
        tiles = [ImageOps.scale(p, scale, resample=Image.Resampling.LANCZOS) if scale != 1 else p for p in panels]
        strip = Image.new("RGB", (tiles[0].width * 8, tiles[0].height), "white")
        frame_dir = args.folder / f"frames-{suffix}"
        frame_dir.mkdir(exist_ok=True)
        for index, tile in enumerate(tiles):
            tile.save(frame_dir / paths[index].name)
            strip.paste(tile, (index * tile.width, 0))
        strip.save(args.folder / f"{scene}-{suffix}-strip.png")

for index in range(4):
    source = args.folder / f"doodle-finished-{index}.png"
    image = Image.open(source).convert("RGB").crop((720, 680, 1200, 1000))
    image.save(args.folder / f"doodle-finished-{index}-2x.png")
    ImageOps.scale(image, 0.5, resample=Image.Resampling.LANCZOS).save(args.folder / f"doodle-finished-{index}-real.png")
