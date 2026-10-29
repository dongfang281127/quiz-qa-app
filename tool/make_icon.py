"""把用户给的 qa_icon.jpg 切成正方形、缩到 1024，写成启动图标源文件。

flutter_launcher_icons 吃的是正方形 PNG（jpg 也能吃，但 PNG 不带压缩伪影，
且 1024 是它推荐的原图尺寸）。旧图先备份成 app_icon_prev.png，改错了能退回来。
"""

from pathlib import Path

from PIL import Image

SRC = Path(r"C:\Users\Xiao Yu\Downloads\qa_icon.jpg")
ASSET_DIR = Path(r"C:\AndroidBuild\flutter\flutter_first\assets\icon")
DST = ASSET_DIR / "app_icon.png"
BACKUP = ASSET_DIR / "app_icon_prev.png"
SIZE = 1024


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    if DST.exists() and not BACKUP.exists():
        BACKUP.write_bytes(DST.read_bytes())

    img = Image.open(SRC)
    print(f"source: {SRC} size={img.size} mode={img.mode}")

    # 居中裁成正方形：图标被压扁比被裁边难看多了
    w, h = img.size
    side = min(w, h)
    left = (w - side) // 2
    top = (h - side) // 2
    img = img.crop((left, top, left + side, top + side))

    if img.mode not in ("RGB", "RGBA"):
        img = img.convert("RGB")
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(DST, format="PNG", optimize=True)

    out = Image.open(DST)
    print(f"written: {DST} size={out.size} mode={out.mode} bytes={DST.stat().st_size}")


if __name__ == "__main__":
    main()
