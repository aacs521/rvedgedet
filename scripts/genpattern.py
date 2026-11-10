import argparse
import sys
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from png2pgm import write_pgm, parse_size, ROOT # same writer / size parser as the converter

PATTERNS = {}


def pattern(fn):
    """decorator: register fn(w, h, rng) -> 2-d uint8 array under its own name."""
    PATTERNS[fn.__name__] = fn
    return fn


def grid(w, h):
    """x, y coordinate arrays of shape (h, w)."""
    y, x = np.indices((h, w))
    return x.astype(np.int64), y.astype(np.int64)


def u8(a):
    return np.clip(a, 0, 255).astype(np.uint8)


# flat: output must be all zero
@pattern
def flat_0(w, h, rng):
    """all black: the output must be all zero"""
    return np.zeros((h, w), np.uint8)
@pattern
def flat_128(w, h, rng):
    """flat mid gray"""
    return np.full((h, w), 128, np.uint8)
@pattern
def flat_255(w, h, rng):
    """all white"""
    return np.full((h, w), 255, np.uint8)


# single edges: sign, orientation, saturation
# a 0 -> 255 step gives the largest possible |gx| (1020) next to the edge
# tests clamping / overflow
@pattern
def step_v(w, h, rng):
    """vertical edge, bright on the right   -> gx only"""
    x, y = grid(w, h);  return u8((x >= w // 2) * 255)
@pattern
def step_h(w, h, rng):
    """horizontal edge, bright at the bottom -> gy only"""
    x, y = grid(w, h);  return u8((y >= h // 2) * 255)
@pattern
def step_d(w, h, rng):
    """diagonal edge                          -> gx and gy"""
    x, y = grid(w, h);  return u8((x * h + y * w >= w * h) * 255)
@pattern
def step_soft(w, h, rng):
    """small step (100 -> 140): no clamping involved"""
    x, y = grid(w, h);  return u8(100 + (x >= w // 2) * 40)


# impulse: hand-checkable 3x3 response
@pattern
def impulse(w, h, rng):
    """one white pixel on black, in the centre"""
    a = np.zeros((h, w), np.uint8);  a[h // 2, w // 2] = 255;  return a
@pattern
def line_v(w, h, rng):
    """1 px wide vertical line"""
    a = np.zeros((h, w), np.uint8);  a[:, w // 2] = 255;  return a
@pattern
def line_h(w, h, rng):
    """1 px wide horizontal line"""
    a = np.zeros((h, w), np.uint8);  a[h // 2, :] = 255;  return a


# periodic: worst case switching, aliasing
@pattern
def checker_1(w, h, rng):
    """1 px squares (gx = gy = 0 in the interior, surprisingly)"""
    x, y = grid(w, h);  return u8(((x + y) & 1) * 255)
@pattern
def checker_8(w, h, rng):
    """8 px squares: edges and corners everywhere"""
    x, y = grid(w, h);  return u8((((x // 8) + (y // 8)) & 1) * 255)
@pattern
def stripes_v(w, h, rng):
    """2 px wide vertical stripes"""
    x, y = grid(w, h);  return u8(((x // 2) & 1) * 255)
@pattern
def stripes_h(w, h, rng):
    """2 px wide horizontal stripes"""
    x, y = grid(w, h);  return u8(((y // 2) & 1) * 255)
@pattern
def rings(w, h, rng):
    """concentric bands of constant width (6 px): every edge orientation at once"""
    x, y = grid(w, h);  cx, cy = w // 2, h // 2
    r = np.floor(np.sqrt((x - cx) ** 2 + (y - cy) ** 2)).astype(np.int64)    # sqrt of an integer: exact, same everywhere
    return u8((r // 6 % 2) * 255)
@pattern
def zoneplate(w, h, rng):
    """bands that get narrower with radius until they alias (moire): stress test, all frequencies"""
    x, y = grid(w, h);  cx, cy = w // 2, h // 2
    return u8((((x - cx) ** 2 + (y - cy) ** 2) // 128 % 2) * 255)
@pattern
def disk(w, h, rng):
    """filled circle, anti-aliasing-free edge"""
    x, y = grid(w, h);  cx, cy, r = w // 2, h // 2, min(w, h) // 3
    return u8((((x - cx) ** 2 + (y - cy) ** 2) <= r * r) * 255)


# ramps: constant gradient, no clamping
@pattern
def ramp_h(w, h, rng):
    """horizontal ramp 0..255 (small, nearly constant gx)"""
    x, y = grid(w, h);  return u8(x * 255 // max(w - 1, 1))
@pattern
def ramp_v(w, h, rng):
    """vertical ramp 0..255 (small, nearly constant gy)"""
    x, y = grid(w, h);  return u8(y * 255 // max(h - 1, 1))
@pattern
def ramp_d(w, h, rng):
    """diagonal ramp 0..255 (gx and gy)"""
    x, y = grid(w, h);  return u8((x + y) * 255 // max(w + h - 2, 1))


# noise (seeded)
@pattern
def noise(w, h, rng):
    """uniform 0..255"""
    return rng.integers(0, 256, (h, w), dtype=np.uint8)
@pattern
def noise_gauss(w, h, rng):
    """mean 128, sigma 30"""
    return u8(np.rint(rng.normal(128, 30, (h, w))))
@pattern
def salt_pepper(w, h, rng):
    """flat 128 with 5 % black / white pixels"""
    a = np.full((h, w), 128, np.uint8)
    r = rng.random((h, w))
    a[r < 0.025] = 0
    a[(r >= 0.025) & (r < 0.05)] = 255
    return a

# main function
def main():
    ap = argparse.ArgumentParser(description='generate synthetic test images as pgm')
    ap.add_argument('--size', type=parse_size, default=(352, 288), help='WxH (default 352x288)')
    ap.add_argument('--only', nargs='+', metavar='NAME', help='only these patterns')
    ap.add_argument('-o', '--out', type=Path, default=ROOT / 'data' / 'synth', help='output folder')
    ap.add_argument('--seed', type=int, default=1, help='seed for the noise patterns (default 1)')
    ap.add_argument('--ascii', action='store_true', help='write plain-text P2 instead of binary P5')
    ap.add_argument('--list', action='store_true', help='list the patterns and exit')
    args = ap.parse_args()

    if args.list:
        for name, fn in PATTERNS.items():
            print(f'{name:<12} {(fn.__doc__ or '').strip()}')
        return
    names = args.only or list(PATTERNS)
    for n in names:
        if n not in PATTERNS:
            sys.exit(f'unknown pattern \'{n}\' (see --list)')

    w, h = args.size
    args.out.mkdir(parents=True, exist_ok=True)
    print(f'{'file':<24}{'min':>5}{'max':>5}{'mean':>7}  crc32')
    for n in names:
        rng = np.random.default_rng(args.seed) # same noise for the same seed and size
        img = PATTERNS[n](w, h, rng)
        assert img.shape == (h, w) and img.dtype == np.uint8
        out = args.out / f'{n}_{w}x{h}.pgm'
        write_pgm(out, img, args.ascii)
        print(f'{out.name:<24}{img.min():>5}{img.max():>5}{img.mean():>7.1f}  {zlib.crc32(img.tobytes()):08x}')
    print(f'\n{len(names)} file(s) -> {args.out}')


if __name__ == '__main__':
    main()
