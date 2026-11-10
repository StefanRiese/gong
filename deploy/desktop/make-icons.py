#!/usr/bin/env python3
"""Generates the desktop app icons (needs Pillow): python3 deploy/desktop/make-icons.py

Motif: a four-cell timetable grid with one checked cell (Lumo) on indigo – the same artwork for every
size and platform (only the platform layout differs: macOS icon grid margin,
monochrome template for the menu bar, square for PWA / home screen).

Output (next to this script, committed):
  app-icon-macos.png      1024 px, macOS layout (inset rounded square) -> AppIcon.icns
  app-icon.ico            Windows exe icon, 16-256 px
  tray-icon.png           32 px, Windows notification area
  MenuBarIcon(@2x).png    18/36 px black template image, macOS menu bar
  ../../web/icon.svg, icon-192.png, icon-512.png   web UI favicon / PWA icons
"""

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent
SS = 4  # supersampling factor

INDIGO = (43, 58, 140)
BLUE_TOP = BLUE_BOTTOM = INDIGO
WHITE = (255, 255, 255, 255)
DIM = (138, 147, 192, 255)  # white at 45 % over the indigo
GOLD = (245, 184, 61, 255)
CHECK = INDIGO + (255,)


def _gradient(size, top, bottom):
    img = Image.new('RGBA', (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(1, size - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        d.line([(0, y), (size, y)], fill=c + (255,))
    return img


def _glyph(d, s, r, bright, dim, accent, check):
    """Draws on a 1024 grid; s() maps coordinates, r() scales lengths.
    Four cells (timetable); the last one is the accent with a check mark."""
    cell, radius = 276, 72
    for x, y, color in [(215, 215, bright), (532, 215, dim), (215, 532, dim), (532, 532, accent)]:
        d.rounded_rectangle([s(x), s(y), s(x + cell), s(y + cell)], r(radius), fill=color)
    pts = [(599, 671), (650, 722), (742, 614)]
    w = 46
    for a, b in zip(pts, pts[1:]):
        d.line([(s(a[0]), s(a[1])), (s(b[0]), s(b[1]))], fill=check, width=r(w))
    for x, y in pts:
        d.ellipse([s(x - w / 2), s(y - w / 2), s(x + w / 2), s(y + w / 2)], fill=check)


def app_icon(size, *, inset):
    big = 1024 * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    s = lambda v: int(v * SS)
    m = 100 if inset else 24  # macOS icon grid leaves a margin
    bg = _gradient(big - 2 * s(m), BLUE_TOP, BLUE_BOTTOM)
    mask = Image.new('L', bg.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, bg.size[0] - 1, bg.size[1] - 1], s(185 if inset else 200), fill=255)
    img.paste(bg, (s(m), s(m)), mask)
    d = ImageDraw.Draw(img)
    # Glyph scaled into the background area.
    k = (1024 - 2 * m) / 1024
    sg = lambda v: int((m + v * k) * SS)
    _glyph(d, sg, lambda v: int(v * k * SS), WHITE, DIM, GOLD, CHECK)
    return img.resize((size, size), Image.LANCZOS)


def template_icon(size):
    big = 1024 * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    black = (0, 0, 0, 255)
    # Fill the frame: the glyph spans ~215..808.
    s = lambda v: int(((v - 190) * 1024 / 645) * SS)
    dim = (0, 0, 0, 120)
    _glyph(d, s, lambda v: int(v * 1024 / 645 * SS), black, dim, black, (0, 0, 0, 0))
    return img.resize((size, size), Image.LANCZOS)


def web_png(size):
    """Web UI / PWA: full-bleed square (also used as maskable icon and iOS
    touch icon, which round the corners themselves); the glyph stays inside
    the maskable safe zone."""
    big = 1024 * SS
    img = _gradient(big, BLUE_TOP, BLUE_BOTTOM)
    d = ImageDraw.Draw(img)
    z = 0.85
    sg = lambda v: int((512 + (v - 512) * z) * SS)
    _glyph(d, sg, lambda v: int(v * z * SS), WHITE, DIM, GOLD, CHECK)
    return img.convert('RGB').resize((size, size), Image.LANCZOS)


class _SvgDraw:
    """Records the ImageDraw calls of _glyph() as SVG elements."""

    def __init__(self):
        self.parts = []

    @staticmethod
    def _c(color):
        return '#%02x%02x%02x' % color[:3] if color[3] else 'none'

    def polygon(self, pts, fill):
        p = ' '.join(f'{x:g},{y:g}' for x, y in pts)
        self.parts.append(f'<polygon points="{p}" fill="{self._c(fill)}"/>')

    def rounded_rectangle(self, box, radius, fill):
        x0, y0, x1, y1 = box
        self.parts.append(f'<rect x="{x0:g}" y="{y0:g}" width="{x1 - x0:g}" height="{y1 - y0:g}" '
                          f'rx="{radius:g}" fill="{self._c(fill)}"/>')

    def line(self, pts, fill, width):
        (x0, y0), (x1, y1) = pts
        self.parts.append(f'<line x1="{x0:g}" y1="{y0:g}" x2="{x1:g}" y2="{y1:g}" '
                          f'stroke="{self._c(fill)}" stroke-width="{width:g}"/>')

    def ellipse(self, box, fill):
        x0, y0, x1, y1 = box
        self.parts.append(f'<ellipse cx="{(x0 + x1) / 2:g}" cy="{(y0 + y1) / 2:g}" '
                          f'rx="{(x1 - x0) / 2:g}" ry="{(y1 - y0) / 2:g}" fill="{self._c(fill)}"/>')


def web_svg():
    """Favicon and app logo: the same rounded icon as the desktop apps."""
    d = _SvgDraw()
    m = 24
    k = (1024 - 2 * m) / 1024
    sg = lambda v: round(m + v * k, 1)
    _glyph(d, sg, lambda v: round(v * k, 1), WHITE, DIM, GOLD, CHECK)
    hexc = lambda c: '#%02x%02x%02x' % c
    return '\n'.join([
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">',
        f'  <rect x="{m}" y="{m}" width="{1024 - 2 * m}" height="{1024 - 2 * m}" rx="200" fill="{hexc(INDIGO)}"/>',
        *('  ' + p for p in d.parts),
        '</svg>',
        '',
    ])


def main():
    web = OUT.parent.parent / 'web'
    web_png(192).save(web / 'icon-192.png', optimize=True)
    web_png(512).save(web / 'icon-512.png', optimize=True)
    (web / 'icon.svg').write_text(web_svg())

    app_icon(1024, inset=True).save(OUT / 'app-icon-macos.png')

    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [app_icon(n, inset=False) for n in sizes]
    frames[-1].save(OUT / 'app-icon.ico', sizes=[(n, n) for n in sizes], append_images=frames[:-1])

    app_icon(32, inset=False).save(OUT / 'tray-icon.png')
    template_icon(18).save(OUT / 'MenuBarIcon.png')
    template_icon(36).save(OUT / 'MenuBarIcon@2x.png')


if __name__ == '__main__':
    main()
