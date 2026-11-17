"""Blurs a rectangle of a framed README image, e.g. other people's names and avatars.

    python3 Tools/blur_region.py <image.png> <x0> <y0> <x1> <y1>    (pixels of the framed image)
"""
import sys

from PIL import Image, ImageFilter

path, box = sys.argv[1], tuple(int(v) for v in sys.argv[2:6])
image = Image.open(path)
image.paste(image.crop(box).filter(ImageFilter.GaussianBlur(9)), box[:2])
image.save(path, optimize=True)
