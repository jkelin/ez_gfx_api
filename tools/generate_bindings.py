#!/usr/bin/env python3
"""Generate include/ez_gfx_api.h from manually maintained bindings/bindings.xml."""
from __future__ import annotations

import argparse
import html
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


POINTER_TYPES = {"void *", "const void *", "const char *", "uint8_t *", "const uint8_t *"}


def required(element: ET.Element, name: str) -> str:
    value = element.get(name)
    if value is None or value == "":
        raise ValueError(f"{element.tag} {element.get('name', '<unnamed>')} is missing {name}")
    return value


def ctype(value: str) -> str:
    return " ".join(value.split())


def doc(element: ET.Element, fallback: str = "") -> str:
    return element.get("doc", fallback).strip()


def validate(root: ET.Element) -> tuple[list[ET.Element], list[ET.Element], list[ET.Element], int]:
    if root.tag != "ez-gfx-bindings":
        raise ValueError("root element must be ez-gfx-bindings")
    abi = int(required(root, "abi-version"))
    def children(name: str) -> list[ET.Element]:
        element = root.find(name)
        if element is None:
            raise ValueError(f"missing {name} section")
        return list(element)

    handles = children("handles")
    enums = children("enums")
    structs = children("structs")
    functions = children("functions")
    all_names: set[str] = set()
    for group in (handles, enums, structs, functions):
        for item in group:
            name = required(item, "name")
            if name in all_names:
                raise ValueError(f"duplicate public name: {name}")
            all_names.add(name)
    enum_names = {item.get("name") for item in enums}
    for enum in enums:
        values: set[str] = set()
        for value in enum:
            if value.tag != "value":
                raise ValueError(f"unsupported element {value.tag} in enum {enum.get('name')}")
            name = required(value, "name")
            if name in values:
                raise ValueError(f"duplicate enum value {name}")
            values.add(name)
            int(value.get("value", ""))
    struct_names = {item.get("name") for item in structs}
    handle_names = {item.get("name") for item in handles}
    known_types = handle_names | enum_names | struct_names | {
        "void", "char", "uint8_t", "uint32_t", "int32_t", "uint64_t", "int64_t", "size_t", "float",
    }

    def known_type(value: str) -> bool:
        normalized = ctype(value)
        while normalized.endswith("*"):
            normalized = normalized[:-1].strip()
        if normalized.startswith("const "):
            normalized = normalized[6:].strip()
        return normalized in known_types

    for struct in structs:
        fields: set[str] = set()
        for field in struct:
            if field.tag != "field":
                raise ValueError(f"unsupported element {field.tag} in struct {struct.get('name')}")
            name = required(field, "name")
            if name in fields:
                raise ValueError(f"duplicate field {struct.get('name')}.{name}")
            fields.add(name)
            field_type = ctype(required(field, "type"))
            if not known_type(field_type):
                raise ValueError(f"unknown type {field_type} in {struct.get('name')}.{name}")
            counted_by = field.get("counted-by")
            if counted_by and counted_by not in fields:
                raise ValueError(f"counted-by field {counted_by} must precede {struct.get('name')}.{name}")

    function_names: set[str] = set()
    for function in functions:
        name = required(function, "name")
        if name in function_names:
            raise ValueError(f"duplicate function {name}")
        function_names.add(name)
        required(function, "return")
        params = [child for child in function if child.tag == "param"]
        for child in function:
            if child.tag not in {"param", "returns"}:
                raise ValueError(f"unsupported element {child.tag} in function {name}")
        param_names: set[str] = set()
        for param in params:
            param_name = required(param, "name")
            if param_name in param_names:
                raise ValueError(f"duplicate parameter {name}.{param_name}")
            param_names.add(param_name)
            param_type = ctype(required(param, "type"))
            if not known_type(param_type):
                raise ValueError(f"unknown type {param_type} in {name}.{param_name}")
            array_length = param.get("array-length")
            if array_length and array_length not in param_names and array_length not in {p.get("name") for p in params}:
                raise ValueError(f"array length {array_length} is missing in {name}")
            array_byte_size = param.get("array-byte-size")
            if array_byte_size and not array_length:
                raise ValueError(f"array byte size {array_byte_size} requires array length in {name}")
            if array_byte_size and array_byte_size not in param_names and array_byte_size not in {p.get("name") for p in params}:
                raise ValueError(f"array byte size {array_byte_size} is missing in {name}")
        if function.get("context") == "last":
            if not params or params[-1].get("name") != "context":
                raise ValueError(f"context=last requires final context parameter in {name}")
            if ctype(params[-1].get("type", "")) != "EzGfxContext":
                raise ValueError(f"final context parameter has wrong type in {name}")
    return handles, enums, structs, abi


def gi_annotation(param: ET.Element) -> str:
    pieces: list[str] = []
    direction = param.get("direction")
    if direction == "out":
        pieces.append("out caller-allocates")
    elif direction == "in":
        pieces.append("in")
    if param.get("nullable") == "true":
        pieces.append("nullable")
    elif param.get("nullable") == "false":
        pieces.append("not nullable")
    byte_size = param.get("array-byte-size")
    if byte_size:
        pieces.append(f"bytes={byte_size}")
    length = param.get("array-length")
    if length:
        pieces.append(f"array length={length}")
    return f" ({') ('.join(pieces)})" if pieces else ""


def function_comment(function: ET.Element) -> list[str]:
    name = required(function, "name")
    lines = ["/**", f" * {name}:"]
    for param in (child for child in function if child.tag == "param"):
        lines.append(f" * @{param.get('name')}{gi_annotation(param)}: {doc(param)}")
    lines.append(" *")
    returns = function.find("returns")
    returns_text = doc(returns) if returns is not None else "Returns the operation status."
    lines.append(f" * Returns: (transfer none): {returns_text}")
    lines.append(" */")
    return lines


