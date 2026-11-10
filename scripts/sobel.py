import csv
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image

from png2pgm import read_pgm, write_pgm, ROOT

EXTS = {'.pgm'}

# the reference model
def sobel(img):
    assert img.dtype == np.uint8
    p = np.pad(img.astype(np.int32), 1, mode="edge")
    # gx = right column - left column, weights 1 2 1
    gx = (p[:-2, 2:] + 2*p[1:-1, 2:] + p[2:, 2:]) - (p[:-2, :-2] + 2*p[1:-1, :-2] + p[2:, :-2])
    # gy = bottom row - top row, weights 1 2 1
    gy = (p[2:, :-2] + 2*p[2:, 1:-1] + p[2:, 2:]) - (p[:-2, :-2] + 2*p[:-2, 1:-1] + p[:-2, 2:])
    return np.clip(np.abs(gx) + np.abs(gy), 0, 255).astype(np.uint8)

# build checksums list
def build_checksums_list(files):
    chk = []
    for i in files:
        img = read_pgm(i)
        out = sobel(img)
        chk += [ {
            'filename': str(i),
            'in_checksum': f'{zlib.crc32(img.tobytes()):08x}',
            'out_checksum': f'{zlib.crc32(out.tobytes()):08x}'
        } ]
    return chk

# write the csv file of a list of dicts into a location
def write_csv(path, l):
    with open(path, 'w', newline='', encoding='ascii') as f:
        w = csv.DictWriter(f, fieldnames=l[0].keys())
        w.writeheader()
        w.writerows(l)

# collect input images
def collect(dirname):
    files = []
    p = Path(dirname)
    if p.is_dir():
        files += sorted(f for f in p.iterdir() if f.suffix.lower() in EXTS)
    else:
        sys.exit(f'error: {p} is not a dir or does not exist')
    return files

# main function
def main():
    files_synth = collect('data/synth')
    files_pgm = collect('data/pgm')
    synth_checksums = []
    pgm_checksums = []
    synth_checksums += build_checksums_list(files_synth)
    pgm_checksums += build_checksums_list(files_pgm)
    write_csv('data/synth.csv', synth_checksums)
    write_csv('data/pgm.csv', pgm_checksums)

if __name__ == '__main__':
    main()
