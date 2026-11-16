#!/usr/bin/env python3
"""Draws the app icon options as 1024 x 1024 SVGs in svg/. Render them with render.swift.

Deliberately unlike WHOOP's marks: no W, no wordmark, no black-and-white, no strap,
no score dials or rings. Also unlike Apple Health's heart on white.

Each option comes in three appearances for iOS 18+: default, dark, and tinted
(a grey mark on black, which iOS recolours with the user's tint).
"""
import math
import pathlib

HERE = pathlib.Path(__file__).parent
S = 1024

NAVY = ("#1B2647", "#0D1429")
NIGHT = ("#10131C", "#05070C")
GOLD = ("#F3D27F", "#C7953B")
AEGEAN = ("#2161A0", "#123A66")
CREAM = "#F4E7CB"
TINT_MARK = "#E6E6E6"


def doc(defs, body, bg_fill):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">'
            f'<defs>{defs}</defs><rect width="{S}" height="{S}" fill="{bg_fill}"/>{body}</svg>')


def vgrad(gid, top, bottom):
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="{S}">'
            f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>')


def cubic(p0, p1, p2, p3, t):
    """Point and heading (degrees) at t on a cubic Bézier."""
    u = 1 - t
    x = u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0]
    y = u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]
    dx = 3 * u * u * (p1[0] - p0[0]) + 6 * u * t * (p2[0] - p1[0]) + 3 * t * t * (p3[0] - p2[0])
    dy = 3 * u * u * (p1[1] - p0[1]) + 6 * u * t * (p2[1] - p1[1]) + 3 * t * t * (p3[1] - p2[1])
    return (x, y), math.degrees(math.atan2(dy, dx))


def leaf(at, heading, length, width, fill):
    L, w = length, width
    d = f"M 0 0 Q {L * 0.45:.1f} {-w:.1f} {L:.1f} 0 Q {L * 0.45:.1f} {w:.1f} 0 0 Z"
    return f'<path d="{d}" transform="translate({at[0]:.1f} {at[1]:.1f}) rotate({heading:.1f})" fill="{fill}"/>'


def laurel_pulse(mark, ground_defs, ground):
    """B: the heartbeat's trace grows into a victor's laurel."""
    pulse = ("M 150 610 L 300 610 C 318 610 328 566 352 566 C 376 566 386 610 404 610 L 440 610 "
             "L 468 654 L 528 290 L 590 770 L 620 610 L 660 610")
    stem = ((660, 610), (790, 610), (880, 470), (800, 300))
    stem2 = ((800, 300), (760, 222), (680, 186), (606, 190))
    leaves = []
    for seg, n, l0, l1 in ((stem, 6, 108, 92), (stem2, 4, 88, 66)):
        for i in range(n):
            t = (i + 1.0) / (n + 0.4)
            (x, y), h = cubic(*seg, t)
            ln = l0 + (l1 - l0) * i / max(1, n - 1)
            for side in (-1, 1):
                leaves.append(leaf((x, y), h + side * 38, ln, ln * 0.26, mark))
    (tx, ty), th = cubic(*stem2, 1.0)
    leaves.append(leaf((tx, ty), th, 70, 18, mark))
    path = f"{pulse} C 790 610 880 470 800 300 C 760 222 680 186 606 190"
    line = (f'<path d="{path}" fill="none" stroke="{mark}" stroke-width="46" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')
    return doc(ground_defs, f'<g transform="translate(0 34)">{line}{"".join(leaves)}</g>', ground)


def meander_pulse(mark, ground_defs, ground):
    """C: a Greek key on either side of an angular heartbeat."""
    st = f'fill="none" stroke="{mark}" stroke-width="44" stroke-linecap="square"'
    base = "M 150 640 L 432 640 L 462 700 L 530 300 L 598 760 L 628 640 L 874 640"
    left_key = "M 196 640 L 196 446 L 380 446 L 380 586 L 268 586 L 268 516 L 320 516"
    right_key = "M 828 640 L 828 446 L 676 446 L 676 586 L 772 586 L 772 516 L 728 516"
    # Round joins on the spike: its sharp mitres get bevelled off.
    body = (f'<path d="{base}" {st} stroke-linejoin="round"/>'
            f'<path d="{left_key}" {st} stroke-linejoin="miter"/><path d="{right_key}" {st} stroke-linejoin="miter"/>')
    return doc(ground_defs, body, ground)


def main():
    out = HERE / "svg"
    out.mkdir(exist_ok=True)
    gold = vgrad("m", *GOLD)
    icons = {
        "b-laurel": laurel_pulse("url(#m)", vgrad("g", *NAVY) + gold, "url(#g)"),
        "b-laurel-dark": laurel_pulse("url(#m)", vgrad("g", *NIGHT) + gold, "url(#g)"),
        "b-laurel-tinted": laurel_pulse(TINT_MARK, "", "#000000"),
        "c-meander": meander_pulse(CREAM, vgrad("g", *AEGEAN), "url(#g)"),
        "c-meander-dark": meander_pulse(CREAM, vgrad("g", *NIGHT), "url(#g)"),
        "c-meander-tinted": meander_pulse(TINT_MARK, "", "#000000"),
    }
    for old in out.glob("*.svg"):
        old.unlink()
    for name, svg in icons.items():
        (out / f"{name}.svg").write_text(svg)
        print(out / f"{name}.svg")


if __name__ == "__main__":
    main()