def type_comment(element: ET.Element, kind: str) -> list[str]:
    name = required(element, "name")
    lines = ["/**", f" * {name}:"]
    if kind == "enum":
        for value in element:
            lines.append(f" * @{required(value, 'name')}: {doc(value)}")
    elif kind == "struct":
        for field in element:
            annotation = ""
            if field.get("nullable") == "true":
                annotation = " (nullable)"
            elif field.get("nullable") == "false":
                annotation = " (not nullable)"
            if field.get("counted-by"):
                annotation += f" (array length={field.get('counted-by')})"
            lines.append(f" * @{required(field, 'name')}{annotation}: {doc(field)}")
    lines.append(" *")
    lines.append(f" * {doc(element)}")
    lines.append(" */")
    return lines
def access_attributes(function: ET.Element) -> list[str]:
    params = [child for child in function if child.tag == "param"]
    attrs: list[str] = []
    for index, param in enumerate(params, 1):
        if param.tag != "param" or not param.get("array-length") or param.get("array-byte-size"):
            continue
        if "*" not in ctype(param.get("type", "")):
            continue
        mode = "write_only" if param.get("direction") == "out" else "read_only"
        length_name = param.get("array-length")
        length_index = next((i for i, item in enumerate(params, 1) if item.get("name") == length_name), None)
        if length_index is None:
            raise ValueError(f"missing array length parameter {length_name}")
        attrs.append(f"EZ_GFX_ACCESS({mode}, {index}, {length_index})")
    for index, param in enumerate(params, 1):
        if param.tag == "param" and param.get("direction") == "out" and "*" in ctype(param.get("type", "")) and not param.get("array-length"):
            attrs.append(f"EZ_GFX_ACCESS(write_only, {index})")
    return attrs


def generate(root: ET.Element) -> str:
    handles, enums, structs, abi = validate(root)
    functions_element = root.find("functions")
    if functions_element is None:
        raise ValueError("missing functions section")
    functions = list(functions_element)
    output: list[str] = [
        "#ifndef EZ_GFX_API_H",
        "#define EZ_GFX_API_H",
        "",
        "#include <stdint.h>",
        "#include <stddef.h>",
        "",
        f"#define EZ_GFX_ABI_VERSION {abi}u",
        "",
        "#if defined(__clang__)",
        "#  if __has_attribute(access)",
        "#    define EZ_GFX_ACCESS(...) __attribute__((access(__VA_ARGS__)))",
        "#  else",
        "#    define EZ_GFX_ACCESS(...)",
        "#  endif",
        "#  if __has_attribute(counted_by)",
        "#    define EZ_GFX_COUNTED_BY(field) __attribute__((counted_by(field)))",
        "#  else",
        "#    define EZ_GFX_COUNTED_BY(field)",
        "#  endif",
        "#elif defined(__GNUC__) && (__GNUC__ >= 10)",
        "#  define EZ_GFX_ACCESS(...) __attribute__((access(__VA_ARGS__)))",
        "#  define EZ_GFX_COUNTED_BY(field)",
        "#else",
        "#  define EZ_GFX_ACCESS(...)",
        "#  define EZ_GFX_COUNTED_BY(field)",
        "#endif",
        "",
        "/* ABI string contract: every const char* is UTF-8 and NUL-terminated for the duration of the call. */",
        "",
        "#ifdef __cplusplus",
        'extern "C" {',
        "#endif",
        "",
    ]
    for handle in handles:
        handle_name = required(handle, "name")
        output.extend(["/**", f" * {handle_name}: {doc(handle)}", " */"])
        output.append(f"typedef uint64_t {handle_name};")
    output.append("")
    for enum in enums:
        name = required(enum, "name")
        output.extend(type_comment(enum, "enum"))
        output.append(f"typedef enum {name} {{")
        for value in enum:
            output.append(f"    {required(value, 'name')} = {int(required(value, 'value'))},")
        output.append(f"}} {name};")
        output.append("")
    for struct in structs:
        name = required(struct, "name")
        output.extend(type_comment(struct, "struct"))
        output.append(f"typedef struct {name} {{")
        for field in struct:
            field_name = required(field, "name")
            field_type = ctype(required(field, "type"))
            suffix = ""
            if field.get("counted-by"):
                suffix = f" EZ_GFX_COUNTED_BY({field.get('counted-by')})"
            output.append(f"    {field_type} {field_name}{suffix};")
        output.append(f"}} {name};")
        output.append("")
    for function in functions:
        output.extend(function_comment(function))
        name = required(function, "name")
        return_type = ctype(required(function, "return"))
        params = [child for child in function if child.tag == "param"]
        if not params:
            declaration = f"{return_type} {name}(void)"
        else:
            declaration = f"{return_type} {name}(" + ", ".join(f"{ctype(required(param, 'type'))} {required(param, 'name')}" for param in params) + ")"
        attrs = access_attributes(function)
        if attrs:
            declaration += " " + " ".join(attrs)
        output.append(declaration + ";")
        output.append("")
    output.extend(["#ifdef __cplusplus", "}", "#endif", "", "#endif", ""])
    return "\n".join(output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xml", default="bindings/bindings.xml")
    parser.add_argument("--header", default="include/ez_gfx_api.h")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        tree = ET.parse(args.xml)
        rendered = generate(tree.getroot())
        header_path = Path(args.header)
        if args.check:
            if not header_path.exists() or header_path.read_text(encoding="utf-8") != rendered:
                print(f"generated header is stale: {header_path}", file=sys.stderr)
                return 1
        else:
            header_path.write_text(rendered, encoding="utf-8", newline="\n")
    except (ET.ParseError, OSError, ValueError) as error:
        print(f"generate_bindings.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
