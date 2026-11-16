"""Contact sheet: each icon masked to an iOS squircle at 1024, 180 and 60 px."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

def squircle(size):
    s = size * 4
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 0.2237), fill=255)
    return m.resize((size, size), Image.LANCZOS)

def tile(img, size, bg):
    icon = img.convert("RGBA").resize((size, size), Image.LANCZOS)
    under = Image.new("RGBA", (size, size), bg)
    under.alpha_composite(icon)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(under, (0, 0), squircle(size))
    return out

files = [Path(p) for p in sys.argv[2:]]
bg_sheet = (236, 236, 240, 255)
W = 40 + len(files) * 460
sheet = Image.new("RGBA", (W, 640), bg_sheet)
for i, f in enumerate(files):
    img = Image.open(f)
    x = 40 + i * 460
    sheet.alpha_composite(tile(img, 420, (0, 0, 0, 255)), (x, 40))
    sheet.alpha_composite(tile(img, 120, (0, 0, 0, 255)), (x, 490))
    sheet.alpha_composite(tile(img, 60, (0, 0, 0, 255)), (x + 150, 520))
    sheet.alpha_composite(tile(img, 40, (0, 0, 0, 255)), (x + 240, 540))
sheet.convert("RGB").save(sys.argv[1])
