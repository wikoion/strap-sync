"""App icon: a heartbeat woven through a band (the strap's loop).

Draws at 4x and downsamples.
  python3 icon.py png [STYLE...]      write png/band-STYLE.png
  python3 icon.py --assets APPICONSET write AppIcon, -Dark and -Tinted
The first concept (render(), a sync ring with the heartbeat on top) was
dropped because it read as a power button.
"""
import math, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SS = 4
N = 1024 * SS


def px(v):
    return v * SS


# ---------- colour helpers (OKLab / OKLCH) ----------
def srgb_to_lin(c):
    c = np.asarray(c, float) / 255
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055) * 255


def to_oklab(rgb):
    r, g, b = srgb_to_lin(rgb)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = np.cbrt([l, m, s])
    return np.array([
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ])


def from_oklab(lab):
    L, a, b = lab
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return lin_to_srgb(np.array([
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ]))


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def ramp(stops, t):
    """Interpolate hex stops in OKLab; t is an array in [0, 1]."""
    labs = [to_oklab(hexrgb(s)) for s in stops]
    t = np.clip(t, 0, 1) * (len(stops) - 1)
    i = np.minimum(t.astype(int), len(stops) - 2)
    f = t - i
    out = np.zeros(t.shape + (3,))
    for k in range(len(stops) - 1):
        sel = i == k
        a, b = labs[k], labs[k + 1]
        lab = a[:, None] * (1 - f[sel]) + b[:, None] * f[sel]
        out[sel] = from_oklab(lab).T
    return out


# ---------- geometry ----------
CX, CY, R = 512, 548, 262          # ring centre and radius (1024 space)
START, END = 28.0, 318.0            # degrees, screen coords (clockwise = increasing)
TOP = 270.0


def ecg(u):
    """Outward offset (px) at u degrees from the top of the ring."""
    qrs = [(-17, 0), (-10, -22), (-1.5, 168), (7, -64), (13, 0)]
    for (u0, h0), (u1, h1) in zip(qrs, qrs[1:]):
        if u0 <= u <= u1:
            return h0 + (h1 - h0) * (u - u0) / (u1 - u0)
    return 0.0


def ring_points(step=0.12):
    pts, ths = [], []
    th = START
    while th <= END:
        r = R + ecg(th - TOP)
        a = math.radians(th)
        pts.append((CX + r * math.cos(a), CY + r * math.sin(a)))
        ths.append(th)
        th += step
    return pts, ths


def resample(pts, step):
    """Points every `step` px along the polyline."""
    out = [pts[0]]
    carry = 0.0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        seg = math.hypot(x1 - x0, y1 - y0)
        d = step - carry
        while d <= seg:
            f = d / seg
            out.append((x0 + (x1 - x0) * f, y0 + (y1 - y0) * f))
            d += step
        carry = seg - (d - step)
    out.append(pts[-1])
    return out


def stroke_mask(pts, width, arrow=None):
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    rr = px(width) / 2
    for x, y in resample(pts, 0.75):
        x, y = px(x), px(y)
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=255)
    if arrow:
        poly = [(px(x), px(y)) for x, y in arrow]
        d.polygon(poly, fill=255)
        d.line(poly + [poly[0]], fill=255, width=int(px(22)), joint="curve")
        for x, y in poly:
            d.ellipse([x - px(11), y - px(11), x + px(11), y + px(11)], fill=255)
    return m


def arrowhead(width):
    a = math.radians(END)
    ex, ey = CX + R * math.cos(a), CY + R * math.sin(a)
    tx, ty = -math.sin(a), math.cos(a)        # clockwise tangent
    nx, ny = math.cos(a), math.sin(a)         # outward normal
    L, W = width * 1.55, width * 1.20
    back = width * 0.15
    bx, by = ex - tx * back, ey - ty * back
    tip = (ex + tx * L, ey + ty * L)
    return [tip, (bx + nx * W, by + ny * W), (bx - nx * W, by - ny * W)]


