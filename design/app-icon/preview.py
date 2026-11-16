#!/usr/bin/env python3
"""Lays the rendered icons (png/) out on one sheet, masked to the iOS icon shape, large and at
home-screen size on a light and a dark wallpaper. Writes options.png."""
import pathlib

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).parent
OPTIONS = [("b-laurel", "B · Laurel"), ("c-meander", "C · Greek key")]
VARIANTS = [("", "Default"), ("-dark", "Dark"), ("-tinted", "Tinted (iOS recolours it)")]
BIG, SMALL, PAD = 280, 120, 40  # SMALL is a 60 pt home-screen icon at 2x


def font(size):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def masked(img, size):
    """The icon at size px, clipped to a rounded square close to iOS's mask."""
    k = 4
    mask = Image.new("L", (size * k, size * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * k - 1, size * k - 1), radius=int(size * k * 0.2237), fill=255)
    out = img.convert("RGB").resize((size, size), Image.LANCZOS)
    out.putalpha(mask.resize((size, size), Image.LANCZOS))
    return out


def main():
    title, label = font(30), font(20)
    col = BIG + PAD
    width = PAD + len(VARIANTS) * col + 2 * (SMALL + 2 * PAD) + PAD
    row = BIG + 3 * PAD
    sheet = Image.new("RGB", (width, PAD + len(OPTIONS) * row), "#F4F1EA")
    draw = ImageDraw.Draw(sheet)
    for r, (stem, name) in enumerate(OPTIONS):
        y = PAD + r * row
        draw.text((PAD, y), name, font=title, fill="#1A1A1A")
        y += 50
        for c, (suffix, vname) in enumerate(VARIANTS):
            x = PAD + c * col
            icon = masked(Image.open(HERE / "png" / f"{stem}{suffix}.png"), BIG)
            sheet.paste(icon, (x, y), icon)
            draw.text((x, y + BIG + 8), vname, font=label, fill="#555555")
        # Home-screen size on light and dark wallpapers.
        x0 = PAD + len(VARIANTS) * col
        for i, (wall, suffix) in enumerate((("#DCE6F0", ""), ("#1C1C22", "-dark"))):
            x = x0 + i * (SMALL + 2 * PAD)
            draw.rounded_rectangle((x, y, x + SMALL + 2 * PAD, y + BIG), radius=24, fill=wall)
            icon = masked(Image.open(HERE / "png" / f"{stem}{suffix}.png"), SMALL)
            sheet.paste(icon, (x + PAD, y + (BIG - SMALL) // 2), icon)
        draw.text((x0, y + BIG + 8), "Home screen size", font=label, fill="#555555")
    sheet.save(HERE / "options.png")
    print(HERE / "options.png", sheet.size)


if __name__ == "__main__":
    main()
