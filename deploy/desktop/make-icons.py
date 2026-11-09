#!/usr/bin/env python3
"""Generates the desktop app icons (needs Pillow): python3 deploy/desktop/make-icons.py

Motif: mortarboard over an open book on the app blue. Small sizes (<= 32 px)
show only the mortarboard, which stays readable in the tray / menu bar.

Output (next to this script, committed):
  app-icon-macos.png      1024 px, macOS layout (inset rounded square) -> AppIcon.icns
  app-icon.ico            Windows exe icon, 16-256 px
  tray-icon.png           32 px, Windows notification area
  MenuBarIcon(@2x).png    18/36 px black template image, macOS menu bar
"""

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent
SS = 4  # supersampling factor

BLUE_TOP = (37, 107, 208)
BLUE_BOTTOM = (22, 74, 160)
WHITE = (255, 255, 255, 255)
PAGE = (214, 228, 250, 255)
GOLD = (247, 190, 52, 255)


def _gradient(size, top, bottom):
    img = Image.new('RGBA', (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(1, size - 1)
        c = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        d.line([(0, y), (size, y)], fill=c + (255,))
    return img


def _glyph(d, s, r, color_cap, color_book, color_tassel, book=True, hole=None):
    """Draws on a 1024 grid; s() maps coordinates, r() scales lengths."""
    P = lambda pts: [(s(x), s(y)) for x, y in pts]
    if book:
        # Open book: two pages meeting at the spine, slightly curved via polygons.
        left = [(500, 600), (420, 572), (300, 566), (196, 584), (196, 836), (300, 818), (420, 824), (500, 852)]
        right = [(1024 - x, y) for x, y in left]
        d.polygon(P(left), fill=color_book)
        d.polygon(P(right), fill=color_book)
        cap_dy = -70
    else:
        cap_dy = 70
    dy = cap_dy
    # Cap base (skull cap) below the board.
    d.rounded_rectangle([s(332), s(400 + dy), s(692), s(560 + dy)], r(60), fill=color_cap)
    if hole is not None:
        # Separation line between board and base.
        d.polygon(P([(300, 436 + dy), (512, 520 + dy), (724, 436 + dy), (724, 466 + dy), (512, 550 + dy), (300, 466 + dy)]), fill=hole)
    # Board (rhombus).
    d.polygon(P([(512, 230 + dy), (900, 386 + dy), (512, 542 + dy), (124, 386 + dy)]), fill=color_cap)
    # Tassel: cord from the button to the right, hanging down.
    d.line(P([(512, 386 + dy), (780, 430 + dy)]), fill=color_tassel, width=r(22))
    d.line(P([(780, 430 + dy), (780, 590 + dy)]), fill=color_tassel, width=r(22))
    d.rounded_rectangle([s(756), s(580 + dy), s(804), s(668 + dy)], r(18), fill=color_tassel)
    d.ellipse([s(490), s(364 + dy), s(534), s(408 + dy)], fill=color_tassel)


def app_icon(size, *, inset, book):
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
    z = 1.0 if book else 1.3  # cap only: zoom in so it stays readable when small
    sg = lambda v: int((m + (512 + (v - 512) * z) * k) * SS)
    _glyph(d, sg, lambda v: int(v * z * k * SS), WHITE, PAGE, GOLD, book=book, hole=BLUE_BOTTOM + (255,))
    return img.resize((size, size), Image.LANCZOS)


def template_icon(size):
    big = 1024 * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    black = (0, 0, 0, 255)
    # Fill the frame: the glyph spans ~124..900 horizontally.
    s = lambda v: int(((v - 112) * 1024 / 800) * SS)
    _glyph(d, s, lambda v: int(v * 1024 / 800 * SS), black, black, black, book=False, hole=(0, 0, 0, 0))
    return img.resize((size, size), Image.LANCZOS)


def main():
    app_icon(1024, inset=True, book=True).save(OUT / 'app-icon-macos.png')

    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [app_icon(n, inset=False, book=n > 32) for n in sizes]
    frames[-1].save(OUT / 'app-icon.ico', sizes=[(n, n) for n in sizes], append_images=frames[:-1])

    app_icon(32, inset=False, book=False).save(OUT / 'tray-icon.png')
    template_icon(18).save(OUT / 'MenuBarIcon.png')
    template_icon(36).save(OUT / 'MenuBarIcon@2x.png')


if __name__ == '__main__':
    main()