def angle_t(shape):
    """Per-pixel gradient position along the ring (0 at START, 1 at END)."""
    yy, xx = np.mgrid[0:shape[0], 0:shape[1]]
    ang = (np.degrees(np.arctan2(yy / SS - CY, xx / SS - CX)) + 360) % 360
    rel = (ang - START) % 360
    sweep = END - START
    gap_mid = sweep + (360 - sweep) / 2
    return np.where(rel > gap_mid, 0.0, rel / sweep)


def background(top, bottom):
    t = np.linspace(0, 1, N)[:, None, None]
    a, b = np.array(hexrgb(top), float), np.array(hexrgb(bottom), float)
    img = a * (1 - t) + b * t
    img = np.broadcast_to(img, (N, N, 3)).copy()
    # soft light from above the ring
    yy, xx = np.mgrid[0:N, 0:N] / SS
    glow = np.exp(-(((xx - 512) / 420) ** 2 + ((yy - 300) / 360) ** 2))
    img += glow[..., None] * np.array(hexrgb(top), float) * 0.35
    return np.clip(img, 0, 255)


def render(style):
    width = 58
    pts, _ = ring_points()
    mask = stroke_mask(pts, width, arrowhead(width))
    m = np.asarray(mask, float) / 255

    t = angle_t((N, N))
    col = ramp(style["stops"], t)

    if style.get("bg"):
        base = background(*style["bg"])
        alpha_out = np.ones((N, N))
    else:
        base = np.zeros((N, N, 3))
        alpha_out = np.zeros((N, N))

    # glow under the stroke
    if style.get("glow"):
        g = np.asarray(mask.filter(ImageFilter.GaussianBlur(px(26))), float) / 255
        g = g * style["glow"]
        base = base * (1 - g[..., None]) + col * g[..., None]
        alpha_out = np.maximum(alpha_out, g)

    out = base * (1 - m[..., None]) + col * m[..., None]
    alpha_out = np.maximum(alpha_out, m)
    rgba = np.dstack([out, alpha_out * 255]).astype(np.uint8)
    img = Image.fromarray(rgba, "RGBA").resize((1024, 1024), Image.LANCZOS)
    return img


STYLES = {
    "cool": {"stops": ["#3FE0C5", "#4AA8FF", "#9B7BFF", "#FF5C8A"], "bg": ("#18203A", "#070A14"), "glow": 0.55},
    "warm": {"stops": ["#7CF29A", "#F6D74A", "#FF8A3D", "#FF4565"], "bg": ("#1D1A22", "#08080B"), "glow": 0.5},
    "red":  {"stops": ["#FF8A9B", "#FF4D6A", "#F0284F"], "bg": ("#1A1D24", "#07080B"), "glow": 0.5},
}

# ---------- concept 2: pulse woven through a band ----------
BX, BY, BR = 512, 512, 262          # band ring centre / radius


def pulse_points():
    """Heartbeat line across the whole icon, QRS inside the ring."""
    sx = -46                                     # shift the complex left to balance the T wave
    knots = [(-600, 0), (-84, 0), (-58, 24), (-20, -184), (20, 100), (46, 0), (74, 0)]
    pts = [(BX + sx + x, BY + y) for x, y in knots]
    for i in range(1, 81):                       # rounded T wave
        x = 74 + i * 1.25
        pts.append((BX + sx + x, BY - 40 * math.sin(math.pi * i / 80) ** 2))
    pts.append((BX + 600, BY))
    return pts


def band_masks(ring_w, pulse_w, gap):
    def ring(w):
        m = Image.new("L", (N, N), 0)
        r = px(BR)
        ImageDraw.Draw(m).ellipse([px(BX) - r - px(w) / 2, px(BY) - r - px(w) / 2,
                                   px(BX) + r + px(w) / 2, px(BY) + r + px(w) / 2],
                                  outline=255, width=int(px(w)))
        return np.asarray(m, float) / 255

    def pulse(w):
        m = Image.new("L", (N, N), 0)
        d = ImageDraw.Draw(m)
        rr = px(w) / 2
        for x, y in resample(pulse_points(), 0.75):
            d.ellipse([px(x) - rr, px(y) - rr, px(x) + rr, px(y) + rr], fill=255)
        return np.asarray(m, float) / 255

    ring_m, ring_cut = ring(ring_w), ring(ring_w + 2 * gap)
    pulse_m, pulse_cut = pulse(pulse_w), pulse(pulse_w + 2 * gap)
    xx = np.arange(N)[None, :] / SS
    left = (xx < BX).astype(float)
    # left crossing: ring passes over the line; right crossing: line over the ring
    pulse_m = pulse_m * (1 - ring_cut * left)
    ring_m = ring_m * (1 - pulse_cut * (1 - left))
    return ring_m, pulse_m


