import sys
from PIL import Image
src, prefix, step = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(src)
w, h = im.size
i = 0
y = 0
while y < h:
    im.crop((0, y, w, min(y + step, h))).save(f"{prefix}-{i}.png")
    i += 1; y += step
print(i, "chunks of", step, "from", w, h)
