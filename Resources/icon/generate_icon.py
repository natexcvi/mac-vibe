#!/usr/bin/env python3
"""
Generate Resources/AppIcon.icns for MacVibe.

Design follows current Apple direction for macOS app icons:
  - Squircle silhouette (rounded-rectangle approximation, ~22.5% corner radius
    on a 1024 canvas — visually indistinguishable from Apple's continuous-
    curvature squircle at icon scale).
  - Vibrant radial-gradient background (off-center highlight, deeper toward
    the lower-right) — matches the "soft 3D" feel of macOS Tahoe icons.
  - Subtle glassy specular highlight at the top.
  - White waveform glyph centered, communicating "voice in".

Outputs a full AppIcon.iconset (10 standard sizes) and runs `iconutil` to
produce Resources/AppIcon.icns.
"""
from __future__ import annotations

import math
import os
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
ICONSET = os.path.join(HERE, "AppIcon.iconset")
ICNS = os.path.normpath(os.path.join(HERE, "..", "AppIcon.icns"))
PNG_PREVIEW = os.path.join(HERE, "AppIcon-preview.png")

CORNER_RADIUS_FRACTION = 0.225  # ≈ Apple's macOS squircle approximation
INNER_HIGHLIGHT = (118, 102, 255)  # vivid violet
OUTER_DEEP = (28, 18, 86)          # deep indigo


def squircle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size, size), radius=int(size * CORNER_RADIUS_FRACTION), fill=255
    )
    return mask


def radial_gradient(size: int, inner: tuple, outer: tuple) -> Image.Image:
    """Render a radial gradient at low resolution then upscale (fast + smooth)."""
    work = 256
    img = Image.new("RGB", (work, work))
    px = img.load()
    cx, cy = work * 0.30, work * 0.27  # off-center toward upper-left
    max_d = math.hypot(work - cx, work - cy)
    for y in range(work):
        for x in range(work):
            d = math.hypot(x - cx, y - cy) / max_d
            t = min(d ** 1.25, 1.0)
            px[x, y] = tuple(
                int(inner[i] + (outer[i] - inner[i]) * t) for i in range(3)
            )
    return img.resize((size, size), Image.LANCZOS)


def add_glass_highlight(img: Image.Image, mask: Image.Image) -> Image.Image:
    """Soft white ellipse near the top, blurred — Apple's classic icon glaze."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.ellipse(
        (
            int(SIZE * 0.05),
            -int(SIZE * 0.50),
            int(SIZE * 0.95),
            int(SIZE * 0.42),
        ),
        fill=(255, 255, 255, 38),
    )
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=SIZE * 0.045))
    masked = Image.new("RGBA", img.size, (0, 0, 0, 0))
    masked.paste(overlay, (0, 0), mask)
    img.alpha_composite(masked)
    return img


def draw_waveform(img: Image.Image) -> Image.Image:
    """Five vertical capsule bars with a natural amplitude envelope."""
    d = ImageDraw.Draw(img)

    bar_w = int(SIZE * 0.078)
    gap = int(SIZE * 0.048)
    bar_count = 5
    total_w = bar_count * bar_w + (bar_count - 1) * gap
    start_x = (SIZE - total_w) // 2
    cy = SIZE // 2

    # Symmetric, peaks at center: short → tall → short
    heights = [0.32, 0.58, 0.74, 0.58, 0.32]

    for i, hf in enumerate(heights):
        h = int(SIZE * hf)
        x0 = start_x + i * (bar_w + gap)
        x1 = x0 + bar_w
        y0 = cy - h // 2
        y1 = cy + h // 2
        d.rounded_rectangle((x0, y0, x1, y1), radius=bar_w // 2, fill=(255, 255, 255, 245))

    return img


def main() -> None:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bg = radial_gradient(SIZE, INNER_HIGHLIGHT, OUTER_DEEP)
    mask = squircle_mask(SIZE)
    canvas.paste(bg, (0, 0), mask)
    canvas = add_glass_highlight(canvas, mask)
    canvas = draw_waveform(canvas)

    canvas.save(PNG_PREVIEW)

    # Apple-required iconset sizes.
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    if os.path.exists(ICONSET):
        shutil.rmtree(ICONSET)
    os.makedirs(ICONSET)

    for px, name in sizes:
        canvas.resize((px, px), Image.LANCZOS).save(os.path.join(ICONSET, name))

    subprocess.check_call(["iconutil", "-c", "icns", "-o", ICNS, ICONSET])
    print(f"✓ wrote {ICNS}")
    print(f"  preview: {PNG_PREVIEW}")


if __name__ == "__main__":
    main()
