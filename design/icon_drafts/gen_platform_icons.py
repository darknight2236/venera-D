# Generate all platform icons from the final D2c source image (1024x1024).
from PIL import Image, ImageFilter
import os

ROOT = r'd:\CodingProjects\venera-D'
SRC = os.path.join(ROOT, 'design', 'icon_drafts', 'D2c_crescent_fullbleed.png')

src = Image.open(SRC).convert('RGBA')
assert src.size == (1024, 1024), src.size

def save(img, path, mode=None):
    if mode:
        img = img.convert(mode)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print('wrote', path, img.size, img.mode)

def resized(size):
    return src.resize((size, size), Image.LANCZOS)

# ---------- shared derived layers for Android adaptive icon ----------
# Background layer: rebuild the vertical night gradient from the left edge of the art
edge = src.crop((0, 0, 8, 1024)).resize((1, 1024), Image.LANCZOS)
def bg_layer(size):
    return edge.resize((size, size), Image.LANCZOS)

# Foreground layer: extract glowing shapes (V + crescent + star) via luminance alpha
gray = src.convert('L')
alpha = gray.point(lambda l: 0 if l < 60 else min(255, (l - 60) * 255 // 140))
fg_full = src.copy()
fg_full.putalpha(alpha)
bbox = alpha.getbbox()
content = fg_full.crop(bbox)

def layer_with_content(size, content_img, safe_ratio=0.62):
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    target = int(size * safe_ratio)
    w, h = content_img.size
    scale = min(target / w, target / h)
    cw, ch = max(1, int(w * scale)), max(1, int(h * scale))
    scaled = content_img.resize((cw, ch), Image.LANCZOS)
    canvas.paste(scaled, ((size - cw) // 2, (size - ch) // 2), scaled)
    return canvas

# Monochrome layer: same silhouette, pure white
mono_full = Image.new('RGBA', src.size, (255, 255, 255, 255))
mono_full.putalpha(alpha)
mono_content = mono_full.crop(bbox)

# ---------- Android ----------
android_res = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
densities = {'mdpi': (48, 108), 'hdpi': (72, 162), 'xhdpi': (96, 216),
             'xxhdpi': (144, 324), 'xxxhdpi': (192, 432)}
for d, (legacy, canvas) in densities.items():
    folder = os.path.join(android_res, f'mipmap-{d}')
    save(resized(legacy), os.path.join(folder, 'ic_launcher.png'))
    save(bg_layer(canvas), os.path.join(folder, 'ic_launcher_background.png'), 'RGBA')
    save(layer_with_content(canvas, content), os.path.join(folder, 'ic_launcher_foreground.png'))
    save(layer_with_content(canvas, mono_content), os.path.join(folder, 'ic_launcher_monochrome.png'))

# ---------- iOS (no alpha channel allowed) ----------
ios_dir = os.path.join(ROOT, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
ios_icons = {
    'AppIcon@2x.png': 120, 'AppIcon@3x.png': 180,
    'AppIcon~ipad.png': 76, 'AppIcon@2x~ipad.png': 152,
    'AppIcon-83.5@2x~ipad.png': 167,
    'AppIcon-40@2x.png': 80, 'AppIcon-40@3x.png': 120,
    'AppIcon-40~ipad.png': 40, 'AppIcon-40@2x~ipad.png': 80,
    'AppIcon-20@2x.png': 40, 'AppIcon-20@3x.png': 60,
    'AppIcon-20~ipad.png': 20, 'AppIcon-20@2x~ipad.png': 40,
    'AppIcon-29.png': 29, 'AppIcon-29@2x.png': 58, 'AppIcon-29@3x.png': 87,
    'AppIcon-29~ipad.png': 29, 'AppIcon-29@2x~ipad.png': 58,
    'AppIcon-60@2x~car.png': 120, 'AppIcon-60@3x~car.png': 180,
    'AppIcon~ios-marketing.png': 1024,
}
for name, px in ios_icons.items():
    save(resized(px), os.path.join(ios_dir, name), 'RGB')

# ---------- macOS ----------
macos_dir = os.path.join(ROOT, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
for px in [16, 32, 64, 128, 256, 512, 1024]:
    save(resized(px), os.path.join(macos_dir, f'app_icon_{px}.png'))

# ---------- Windows ICO ----------
ico_path = os.path.join(ROOT, 'windows', 'runner', 'resources', 'app_icon.ico')
resized(256).save(ico_path, format='ICO',
                  sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print('wrote', ico_path)

# ---------- Debian / in-app asset / fastlane ----------
save(resized(1024), os.path.join(ROOT, 'debian', 'gui', 'venera.png'))
save(resized(1024), os.path.join(ROOT, 'assets', 'app_icon.png'))
save(resized(512), os.path.join(ROOT, 'fastlane', 'metadata', 'android', 'en-US', 'images', 'icon.png'))

print('ALL DONE')
