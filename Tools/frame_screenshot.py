"""Frames a Vapor snapshot like a macOS window: rounded corners, a hairline edge and a soft shadow on a
transparent canvas, so it sits well on both GitHub themes.

    python3 Tools/frame_screenshot.py <in.png> <out.png> [small]
"""
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
small = len(sys.argv) > 3 and sys.argv[3] == "small"

shot = Image.open(src).convert("RGBA")
# Snapshots are 2x; the hero keeps full resolution, gallery images are halved to keep the repo light.
if small:
    shot = shot.resize((shot.width // 2, shot.height // 2), Image.LANCZOS)
scale = shot.width / 1320
radius, pad, blur = round(20 * scale), round(56 * scale), round(28 * scale)

mask = Image.new("L", shot.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1], radius, fill=255)
shot.putalpha(ImageChops.multiply(shot.getchannel("A"), mask))
edge = Image.new("RGBA", shot.size, (0, 0, 0, 0))
ImageDraw.Draw(edge).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1], radius,
                                       outline=(255, 255, 255, 34), width=max(1, round(scale)))
shot = Image.alpha_composite(shot, edge)

canvas = Image.new("RGBA", (shot.width + 2 * pad, shot.height + 2 * pad), (0, 0, 0, 0))
shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([pad, pad + blur // 3, pad + shot.width, pad + shot.height + blur // 3],
                                         radius, fill=(0, 0, 0, 120))
canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(blur)))
canvas.alpha_composite(shot, (pad, pad))
canvas.save(dst, optimize=True)
