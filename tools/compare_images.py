#!/usr/bin/env python3
"""Compare two 8-bit PNG images without external dependencies."""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def read_png(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path} is not a PNG")

    position = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = None
    interlace = None
    compressed = bytearray()
    while position < len(data):
        if position + 12 > len(data):
            raise ValueError(f"{path} has a truncated PNG chunk")
        length = struct.unpack_from(">I", data, position)[0]
        chunk_start = position + 8
        chunk_end = chunk_start + length
        if chunk_end + 4 > len(data):
            raise ValueError(f"{path} has a truncated PNG payload")
        chunk_type = data[position + 4 : position + 8]
        payload = data[chunk_start:chunk_end]
        if chunk_type == b"IHDR":
            if length != 13:
                raise ValueError(f"{path} has an invalid IHDR")
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if compression != 0 or filter_method != 0 or interlace != 0:
                raise ValueError(f"{path} uses an unsupported PNG encoding")
            if bit_depth != 8 or color_type not in (0, 2, 4, 6):
                raise ValueError(f"{path} must be a non-interlaced 8-bit PNG")
        elif chunk_type == b"IDAT":
            compressed.extend(payload)
        elif chunk_type == b"IEND":
            break
        position = chunk_end + 4

    if width is None or height is None or interlace is None:
        raise ValueError(f"{path} is missing IHDR")

    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    row_bytes = width * channels
    raw = zlib.decompress(bytes(compressed))
    expected = height * (row_bytes + 1)
    if len(raw) != expected:
        raise ValueError(f"{path} has {len(raw)} decoded bytes; expected {expected}")

    rows: list[bytes] = []
    previous = bytes(row_bytes)
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        encoded = raw[cursor : cursor + row_bytes]
        cursor += row_bytes
        row = bytearray(row_bytes)
        for index, value in enumerate(encoded):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                reconstructed = value
            elif filter_type == 1:
                reconstructed = (value + left) & 0xFF
            elif filter_type == 2:
                reconstructed = (value + above) & 0xFF
            elif filter_type == 3:
                reconstructed = (value + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                reconstructed = (value + paeth(left, above, upper_left)) & 0xFF
            else:
                raise ValueError(f"{path} uses unsupported PNG filter {filter_type}")
            row[index] = reconstructed
        rows.append(bytes(row))
        previous = bytes(row)

    rgba = bytearray(width * height * 4)
    output = 0
    for row in rows:
        if color_type == 6:
            rgba[output : output + len(row)] = row
            output += len(row)
        elif color_type == 2:
            for index in range(0, len(row), 3):
                rgba[output : output + 4] = row[index : index + 3] + b"\xff"
                output += 4
        elif color_type == 4:
            for index in range(0, len(row), 2):
                rgba[output : output + 4] = bytes((row[index], row[index], row[index], row[index + 1]))
                output += 4
        else:
            for value in row:
                rgba[output : output + 4] = bytes((value, value, value, 255))
                output += 4
    return width, height, bytes(rgba)


def compare(reference: Path, candidate: Path, max_diff: int, max_changed_pixels: int) -> int:
    reference_width, reference_height, reference_pixels = read_png(reference)
    candidate_width, candidate_height, candidate_pixels = read_png(candidate)
    if (reference_width, reference_height) != (candidate_width, candidate_height):
        print(
            f"FAIL {reference.name} vs {candidate.name}: dimensions "
            f"{reference_width}x{reference_height} != {candidate_width}x{candidate_height}"
        )
        return 1

    maximum_difference = 0
    changed_pixels = 0
    for offset in range(0, len(reference_pixels), 4):
        pixel_difference = max(
            abs(reference_pixels[offset + channel] - candidate_pixels[offset + channel])
            for channel in range(4)
        )
        maximum_difference = max(maximum_difference, pixel_difference)
        if pixel_difference > 0:
            changed_pixels += 1

    status = "PASS" if maximum_difference <= max_diff and changed_pixels <= max_changed_pixels else "FAIL"
    print(
        f"{status} {reference.name} vs {candidate.name}: "
        f"size={reference_width}x{reference_height} max_diff={maximum_difference} "
        f"changed_pixels={changed_pixels} limits=({max_diff},{max_changed_pixels})"
    )
    return 0 if status == "PASS" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--max-diff", type=int, default=0)
    parser.add_argument("--max-changed-pixels", type=int, default=0)
    args = parser.parse_args()
    if args.max_diff < 0 or args.max_changed_pixels < 0:
        parser.error("comparison limits must be non-negative")
    try:
        return compare(args.reference, args.candidate, args.max_diff, args.max_changed_pixels)
    except (OSError, ValueError, zlib.error, struct.error) as error:
        print(f"FAIL {args.reference} vs {args.candidate}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
