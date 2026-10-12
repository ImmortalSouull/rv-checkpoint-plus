"""Vertical (1080x1920) TikTok cut of the RV Checkpoint+ showcase.

Game footage is cropped 1:1 from the 3440x1440 take (no downscaling), so the in-game messages
stay readable on a phone. Big two-line captions sit above the footage.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "raw", "take6.mp4")
OUT = os.path.join(HERE, sys.argv[1] if len(sys.argv) > 1 else "rv_checkpoint_plus_tiktok.mp4")
FONT = "C\\:/Windows/Fonts/segoeuib.ttf"
FONT_REG = "C\\:/Windows/Fonts/segoeui.ttf"

W, H = 1080, 1920
CROP_X, CROP_Y, CROP_W, CROP_H = 1180, 60, 1080, 1350
VIDEO_Y = 400
ACCENT = "0xF2C230"

# (in, dur, line1, line2)
SEGMENTS = [
    (0.6, 2.4, "RV There Yet?", "but you can SAVE ANYWHERE"),
    (3.0, 5.8, "F5 = quick save", "even while driving"),
    (13.6, 3.4, "Crashed into the trees?", ""),
    (21.6, 4.2, "F7 = RV lifted free", ""),
    (27.6, 2.6, "RV destroyed", "(staged for the demo)"),
    (37.2, 7.4, "Back at your quick save", "not at the checkpoint"),
    (55.0, 7.4, "F8 = go back to", "any earlier checkpoint"),
]
CARD_DUR = 3.6
FADE = 0.15


def esc(s):
    return s.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’").replace("%", "\\%")


def text(label, y, size, color="white", font=FONT):
    return (f"drawtext=fontfile='{font}':text='{esc(label)}':fontsize={size}:fontcolor={color}"
            f":x=(w-text_w)/2:y={y}:shadowcolor=black@0.7:shadowx=3:shadowy=3")


parts, labels = [], []
for i, (t_in, dur, l1, l2) in enumerate(SEGMENTS):
    v = (f"[0:v]trim=start={t_in}:duration={dur},setpts=PTS-STARTPTS,"
         f"crop={CROP_W}:{CROP_H}:{CROP_X}:{CROP_Y},"
         f"pad={W}:{H}:0:{VIDEO_Y}:color=0x0B0D10,"
         + text(l1, 120 if l2 else 170, 76, ACCENT if i == 0 else "white") + ","
         + (text(l2, 220, 58) + "," if l2 else "")
         + text("RV Checkpoint+", 1800, 44, ACCENT) + ","
         f"fade=t=in:st=0:d={FADE},fade=t=out:st={dur - FADE}:d={FADE},format=yuv420p,setsar=1[v{i}]")
    a = (f"[0:a]atrim=start={t_in}:duration={dur},asetpts=PTS-STARTPTS,"
         f"afade=t=in:st=0:d={FADE},afade=t=out:st={dur - FADE}:d={FADE}[a{i}]")
    parts += [v, a]
    labels.append(f"[v{i}][a{i}]")

n = len(SEGMENTS)
card = (f"color=c=0x0B0D10:s={W}x{H}:d={CARD_DUR}:r=30,"
        + text("RV Checkpoint+", 700, 110, ACCENT) + ","
        + text("free mod for RV There Yet?", 840, 56) + ","
        + text("F5 save   F9 load   F8 checkpoints", 1000, 46, "white", FONT_REG) + ","
        + text("F7 recover RV   F6 unstuck", 1070, 46, "white", FONT_REG) + ","
        + text("repairs saved automatically", 1140, 46, "white", FONT_REG) + ","
        + f"fade=t=in:st=0:d=0.3,fade=t=out:st={CARD_DUR - 0.8}:d=0.8,format=yuv420p,setsar=1[v{n}]")
parts.append(card)
parts.append(f"anullsrc=r=48000:cl=stereo,atrim=duration={CARD_DUR}[a{n}]")
labels.append(f"[v{n}][a{n}]")
parts.append("".join(labels) + f"concat=n={n + 1}:v=1:a=1[vc][ac]")
parts.append("[ac]loudnorm=I=-14:TP=-1.5:LRA=11[ao]")

cmd = ["ffmpeg", "-v", "error", "-y", "-i", SRC, "-filter_complex", ";".join(parts),
       "-map", "[vc]", "-map", "[ao]", "-r", "30",
       "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
       "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-movflags", "+faststart", OUT]
subprocess.run(cmd, check=True)
print("wrote", OUT)
