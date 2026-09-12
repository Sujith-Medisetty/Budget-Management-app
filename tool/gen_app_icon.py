"""Generate the Pocket app icon (1024x1024 PNG) matching the in-app
Pocket logo: indigo gradient rounded square with a white wallet glyph.

Output: assets/app_icon.png — consumed by flutter_launcher_icons."""

import math
from PIL import Image, ImageDraw

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.22)

# Palette — mirrors AppColors in lib/core/theme/app_theme.dart.
INDIGO = (79, 70, 229, 255)            # #4F46E5 AppColors.indigo
INDIGO_DARK = (129, 140, 248, 255)     # #818CF8 AppColors.indigoDark
INDIGO_DEEP = (67, 56, 202, 255)       # #4338CA AppColors.indigoDeep
WHITE = (255, 255, 255, 255)


def lerp(a, b, t):
    return tuple(int(round((1 - t) * a[i] + t * b[i])) for i in range(len(a)))


def build_gradient(size, c0, c1, angle_deg=135):
    """Linear gradient at full resolution — no bilinear upscale artifacts
    on the diagonal. ~1M iterations, but it's a one-time build."""
    img = Image.new('RGBA', (size, size))
    px = img.load()
    # For a top-left → bottom-right diagonal (the in-app logo direction),
    # the gradient axis is (x + y). Avoid using the cos+sin formulation
    # since at 135° cos + sin = 0 and the projection degenerates.
    if angle_deg == 135:
        # Pure diagonal — gradient runs along (x + y) from 0 to 2*(size-1).
        denom = 2.0 * (size - 1)
        c0_r, c0_g, c0_b = c0[0], c0[1], c0[2]
        c1_r, c1_g, c1_b = c1[0], c1[1], c1[2]
        for y in range(size):
            for x in range(size):
                t = (x + y) / denom
                px[x, y] = (
                    int(round((1 - t) * c0_r + t * c1_r)),
                    int(round((1 - t) * c0_g + t * c1_g)),
                    int(round((1 - t) * c0_b + t * c1_b)),
                    255,
                )
    else:
        rad = math.radians(angle_deg)
        cos_a = math.cos(rad)
        sin_a = math.sin(rad)
        denom = (size - 1) * (cos_a + sin_a)
        if denom == 0:
            denom = 1  # degenerate angle — flat
        norm = 1.0 / denom
        c0_r, c0_g, c0_b = c0[0], c0[1], c0[2]
        c1_r, c1_g, c1_b = c1[0], c1[1], c1[2]
        for y in range(size):
            for x in range(size):
                t = max(0.0, min(1.0, (x * cos_a + y * sin_a) * norm))
                px[x, y] = (
                    int(round((1 - t) * c0_r + t * c1_r)),
                    int(round((1 - t) * c0_g + t * c1_g)),
                    int(round((1 - t) * c0_b + t * c1_b)),
                    255,
                )
    return img


def build_mask(size, radius):
    """White rounded square on black — used as the alpha channel."""
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=radius,
        fill=255,
    )
    return mask


def draw_wallet(canvas, cx, cy):
    """White wallet glyph centered on (cx, cy). Rounded body, top flap,
    inner indigo stripe, and a circular clasp on the right side."""
    d = ImageDraw.Draw(canvas, 'RGBA')

    body_w = 540
    body_h = 360
    body_x0 = int(cx - body_w / 2)
    body_y0 = int(cy - body_h / 2 - 10)
    body_x1 = body_x0 + body_w
    body_y1 = body_y0 + body_h
    body_radius = 46
    d.rounded_rectangle(
        [body_x0, body_y0, body_x1, body_y1],
        radius=body_radius,
        fill=WHITE,
    )

    flap_h = 70
    flap_x0 = body_x0 + 14
    flap_x1 = body_x1 - 14
    flap_y0 = body_y0 - 18
    flap_y1 = flap_y0 + flap_h
    d.rounded_rectangle(
        [flap_x0, flap_y0, flap_x1, flap_y1],
        radius=18,
        fill=WHITE,
    )

    stripe_h = 26
    stripe_x0 = body_x0 + 60
    stripe_x1 = body_x1 - 180
    stripe_y0 = body_y0 + 120
    d.rounded_rectangle(
        [stripe_x0, stripe_y0, stripe_x1, stripe_y0 + stripe_h],
        radius=stripe_h // 2,
        fill=INDIGO_DEEP,
    )

    clasp_cx = body_x1 - 48
    clasp_cy = body_y0 + int(body_h * 0.62)
    clasp_r = 58
    d.ellipse(
        [clasp_cx - clasp_r, clasp_cy - clasp_r,
         clasp_cx + clasp_r, clasp_cy + clasp_r],
        fill=WHITE,
    )
    inner_r = 34
    d.ellipse(
        [clasp_cx - inner_r, clasp_cy - inner_r,
         clasp_cx + inner_r, clasp_cy + inner_r],
        fill=INDIGO_DEEP,
    )


def main():
    bg = build_gradient(SIZE, INDIGO, INDIGO_DARK, angle_deg=135)
    mask = build_mask(SIZE, CORNER_RADIUS)
    bg.putalpha(mask)

    draw_wallet(bg, cx=SIZE / 2, cy=SIZE / 2 + 12)

    out = '/Users/sujithmedisetty/pocket/assets/app_icon.png'
    bg.save(out, 'PNG')
    print(f'Wrote {SIZE}x{SIZE} icon to {out}')


if __name__ == '__main__':
    main()