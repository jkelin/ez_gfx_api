#!/usr/bin/env python3
"""Verify that every function declared by the C ABI header is exported by a PE DLL."""

from __future__ import annotations

import argparse
import re
import struct
import subprocess
from pathlib import Path

FUNCTION_PATTERN = re.compile(
    r"(?m)^\s*[A-Za-z_][A-Za-z0-9_\s\*]*\s+(ez_gfx_[A-Za-z0-9_]+)\s*\([^;]*\)\s*;"
)
DUMPBIN_EXPORT_PATTERN = re.compile(r"^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$")


def declared_functions(header: Path) -> set[str]:
    return set(FUNCTION_PATTERN.findall(header.read_text(encoding="utf-8")))


def dumpbin_exports(dll: Path) -> set[str] | None:
    try:
        completed = subprocess.run(
            ["dumpbin", "/exports", str(dll)],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    return {
        match.group(1)
        for line in completed.stdout.splitlines()
        if (match := DUMPBIN_EXPORT_PATTERN.match(line)) is not None
    }


def read_u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def c_string(data: bytes, offset: int) -> str:
    end = data.index(b"\0", offset)
    return data[offset:end].decode("ascii")


def pe_rva_to_offset(data: bytes, rva: int) -> int:
    pe_offset = read_u32(data, 0x3C)
    coff_offset = pe_offset + 4
    section_count = read_u16(data, coff_offset + 2)
    optional_size = read_u16(data, coff_offset + 16)
    section_offset = coff_offset + 20 + optional_size
    for index in range(section_count):
        current = section_offset + index * 40
        virtual_size = read_u32(data, current + 8)
        virtual_address = read_u32(data, current + 12)
        raw_size = read_u32(data, current + 16)
        raw_offset = read_u32(data, current + 20)
        section_size = max(virtual_size, raw_size)
        if virtual_address <= rva < virtual_address + section_size:
            return raw_offset + (rva - virtual_address)
    raise ValueError(f"RVA 0x{rva:X} is not in a PE section")


def pe_exports(dll: Path) -> set[str]:
    data = dll.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError(f"{dll} is not a PE image")
    pe_offset = read_u32(data, 0x3C)
    if data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise ValueError(f"{dll} has an invalid PE signature")
    optional_offset = pe_offset + 24
    magic = read_u16(data, optional_offset)
    data_directory_offset = optional_offset + (112 if magic == 0x20B else 96)
    export_rva = read_u32(data, data_directory_offset)
    if export_rva == 0:
        return set()
    export_offset = pe_rva_to_offset(data, export_rva)
    names_rva = read_u32(data, export_offset + 32)
    name_count = read_u32(data, export_offset + 24)
    names_offset = pe_rva_to_offset(data, names_rva)
    return {
        c_string(data, pe_rva_to_offset(data, read_u32(data, names_offset + index * 4)))
        for index in range(name_count)
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dll", type=Path, required=True)
    parser.add_argument("--header", type=Path, default=Path("include/ez_gfx_api.h"))
    args = parser.parse_args()

    if not args.dll.is_file():
        parser.error(f"DLL does not exist: {args.dll}")
    if not args.header.is_file():
        parser.error(f"header does not exist: {args.header}")

    expected = declared_functions(args.header)
    if not expected:
        parser.error(f"no ez_gfx declarations found in {args.header}")

    exports = dumpbin_exports(args.dll)
    source = "dumpbin"
    if exports is None:
        exports = pe_exports(args.dll)
        source = "PE export table"

    missing = sorted(expected - exports)
    if missing:
        print(f"missing exports ({source}):")
        for name in missing:
            print(f"  {name}")
        return 1

    print(f"exports ok: {len(expected)} declarations resolved via {source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
