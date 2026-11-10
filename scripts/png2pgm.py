import argparse
import re
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
EXTS = {'.png', '.jpg', '.jpeg', '.bmp', '.tif', '.tiff', '.webp'}

# save a PGM file
def write_pgm(path, img, ascii_mode=False):
    """img: 2D uint8 array (rows, cols)"""
    img = np.asarray(img)
    assert img.ndim == 2 and img.dtype == np.uint8, 'need a 2D uint8 array'
    h, w = img.shape
    path = Path(path)
    if ascii_mode:
        lines = [f'P2\n{w} {h}\n255']
        for row in img: # PGM spec asks for lines of at most 70 chars
            cur = ''
            for v in row:
                tok = str(int(v))
                if cur and len(cur) + 1 + len(tok) > 70:
                    lines.append(cur)
                    cur = tok
                else:
                    cur = f'{cur} {tok}' if cur else tok
            lines.append(cur)
        path.write_text('\n'.join(lines) + '\n', encoding='ascii')
    else:
        path.write_bytes(f'P5\n{w} {h}\n255\n'.encode('ascii') + img.tobytes())

# read a PGM file
# header: magic, width, height, maxval, separated by whitespace and/or '#' comment lines
_SEP = rb'(?:\s+|#[^\n]*\n)+'
_HEADER = re.compile(rb'(P[25])' + _SEP + rb'(\d+)' + _SEP + rb'(\d+)' + _SEP + rb'(\d+)')
def read_pgm(path):
    """read P2 or P5 (8-bit) -> 2D uint8 array. understands '#' comments"""
    data = Path(path).read_bytes()
    m = _HEADER.match(data)
    if not m:
        raise ValueError(f'{path}: not a P2/P5 pgm, file starts with {data[:20]!r}')
    magic, w, h, maxval = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
    if maxval != 255:
        raise ValueError(f'{path}: only maxval 255 is supported (got {maxval})')
    body = m.end() # raster starts after exactly one whitespace byte
    if magic == b'P5':
        raster = np.frombuffer(data, dtype=np.uint8, offset=body + 1)
    else:
        raster = np.array(data[body:].split(), dtype=np.int64)
        if raster.size and (raster.min() < 0 or raster.max() > 255):
            raise ValueError(f'{path}: ascii pixel value out of range')
        raster = raster.astype(np.uint8)
    if raster.size != w * h:
        raise ValueError(f'{path}: header says {w}x{h} = {w * h} pixels, file has {raster.size}')
    return raster.reshape(h, w).copy()


# convert to grayscale
def to_grayscale(im):
    """any pillow image -> 2D uint8 gray array. transparency is flattened onto black"""
    if im.mode in ('I;16', 'I;16L', 'I;16B'): # 16-bit gray: keep the top byte
        return (np.asarray(im, dtype=np.uint32) >> 8).astype(np.uint8)
    if im.mode in ('RGBA', 'LA', 'PA') or "transparency" in im.info:
        bg = Image.new('RGBA', im.size, (0, 0, 0, 255))
        im = Image.alpha_composite(bg, im.convert('RGBA'))
    return np.asarray(im.convert('L'), dtype=np.uint8)

# crop and fit the image
def crop_and_fit(gray, size, how):
    """bring the gray array to size=(w, h). how: crop | stretch | none."""
    if how == 'none' or (gray.shape[1], gray.shape[0]) == size:
        return gray
    im = Image.fromarray(gray, 'L')
    w, h = size
    if how == 'crop': # centre-crop to the target aspect ratio
        sw, sh = im.size
        if sw * h > sh * w: # is it too wide?
            nw = round(sh * w / h)
            box = ((sw - nw) // 2, 0, (sw - nw) // 2 + nw, sh)
        else:               # or too tall?
            nh = round(sw * h / w)
            box = (0, (sh - nh) // 2, sw, (sh - nh) // 2 + nh)
        im = im.crop(box)
    return np.asarray(im.resize((w, h), Image.LANCZOS), dtype=np.uint8)

# collect input images from a folder or a set of files
def collect(inputs):
    files = []
    for p in inputs:
        p = Path(p)
        if p.is_dir():
            files += sorted(f for f in p.iterdir() if f.suffix.lower() in EXTS)
        elif p.is_file():
            files.append(p)
        else:
            sys.exit(f'error: {p} does not exist')
    return files

# parse the size provided in the arguments (WxH format)
def parse_size(s):
    try:
        w, h = s.lower().split('x')
        return int(w), int(h)
    except ValueError:
        raise argparse.ArgumentTypeError('size must look like this: WxH (W and H are numbers)')

# main function
def main():
    ap = argparse.ArgumentParser(description='png -> 8-bit grayscale pgm (P5 binary or P2 ascii)')
    ap.add_argument('inputs', nargs='*', default=[ROOT / 'data' / 'orig'],
                    help='image files or folders (default: data/orig)')
    ap.add_argument('-o', '--out', type=Path, default=ROOT / 'data' / 'pgm',
                    help='output folder (default: data/pgm)')
    ap.add_argument('--size', type=parse_size, default=(352, 288), help='target WxH (default 352x288)')
    ap.add_argument('--resize', choices=('crop', 'stretch', 'none'), default='crop',
                    help='how to reach --size: centre-crop to aspect then scale (default), stretch, or keep size')
    ap.add_argument('--ascii', action='store_true', help='write plain-text P2 instead of binary P5')
    args = ap.parse_args()

    files = collect(args.inputs)
    if not files:
        sys.exit('no input images found')
    args.out.mkdir(parents=True, exist_ok=True)

    print(f'{'file':<16}{'min':>5}{'max':>5}{'mean':>7}  crc32')

    for f in files:
        with Image.open(f) as im:
            in_size = im.size
            gray = crop_and_fit(to_grayscale(im), args.size, args.resize)

        out = args.out / (f.stem + '.pgm')
        write_pgm(out, gray, args.ascii)

        back = read_pgm(out) # round-trip check
        if not np.array_equal(back, gray):
            sys.exit(f'error: {out} does not read back identically')

        print(f'{f.name:<16}'
              f'{gray.min():>5}{gray.max():>5}{gray.mean():>7.1f}'
              f'  {zlib.crc32(gray.tobytes()):08x}')

    print(f'\n{len(files)} file(s) -> {args.out}  ({'P2 ascii' if args.ascii else 'P5 binary'})')

if __name__ == '__main__':
    main()

