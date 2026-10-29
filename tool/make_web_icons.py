"""从 assets/icon/app_icon.png 生成 Web 端图标。

  - web/favicon.png               64×64
  - web/icons/Icon-192.png       192×192
  - web/icons/Icon-512.png       512×512
  - web/icons/Icon-maskable-*.png 保留 80% 安全区，四周补主题色

用法（在工程根目录）：
    python tool/make_web_icons.py
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "icon" / "app_icon.png"
BG = (1, 117, 194, 255)  # #0175C2，和 web/index.html 的 theme-color 一致

TARGETS = {
    ROOT / "web" / "favicon.png": (64, False),
    ROOT / "web" / "icons" / "Icon-192.png": (192, False),
    ROOT / "web" / "icons" / "Icon-512.png": (512, False),
    ROOT / "web" / "icons" / "Icon-maskable-192.png": (192, True),
    ROOT / "web" / "icons" / "Icon-maskable-512.png": (512, True),
}


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    for path, (size, maskable) in TARGETS.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if not maskable:
            src.resize((size, size), Image.LANCZOS).save(path)
            print(f"{path.relative_to(ROOT)}  {size}x{size}")
            continue
        canvas = Image.new("RGBA", (size, size), BG)
        inner = int(size * 0.8)
        canvas.paste(src.resize((inner, inner), Image.LANCZOS), ((size - inner) // 2,) * 2)
        canvas.save(path)
        print(f"{path.relative_to(ROOT)}  {size}x{size} (maskable)")


if __name__ == "__main__":
    main()
