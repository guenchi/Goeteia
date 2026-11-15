# Builds the PNG, TGA and GLB fixtures of tools/mutation/image.ss and
# tools/mutation/gltf.ss, which have no byte-list fixture in their cells
# to borrow (test/image.ss writes its PNGs byte by byte to name each
# field; test/glb.ss builds its files with glb-write!).  Deterministic:
# the pixels come from a fixed linear congruential sequence, and zlib at
# level 9 gives the same stream for the same input.  Prints each fixture
# as a Scheme list of bytes, ready to paste.
import struct
import zlib


def lcg(seed):
    while True:
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        yield seed >> 16


def chunk(kind, data):
    body = kind + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)


def png_rgba():
    # 12x10 RGBA: a gradient with noise, rows filtered with types 0..4 in
    # turn, so the decoder runs every unfilter
    w, h = 12, 10
    r = lcg(7)
    rows = []
    for y in range(h):
        px = bytearray()
        for x in range(w):
            n = next(r) & 15
            px += bytes([(x * 20 + n) & 255, (y * 25 + n) & 255, (x * y * 3) & 255, 255 - n])
        rows.append(px)
    raw = bytearray()
    prev = bytearray(w * 4)
    for y, px in enumerate(rows):
        f = y % 5
        out = bytearray()
        for i, b in enumerate(px):
            a = px[i - 4] if i >= 4 else 0
            u = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            if f == 0:
                v = b
            elif f == 1:
                v = b - a
            elif f == 2:
                v = b - u
            elif f == 3:
                v = b - ((a + u) >> 1)
            else:
                p = a + u - c
                pa, pb, pc = abs(p - a), abs(p - u), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (u if pb <= pc else c)
                v = b - pr
            out.append(v & 255)
        raw += bytes([f]) + out
        prev = px
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))


def png_palette():
    # 10x8, 8-bit palette of 6 colours with a tRNS entry (the decoder
    # refuses samples narrower than a byte)
    w, h = 10, 8
    r = lcg(11)
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += bytes([(x + y + (next(r) & 1)) % 6 for x in range(w)])
    plte = bytes([0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0, 255, 255, 255])
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 3, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'PLTE', plte)
            + chunk(b'tRNS', bytes([0, 128])) + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
            + chunk(b'IEND', b''))


def tga_rle():
    # 8x6, type 10 (run-length, true colour), 32 bits, bottom-up: runs and
    # raw packets in turn
    w, h = 8, 6
    head = struct.pack('<BBBHHBHHHHBB', 0, 0, 10, 0, 0, 0, 0, 0, w, h, 32, 8)
    body = bytearray()
    for y in range(h):
        body += bytes([0x80 | 3]) + bytes([y * 40, 10, 200, 255])
        body += bytes([3]) + b''.join(bytes([x * 30, y * 30, 7, 255]) for x in range(4))
    return head + body


def glb():
    # one triangle-pair mesh: POSITION (with the bounds glTF requires),
    # NORMAL, and unsigned-short indices, in one buffer
    pos = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0)]
    nrm = [(0, 0, 1)] * 4
    idx = [0, 1, 2, 2, 1, 3]
    bin_ = b''.join(struct.pack('<3f', *p) for p in pos)
    bin_ += b''.join(struct.pack('<3f', *n) for n in nrm)
    bin_ += struct.pack('<6H', *idx)
    while len(bin_) % 4:
        bin_ += b'\0'
    js = ('{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],'
          '"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1},"indices":2}]}],'
          '"accessors":['
          '{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},'
          '{"bufferView":1,"componentType":5126,"count":4,"type":"VEC3"},'
          '{"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}],'
          '"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},'
          '{"buffer":0,"byteOffset":48,"byteLength":48},'
          '{"buffer":0,"byteOffset":96,"byteLength":12}],'
          '"buffers":[{"byteLength":%d}]}' % len(bin_)).encode()
    while len(js) % 4:
        js += b' '
    total = 12 + 8 + len(js) + 8 + len(bin_)
    return (struct.pack('<III', 0x46546C67, 2, total)
            + struct.pack('<II', len(js), 0x4E4F534A) + js
            + struct.pack('<II', len(bin_), 0x004E4942) + bin_)


def scheme(name, bs):
    words = [str(b) for b in bs]
    lines = [' '.join(words[i:i + 20]) for i in range(0, len(words), 20)]
    return '(define %s\n  \'(%s))' % (name, '\n    '.join(lines))


if __name__ == '__main__':
    for name, f in (('png-rgba', png_rgba), ('png-palette', png_palette),
                    ('tga-rle', tga_rle), ('glb-quad', glb)):
        bs = f()
        print(';; %s: %d bytes' % (name, len(bs)))
        print(scheme(name, bs))
