"""Nexus gallery images: 16:9 crops of in-game screenshots with a caption bar."""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")
OUT = os.path.join(HERE, "final")
os.makedirs(OUT, exist_ok=True)

W, H = 1920, 1080
ACCENT = (242, 194, 48)
BOLD = "C:/Windows/Fonts/segoeuib.ttf"
REG = "C:/Windows/Fonts/segoeui.ttf"


def font(path, size):
    return ImageFont.truetype(path, size)


def base(name, align="center"):
    im = Image.open(os.path.join(RAW, name + ".png")).convert("RGB")
    w, h = im.size                      # 3440x1440 ultrawide -> 16:9
    cw = h * 16 // 9
    x0 = {"center": (w - cw) // 2, "left": 0, "right": w - cw}[align]
    return im.crop((x0, 0, x0 + cw, h)).resize((W, H), Image.LANCZOS)


def bar(im, key, title, sub):
    """Dark gradient at the bottom with [KEY] title / subtitle."""
    grad = Image.new("L", (1, 300))
    for y in range(300):
        grad.putpixel((0, y), int(225 * (y / 299) ** 1.2))
    grad = grad.resize((W, 300))
    black = Image.new("RGB", (W, 300), (8, 10, 14))
    im.paste(black, (0, H - 300), grad)
    d = ImageDraw.Draw(im)
    x, y = 80, H - 175
    if key:
        f = font(BOLD, 64)
        tw = d.textlength(key, font=f)
        d.rounded_rectangle((x, y - 6, x + tw + 44, y + 82), radius=14, fill=ACCENT)
        d.text((x + 22, y), key, font=f, fill=(15, 15, 15))
        x += tw + 44 + 30
    d.text((x, y - 2), title, font=font(BOLD, 66), fill="white")
    if sub:
        d.text((80, y + 92), sub, font=font(REG, 40), fill=(225, 225, 225))
    tag = "RV Checkpoint+"
    ft = font(BOLD, 34)
    d.text((W - 60 - d.textlength(tag, font=ft), 40), tag, font=ft, fill=ACCENT,
           stroke_width=3, stroke_fill=(0, 0, 0))
    return im


def cover():
    im = base("cover", "right")           # RV ends up on the left, text goes right
    band = Image.new("L", (W, H), 0)
    bd = ImageDraw.Draw(band)
    for x in range(1050):
        bd.line([(W - 1 - x, 0), (W - 1 - x, H)], fill=int(225 * (1 - x / 1050) ** 1.1))
    im.paste(Image.new("RGB", (W, H), (8, 10, 14)), (0, 0), band.filter(ImageFilter.GaussianBlur(4)))
    d = ImageDraw.Draw(im)
    X = 1060
    d.text((X, 230), "RV Checkpoint+", font=font(BOLD, 112), fill=ACCENT, stroke_width=2, stroke_fill=(0, 0, 0))
    d.text((X + 6, 385), "Save anywhere in RV There Yet?", font=font(BOLD, 50), fill="white")
    lines = [("F5", "quick save anywhere"), ("F9", "quick load"), ("F8", "go back to any checkpoint"),
             ("F7", "recover a stuck / flipped RV"), ("F6", "unstuck players"), ("+", "repairs saved automatically")]
    fk, ft = font(BOLD, 40), font(REG, 40)
    for i, (k, t) in enumerate(lines):
        y = 500 + i * 64
        d.rounded_rectangle((X + 6, y + 4, X + 86, y + 54), radius=10, fill=ACCENT)
        d.text((X + 46 - d.textlength(k, font=fk) / 2, y + 4), k, font=fk, fill=(15, 15, 15))
        d.text((X + 110, y + 2), t, font=ft, fill=(238, 238, 238))
    return im


SHOTS = [
    ("01_cover", None),
    ("02_quick_save", ("quicksave", "F5", "Quick save anywhere",
                       "Saves the RV's position, damage, repairs and items on it")),
    ("03_flipped", ("flipped", "", "Flipped your RV?",
                    "The mod won't save a bad spot. Press F7 to recover")),
    ("04_recovered", ("recovered", "F7", "Back on its wheels",
                      "First press lifts a stuck RV free, the second puts it on the last safe spot")),
    ("05_quick_load", ("quickload", "F9", "Quick load",
                       "Also after game over: you're back at your quick save, not at the checkpoint")),
    ("06_checkpoint_menu", ("f8menu", "F8", "Go back to any checkpoint",
                            "Missed an item? Pick an earlier checkpoint. Your repairs are kept")),
]

for out, spec in SHOTS:
    if spec is None:
        im = cover()
    else:
        raw, key, title, sub = spec
        im = bar(base(raw), key, title, sub)
    im.save(os.path.join(OUT, out + ".jpg"), quality=92)
    print("wrote", out)
