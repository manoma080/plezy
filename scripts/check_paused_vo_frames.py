#!/usr/bin/env python3
"""Check captured 1080x1920 equalizer-mock paused transition frames.

Run against screenshots captured after each saturation activation/reset. This
fixture's test pattern occupies x=80..1000,y=660..850 and is never black there.
Not a general-purpose video black-frame detector.
"""
import sys
from pathlib import Path
from PIL import Image, ImageStat

failed = []
for arg in sys.argv[1:]:
    path = Path(arg)
    image = Image.open(path).convert('RGB')
    if image.size != (1080, 1920):
        raise SystemExit(f'{path}: unexpected dimensions {image.size}')
    mean = sum(ImageStat.Stat(image.crop((80, 660, 1000, 850))).mean) / 3
    print(f'{path}: video mean={mean:.2f} {"BLACK" if mean < 5 else "visible"}')
    if mean < 5:
        failed.append(path)
if not sys.argv[1:]:
    raise SystemExit('provide screenshot paths')
raise SystemExit(bool(failed))
