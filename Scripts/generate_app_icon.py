#!/usr/bin/env python3
"""Generate the Open Assist app icon: a microphone with sound waves inside a thin circle."""

from PIL import Image, ImageDraw
import math
import os

SIZE = 1024
CENTER = SIZE // 2
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), '..', 'Resources')


def draw_icon():
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Background: rounded square (macOS icon shape)
    bg_margin = 20
    bg_radius = 180
    draw.rounded_rectangle(
        [bg_margin, bg_margin, SIZE - bg_margin, SIZE - bg_margin],
        radius=bg_radius,
        fill=(55, 65, 130, 255),  # Deep indigo/navy
    )

    # Thin circle
    circle_radius = 360
    circle_stroke = 5  # Very thin
    draw.ellipse(
        [CENTER - circle_radius, CENTER - circle_radius,
         CENTER + circle_radius, CENTER + circle_radius],
        outline=(220, 225, 240, 200),
        width=circle_stroke,
    )

    # Microphone body (larger) — pill shape
    mic_width = 120
    mic_height = 220
    mic_top = CENTER - 140
    mic_left = CENTER - mic_width // 2
    mic_right = CENTER + mic_width // 2
    mic_bottom = mic_top + mic_height

    # Gradient-like microphone body
    for i in range(mic_width):
        t = i / mic_width
        # Darker on edges, lighter in middle
        brightness = int(180 + 60 * math.sin(t * math.pi))
        color = (brightness, brightness, min(255, brightness + 30), 255)
        x = mic_left + i
        draw.line([(x, mic_top + mic_width // 2), (x, mic_bottom - mic_width // 2)], fill=color)

    # Rounded caps for mic
    draw.ellipse(
        [mic_left, mic_top, mic_right, mic_top + mic_width],
        fill=(210, 215, 235, 255),
    )
    draw.ellipse(
        [mic_left, mic_bottom - mic_width, mic_right, mic_bottom],
        fill=(180, 185, 210, 255),
    )

    # Mic glossy highlight
    highlight_w = 40
    highlight_h = 80
    hx = CENTER - 25
    hy = mic_top + 50
    draw.ellipse(
        [hx, hy, hx + highlight_w, hy + highlight_h],
        fill=(255, 255, 255, 80),
    )

    # Microphone cradle (U-shape arc)
    cradle_radius = 150
    cradle_stroke = 10
    cradle_top = CENTER - 80
    # Draw arc
    draw.arc(
        [CENTER - cradle_radius, cradle_top,
         CENTER + cradle_radius, cradle_top + cradle_radius * 2],
        start=0, end=180,
        fill=(200, 205, 225, 220),
        width=cradle_stroke,
    )

    # Stand (vertical line from cradle bottom)
    stand_top = cradle_top + cradle_radius
    stand_bottom = stand_top + 100
    stand_width = 10
    draw.rectangle(
        [CENTER - stand_width // 2, stand_top,
         CENTER + stand_width // 2, stand_bottom],
        fill=(200, 205, 225, 220),
    )

    # Base (horizontal line)
    base_width = 100
    base_height = 10
    draw.rounded_rectangle(
        [CENTER - base_width // 2, stand_bottom,
         CENTER + base_width // 2, stand_bottom + base_height],
        radius=5,
        fill=(200, 205, 225, 220),
    )

    # Sound waves (left side)
    wave_center_y = CENTER - 30
    for i, offset in enumerate([55, 85, 115]):
        alpha = 200 - i * 50
        bar_height = 30 + i * 20
        bx = CENTER - mic_width // 2 - offset
        draw.rounded_rectangle(
            [bx - 4, wave_center_y - bar_height // 2,
             bx + 4, wave_center_y + bar_height // 2],
            radius=4,
            fill=(180, 200, 240, alpha),
        )

    # Sound waves (right side)
    for i, offset in enumerate([55, 85, 115]):
        alpha = 200 - i * 50
        bar_height = 30 + i * 20
        bx = CENTER + mic_width // 2 + offset
        draw.rounded_rectangle(
            [bx - 4, wave_center_y - bar_height // 2,
             bx + 4, wave_center_y + bar_height // 2],
            radius=4,
            fill=(180, 200, 240, alpha),
        )

    # Sparkle dots
    sparkles = [
        (CENTER - 160, CENTER - 100, 6),
        (CENTER + 170, CENTER - 60, 5),
        (CENTER + 140, CENTER + 80, 4),
        (CENTER - 130, CENTER + 100, 5),
    ]
    for sx, sy, sr in sparkles:
        draw.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(255, 255, 255, 140))

    return img


def main():
    img = draw_icon()

    png_path = os.path.join(OUTPUT_DIR, 'AppIcon.png')
    img.save(png_path, 'PNG')
    print(f"Saved {png_path}")

    # Generate .icns using iconutil
    iconset_dir = os.path.join(OUTPUT_DIR, 'AppIcon.iconset')
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        resized = img.resize((s, s), Image.LANCZOS)
        resized.save(os.path.join(iconset_dir, f'icon_{s}x{s}.png'), 'PNG')
        if s <= 512:
            resized2x = img.resize((s * 2, s * 2), Image.LANCZOS)
            resized2x.save(os.path.join(iconset_dir, f'icon_{s}x{s}@2x.png'), 'PNG')

    icns_path = os.path.join(OUTPUT_DIR, 'AppIcon.icns')
    os.system(f'iconutil -c icns "{iconset_dir}" -o "{icns_path}"')
    print(f"Saved {icns_path}")

    # Cleanup iconset
    import shutil
    shutil.rmtree(iconset_dir)


if __name__ == '__main__':
    main()