def conic(cx, cy, start_deg):
    yy, xx = np.mgrid[0:N, 0:N]
    ang = (np.degrees(np.arctan2(yy / SS - cy, xx / SS - cx)) - start_deg) % 360
    return ang / 360


def render_band(style):
    ring_m, pulse_m = band_masks(style.get("ring_w", 66), style.get("pulse_w", 50), 16)
    if style.get("bg"):
        base, alpha = background(*style["bg"]), np.ones((N, N))
    else:
        base, alpha = np.zeros((N, N, 3)), np.zeros((N, N))
    if "ring_stops" in style:
        ring_c = ramp(style["ring_stops"], np.abs(conic(BX, BY, 90) * 2 - 1))
    else:
        ring_c = np.broadcast_to(np.array(hexrgb(style["ring"]), float), (N, N, 3))
    pulse_c = np.broadcast_to(np.array(hexrgb(style["pulse"]), float), (N, N, 3))

    out = base * (1 - ring_m[..., None]) + ring_c * ring_m[..., None]
    alpha = np.maximum(alpha, ring_m)
    if style.get("glow"):
        g = Image.fromarray((pulse_m * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(px(22)))
        g = np.asarray(g, float) / 255 * style["glow"]
        out = out * (1 - g[..., None]) + pulse_c * g[..., None]
        alpha = np.maximum(alpha, g)
    out = out * (1 - pulse_m[..., None]) + pulse_c * pulse_m[..., None]
    alpha = np.maximum(alpha, np.maximum(ring_m, pulse_m))
    if not style.get("bg"):
        # un-premultiply so transparent edges keep their colour
        out = out / np.maximum(alpha, 1e-6)[..., None]
    rgba = np.dstack([np.clip(out, 0, 255), alpha * 255]).astype(np.uint8)
    img = Image.fromarray(rgba, "RGBA").resize((1024, 1024), Image.LANCZOS)
    return img if not style.get("bg") else img.convert("RGB")


BAND = {
    "graphite": {"bg": ("#1B2030", "#07090F"), "ring_stops": ["#9AA3B5", "#3A4152"], "pulse": "#FF4D6A", "glow": 0.6},
    "cool":     {"bg": ("#18203A", "#070A14"), "ring_stops": ["#47D9C6", "#7B6CFF"], "pulse": "#FFFFFF", "glow": 0.35},
    "coral":    {"bg": ("#1A1D24", "#07080B"), "ring": "#FF4D6A", "pulse": "#FFFFFF", "glow": 0.3},
    # iOS 18+ appearances: transparent so the system supplies the backdrop
    "dark":     {"ring_stops": ["#47D9C6", "#7B6CFF"], "pulse": "#FFFFFF", "glow": 0.25},
    "tinted":   {"ring_stops": ["#B8B8B8", "#8A8A8A"], "pulse": "#FFFFFF"},
}

ASSETS = {"AppIcon.png": "cool", "AppIcon-Dark.png": "dark", "AppIcon-Tinted.png": "tinted"}

if __name__ == "__main__":
    if sys.argv[1:2] == ["--assets"]:
        for fname, name in ASSETS.items():
            render_band(BAND[name]).save(Path(sys.argv[2]) / fname)
            print("wrote", fname)
        sys.exit()
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "png")
    out.mkdir(parents=True, exist_ok=True)
    for name in (sys.argv[2:] or BAND):
        render_band(BAND[name]).save(out / f"band-{name}.png")
        print("wrote", name)
