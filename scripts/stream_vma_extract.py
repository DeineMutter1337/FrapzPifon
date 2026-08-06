#!/usr/bin/env python3
import argparse
import hashlib
import os
import struct
import urllib.parse
import urllib.request

import zstandard as zstd

CLUSTER = 65536


def exact(f, n):
    b = bytearray()
    while len(b) < n:
        x = f.read(n - len(b))
        if not x:
            raise EOFError(f"unexpected EOF, needed {n-len(b)} bytes")
        b.extend(x)
    return bytes(b)


def blob_map(header, off, size):
    data = header[off:off + size]
    out, p = {}, 1
    while p + 2 <= len(data):
        ln = int.from_bytes(data[p:p + 2], 'little')
        if p + 2 + ln > len(data):
            break
        out[p] = data[p + 2:p + 2 + ln]
        p += 2 + ln
    return out


def open_source(source):
    parsed = urllib.parse.urlparse(source)
    if parsed.scheme in ('http', 'https'):
        req = urllib.request.Request(
            source,
            headers={'User-Agent': 'FrapzPifon-Analyzer/1.0'},
        )
        return urllib.request.urlopen(req, timeout=300)
    if parsed.scheme == 'file':
        return open(urllib.request.url2pathname(parsed.path), 'rb')
    if parsed.scheme:
        raise ValueError(f'unsupported source scheme: {parsed.scheme}')
    return open(source, 'rb')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source', help='HTTP(S) URL, file:// URL, or local .vma.zst path')
    ap.add_argument('destination')
    args = ap.parse_args()
    os.makedirs(args.destination, exist_ok=True)

    with open_source(args.source) as response:
        reader = zstd.ZstdDecompressor().stream_reader(response)
        first = exact(reader, 12288)
        if first[:4] != b'VMA\0':
            raise RuntimeError('not a VMA stream')
        header_size = int.from_bytes(first[56:60], 'big')
        header = first + exact(reader, header_size - len(first))

        expected = header[32:48]
        check = bytearray(header)
        check[32:48] = b'\0' * 16
        if hashlib.md5(check).digest() != expected:
            raise RuntimeError('VMA header checksum mismatch')

        blob_off = int.from_bytes(header[48:52], 'big')
        blob_size = int.from_bytes(header[52:56], 'big')
        blobs = blob_map(header, blob_off, blob_size)

        config_names = [
            int.from_bytes(header[2044 + i * 4:2048 + i * 4], 'big')
            for i in range(256)
        ]
        config_data = [
            int.from_bytes(header[3068 + i * 4:3072 + i * 4], 'big')
            for i in range(256)
        ]
        for no, do in zip(config_names, config_data):
            if not no or no not in blobs or do not in blobs:
                continue
            name = blobs[no].split(b'\0', 1)[0].decode('utf-8', 'replace')
            if '/' in name or '\\' in name:
                continue
            with open(os.path.join(args.destination, name), 'wb') as config_file:
                config_file.write(blobs[do])

        uuid = header[8:24]
        devices, handles = {}, {}
        for dev_id in range(256):
            p = 4096 + dev_id * 32
            name_off = int.from_bytes(header[p:p + 4], 'big')
            size = int.from_bytes(header[p + 8:p + 16], 'big')
            if not size or name_off not in blobs:
                continue
            name = blobs[name_off].split(b'\0', 1)[0].decode('utf-8', 'replace')
            path = os.path.join(args.destination, name)
            devices[dev_id] = (path, size)
            handles[dev_id] = open(path, 'w+b')
            print(f'device {dev_id}: {name}, virtual size={size}')

        extents = 0
        try:
            while True:
                eh = reader.read(512)
                if not eh:
                    break
                if len(eh) != 512:
                    raise EOFError('truncated extent header')
                if eh[:4] != b'VMAE':
                    raise RuntimeError(f'bad extent magic at extent {extents}')
                if eh[8:24] != uuid:
                    raise RuntimeError('extent UUID mismatch')
                expected = eh[24:40]
                chk = bytearray(eh)
                chk[24:40] = b'\0' * 16
                if hashlib.md5(chk).digest() != expected:
                    raise RuntimeError('extent checksum mismatch')

                for i in range(59):
                    p = 40 + i * 8
                    mask = int.from_bytes(eh[p:p + 2], 'big')
                    dev_id = eh[p + 3]
                    cluster_no = int.from_bytes(eh[p + 4:p + 8], 'big')
                    if dev_id == 0:
                        continue
                    if dev_id not in handles:
                        raise RuntimeError(f'unknown device {dev_id}')
                    f = handles[dev_id]
                    f.seek(cluster_no * CLUSTER)
                    for bit in range(16):
                        if mask & (1 << bit):
                            f.write(exact(reader, 4096))
                        else:
                            f.seek(4096, os.SEEK_CUR)
                extents += 1
                if extents % 1000 == 0:
                    print(f'processed {extents} extents')
        finally:
            for dev_id, f in handles.items():
                if not f.closed:
                    f.truncate(devices[dev_id][1])
                    f.close()

        print(f'done: {extents} extents')


if __name__ == '__main__':
    main()
