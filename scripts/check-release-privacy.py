#!/usr/bin/env python3
import getpass
import codecs
import json
import html
import os
import plistlib
import posixpath
import re
import stat
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from release_privacy_policy import (
    LOCAL_SERVICE_URL,
    LOCAL_SERVICE_URL_NAME,
    contains_local_service_url,
)


CHUNK_SIZE = 1024 * 1024
MAX_SYMLINK_TARGET = 4096
MAX_ARCHIVE_ENTRIES = 50000
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
MAX_PLIST_BYTES = 4 * 1024 * 1024
STRUCTURED_SUFFIXES = {".json", ".plist", ".strings", ".stringsdict", ".xcstrings", ".xml", ".xcscheme"}
STRUCTURED_METADATA_ERROR = "unparseable structured metadata"
OVERSIZED_STRUCTURED_METADATA = "oversized structured metadata"
INVALID_TEXT_ENCODING = "invalid text encoding"
ZERO_FILL_SECTION_TYPES = {0x1, 0xC, 0x12}
APPLEDOUBLE_MAGIC = b"\x00\x05\x16\x07"
MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
FLAGGED_DATA = {
    "machine path": re.compile(rb"/Users/|/private/var/|/Volumes/|/var/folders/"),
    "private key": re.compile(
        rb"(?:-----BEGIN (?:(?:RSA|EC|DSA|OPENSSH) )?(?:ENCRYPTED )?PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOCK-----)"
    ),
    "GitHub token": re.compile(
        rb"(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)"
    ),
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
}


def build_patterns(repository_root):
    patterns = dict(FLAGGED_DATA)
    patterns[LOCAL_SERVICE_URL_NAME] = LOCAL_SERVICE_URL
    patterns["repository path"] = re.compile(
        re.escape(repository_root.resolve().as_posix().encode())
    )
    home = Path.home().as_posix().encode()
    if len(home) > len("/Users/"):
        patterns["home path"] = re.compile(re.escape(home))
    username = getpass.getuser().encode()
    if len(username) >= 3:
        patterns["user name"] = re.compile(rb"\b" + re.escape(username) + rb"\b")
    return patterns


def iter_entries(directory):
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            yield path
            if entry.is_dir(follow_symlinks=False):
                yield from iter_entries(path)


def matching_names(data, patterns):
    matches = [
        name
        for name, pattern in patterns.items()
        if name != LOCAL_SERVICE_URL_NAME and pattern.search(data)
    ]
    if LOCAL_SERVICE_URL_NAME in patterns and contains_local_service_url(data):
        matches.append(LOCAL_SERVICE_URL_NAME)
    return matches


def plist_value_data(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield from plist_value_data(key)
            yield from plist_value_data(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from plist_value_data(item)
    elif isinstance(value, bytes):
        yield value
    elif isinstance(value, str):
        yield value.encode()


def text_encodings(data):
    if data.startswith((b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff")):
        return ("utf-32",)
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return ("utf-16",)
    if len(data) >= 4 and data[:3] == b"\x00\x00\x00":
        return ("utf-32-be",)
    if len(data) >= 4 and data[1:4] == b"\x00\x00\x00":
        return ("utf-32-le",)
    if len(data) >= 4 and data[0:1] == b"\x00" and data[2:3] == b"\x00":
        return ("utf-16-be",)
    if len(data) >= 4 and data[1:2] == b"\x00" and data[3:4] == b"\x00":
        return ("utf-16-le",)
    return ("utf-8-sig", "utf-16-le", "utf-16-be", "utf-32-le", "utf-32-be")


def decode_text(data):
    for encoding in text_encodings(data):
        try:
            text = data.decode(encoding)
        except UnicodeDecodeError:
            continue
        if "\x00" not in text:
            return text
    return None
def metadata_matches(data, patterns):
    matches = matching_names(data, patterns)
    text = decode_text(data)
    if text is not None:
        matches.extend(matching_names(text.encode(), patterns))
    return list(dict.fromkeys(matches))


def plist_has_duplicate_keys(data):
    try:
        root = ET.fromstring(data)
    except (ET.ParseError, UnicodeError):
        return False

    def local_name(tag):
        return tag.rsplit("}", 1)[-1]

    def has_duplicates(element):
        if local_name(element.tag) == "dict":
            keys = set()
            for child in element:
                if local_name(child.tag) == "key":
                    key = child.text or ""
                    if key in keys:
                        return True
                    keys.add(key)
                if has_duplicates(child):
                    return True
        else:
            for child in element:
                if has_duplicates(child):
                    return True
        return False

    return has_duplicates(root)

def binary_plist_has_duplicate_keys(data):
    if not data.startswith(b"bplist00"):
        return False
    if len(data) < 40:
        return True
    trailer = data[-32:]
    offset_size = trailer[6]
    reference_size = trailer[7]
    object_count = int.from_bytes(trailer[8:16], "big")
    top_object = int.from_bytes(trailer[16:24], "big")
    offset_table = int.from_bytes(trailer[24:32], "big")
    if (
        offset_size not in {1, 2, 4, 8}
        or reference_size not in {1, 2, 4, 8}
        or not 0 < object_count <= 1000000
        or top_object >= object_count
        or offset_table + object_count * offset_size > len(data) - 32
    ):
        return True

    offsets = [
        int.from_bytes(
            data[offset_table + index * offset_size : offset_table + (index + 1) * offset_size],
            "big",
        )
        for index in range(object_count)
    ]
    if any(offset >= len(data) - 32 for offset in offsets):
        return True

    def object_position(reference):
        if reference >= object_count:
            raise ValueError
        return offsets[reference]

    def count_and_position(position, info):
        if info != 0xF:
            return info, position
        if position + 1 > len(data):
            raise ValueError
        marker = data[position]
        if marker >> 4 != 0x1:
            raise ValueError
        byte_count = 1 << (marker & 0xF)
        if byte_count > 8 or position + 1 + byte_count > len(data):
            raise ValueError
        return (
            int.from_bytes(data[position + 1 : position + 1 + byte_count], "big"),
            position + 1 + byte_count,
        )

    def object_string(reference):
        position = object_position(reference)
        marker = data[position]
        kind, info = marker >> 4, marker & 0xF
        if kind not in {0x5, 0x6}:
            return None
        count, start = count_and_position(position + 1, info)
        byte_length = count if kind == 0x5 else count * 2
        end = start + byte_length
        if end > len(data):
            raise ValueError
        encoding = "ascii" if kind == 0x5 else "utf-16-be"
        return data[start:end].decode(encoding)

    def walk(reference, visited):
        if reference in visited:
            return False
        visited.add(reference)
        position = object_position(reference)
        marker = data[position]
        kind, info = marker >> 4, marker & 0xF
        if kind in {0xA, 0xC}:
            count, start = count_and_position(position + 1, info)
            end = start + count * reference_size
            if end > len(data):
                raise ValueError
            return any(
                walk(
                    int.from_bytes(
                        data[start + index * reference_size : start + (index + 1) * reference_size],
                        "big",
                    ),
                    visited,
                )
                for index in range(count)
            )
        if kind != 0xD:
            return False
        count, start = count_and_position(position + 1, info)
        refs_end = start + count * reference_size * 2
        if refs_end > len(data):
            raise ValueError
        keys = [
            int.from_bytes(
                data[start + index * reference_size : start + (index + 1) * reference_size],
                "big",
            )
            for index in range(count)
        ]
        values_start = start + count * reference_size
        values = [
            int.from_bytes(
                data[values_start + index * reference_size : values_start + (index + 1) * reference_size],
                "big",
            )
            for index in range(count)
        ]
        key_values = [object_string(reference) for reference in keys]
        if any(value is None for value in key_values) or len(set(key_values)) != len(key_values):
            return True
        return any(walk(reference, visited) for reference in values)

    try:
        return walk(top_object, set())
    except (UnicodeDecodeError, ValueError, IndexError):
        return True

def is_appledouble(name, data):
    if not Path(name).name.startswith("._") or not data.startswith(APPLEDOUBLE_MAGIC):
        return False
    if len(data) < 26 or int.from_bytes(data[4:8], "big") != 0x00020000:
        return False
    entry_count = int.from_bytes(data[24:26], "big")
    table_end = 26 + entry_count * 12
    if table_end > len(data):
        return False
    entry_end = table_end
    for index in range(entry_count):
        entry = 26 + index * 12
        offset = int.from_bytes(data[entry + 4 : entry + 8], "big")
        length = int.from_bytes(data[entry + 8 : entry + 12], "big")
        if offset < table_end or offset + length > len(data):
            return False
        entry_end = max(entry_end, offset + length)
    if entry_end != len(data):
        return False
    return True

def structured_matches(name, data, patterns):
    suffix = Path(name).suffix.lower()
    if is_appledouble(name, data):
        return []
    if suffix == ".plist":
        if plist_has_duplicate_keys(data) or binary_plist_has_duplicate_keys(data):
            return [STRUCTURED_METADATA_ERROR]
        try:
            value = plistlib.loads(data)
        except (plistlib.InvalidFileException, ValueError, TypeError):
            return [STRUCTURED_METADATA_ERROR]
        return [
            match
            for item in plist_value_data(value)
            for match in matching_names(item, patterns)
        ]
    if suffix in {".json", ".xcstrings"}:
        try:
            value = json.loads(data, object_pairs_hook=lambda pairs: pairs)
        except (json.JSONDecodeError, ValueError, TypeError):
            return [STRUCTURED_METADATA_ERROR]
        return [
            match
            for item in plist_value_data(value)
            for match in matching_names(item, patterns)
        ]
    if suffix == ".strings":
        text = decode_text(data)
        return (
            [STRUCTURED_METADATA_ERROR]
            if text is None
            else matching_names(text.encode(), patterns)
        )
    if suffix in {".xml", ".xcscheme", ".stringsdict"}:
        text = decode_text(data)
        if text is None:
            return [STRUCTURED_METADATA_ERROR]
        source_matches = matching_names(html.unescape(text).encode(), patterns)
        try:
            root = ET.fromstring(data)
        except (ET.ParseError, UnicodeError):
            return [STRUCTURED_METADATA_ERROR]
        values = []
        for element in root.iter():
            values.extend((element.tag, element.text, element.tail))
            values.extend(element.attrib.keys())
            values.extend(element.attrib.values())
        value_matches = [
            match
            for item in values
            if item is not None
            for match in matching_names(item.encode(), patterns)
        ]
        return list(dict.fromkeys(source_matches + value_matches))
    return []


def scan_structured_file(path, patterns):
    if path.suffix.lower() not in STRUCTURED_SUFFIXES:
        return []
    if path.stat().st_size > MAX_PLIST_BYTES:
        return [OVERSIZED_STRUCTURED_METADATA]
    return structured_matches(path.name, path.read_bytes(), patterns)




def scan_stream(stream, patterns, decode_text=True):
    matches = []
    remaining = set(patterns)
    raw_overlap = max(
        (len(pattern.pattern) for pattern in patterns.values()),
        default=1,
    )
    text_overlap = raw_overlap
    raw_previous = b""
    text_previous = ""
    decoder = None
    first_chunk = True

    def decoder_for(chunk):
        if not decode_text:
            return None
        encoding = text_encodings(chunk)[0]
        if encoding == "utf-8-sig":
            return None
        return codecs.getincrementaldecoder(encoding)()

    while remaining:
        chunk = stream.read(CHUNK_SIZE)
        if not chunk:
            break
        if first_chunk:
            decoder = decoder_for(chunk)
            first_chunk = False
        data = raw_previous + chunk
        for name in matching_names(data, patterns):
            if name in remaining:
                matches.append(name)
                remaining.remove(name)
        raw_previous = data[-raw_overlap:]
        if decoder is not None and remaining:
            try:
                decoded = decoder.decode(chunk, final=False)
            except UnicodeDecodeError:
                matches.append(INVALID_TEXT_ENCODING)
                decoder = None
            else:
                text_data = text_previous + decoded
                for name in matching_names(text_data.encode(), patterns):
                    if name in remaining:
                        matches.append(name)
                        remaining.remove(name)
                text_previous = text_data[-text_overlap:]

    if decoder is not None and remaining:
        try:
            decoded = decoder.decode(b"", final=True)
        except UnicodeDecodeError:
            matches.append(INVALID_TEXT_ENCODING)
        else:
            text_data = text_previous + decoded
            for name in matching_names(text_data.encode(), patterns):
                if name in remaining:
                    matches.append(name)
    return matches


def scan(app, patterns):
    app_root = app.resolve()
    failures = []
    for path in iter_entries(app):
        relative_path = path.relative_to(app)
        if path.is_symlink():
            try:
                resolved = path.resolve(strict=False)
            except (OSError, RuntimeError):
                failures.append((relative_path, "unresolvable symlink"))
                continue
            try:
                resolved.relative_to(app_root)
            except ValueError:
                failures.append((relative_path, "external symlink"))
                continue
            failures.extend(
                (relative_path, name)
                for name in matching_names(os.fsencode(os.readlink(path)), patterns)
            )

        try:
            metadata = os.stat(path, follow_symlinks=False)
        except OSError:
            failures.append((relative_path, "file metadata could not be read"))
            continue
        if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink > 1:
            failures.append((relative_path, "hard-linked file"))

        if path.is_file():
            with path.open("rb") as stream:
                failures.extend(
                    (relative_path, name)
                    for name in scan_stream(
                        stream,
                        patterns,
                        decode_text=not path.name.startswith("._"),
                    )
                )
            failures.extend(
                (relative_path, name)
                for name in scan_structured_file(path, patterns)
            )
    return failures


def archive_symlink(info):
    mode = (info.external_attr >> 16) & 0o170000
    return stat.S_ISLNK(mode)


def archive_link_is_external(name, target):
    if not target or target.startswith("/") or "\x00" in target:
        return True
    root = name.split("/", 1)[0]
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
    return resolved != root and not resolved.startswith(root + "/")


def archive_directory_info(archive):
    with archive.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        file_size = stream.tell()
        tail_size = min(file_size, 22 + 65535)
        stream.seek(file_size - tail_size)
        tail = stream.read(tail_size)

    for offset in range(len(tail) - 22, -1, -1):
        if tail[offset : offset + 4] != b"PK\x05\x06":
            continue
        comment_length = int.from_bytes(tail[offset + 20 : offset + 22], "little")
        if offset + 22 + comment_length != len(tail):
            continue
        disk = int.from_bytes(tail[offset + 4 : offset + 6], "little")
        central_disk = int.from_bytes(tail[offset + 6 : offset + 8], "little")
        entries_on_disk = int.from_bytes(tail[offset + 8 : offset + 10], "little")
        entries = int.from_bytes(tail[offset + 10 : offset + 12], "little")
        central_size = int.from_bytes(tail[offset + 12 : offset + 16], "little")
        central_offset = int.from_bytes(tail[offset + 16 : offset + 20], "little")
        if (
            0xFFFF in (entries_on_disk, entries)
            or 0xFFFFFFFF in (central_size, central_offset)
        ):
            raise zipfile.BadZipFile("ZIP64 archives are not supported")
        if disk != 0 or central_disk != 0 or entries_on_disk != entries:
            raise zipfile.BadZipFile("multi-disk archives are not supported")
        end_offset = file_size - tail_size + offset
        concatenation = end_offset - (central_offset + central_size)
        if concatenation != 0:
            raise zipfile.BadZipFile("ZIP preambles are not supported")
        central_start = central_offset + concatenation
        if central_start < 0 or central_start + central_size != end_offset:
            continue
        return entries, central_start, central_size
    raise zipfile.BadZipFile("end of central directory not found")


def central_directory_count(archive, offset, size):
    count = 0
    with archive.open("rb") as stream:
        stream.seek(offset)
        remaining = size
        while remaining:
            if remaining < 4:
                raise zipfile.BadZipFile("truncated central directory")
            signature = stream.read(4)
            if signature == b"PK\x01\x02":
                if remaining < 46:
                    raise zipfile.BadZipFile("truncated central directory entry")
                fixed = stream.read(42)
                name_size = int.from_bytes(fixed[24:26], "little")
                extra_size = int.from_bytes(fixed[26:28], "little")
                comment_size = int.from_bytes(fixed[28:30], "little")
                variable_size = name_size + extra_size + comment_size
                record_size = 46 + variable_size
                if record_size > remaining:
                    raise zipfile.BadZipFile("truncated central directory entry")
                stream.seek(variable_size, os.SEEK_CUR)
                count += 1
                if count > MAX_ARCHIVE_ENTRIES:
                    return count
            elif signature == b"PK\x05\x05":
                if remaining < 6:
                    raise zipfile.BadZipFile("truncated central directory signature")
                signature_size = int.from_bytes(stream.read(2), "little")
                record_size = 6 + signature_size
                if record_size > remaining:
                    raise zipfile.BadZipFile("truncated central directory signature")
                stream.seek(signature_size, os.SEEK_CUR)
            else:
                raise zipfile.BadZipFile("invalid central directory signature")
            remaining -= record_size
    return count


def scan_local_header(stream, info, patterns):
    stream.seek(info.header_offset)
    header = stream.read(30)
    if len(header) != 30 or header[:4] != b"PK\x03\x04":
        raise zipfile.BadZipFile("invalid local file header")
    flags = int.from_bytes(header[6:8], "little")
    name_size = int.from_bytes(header[26:28], "little")
    extra_size = int.from_bytes(header[28:30], "little")
    local_name = stream.read(name_size)
    local_extra = stream.read(extra_size)
    if len(local_name) != name_size or len(local_extra) != extra_size:
        raise zipfile.BadZipFile("truncated local file header")
    matches = metadata_matches(local_name, patterns) + metadata_matches(local_extra, patterns)
    data_end = stream.tell() + info.compress_size
    record_end = data_end
    if flags & 0x8:
        stream.seek(data_end)
        descriptor_prefix = stream.read(4)
        if len(descriptor_prefix) != 4:
            raise zipfile.BadZipFile("truncated data descriptor")
        zip64 = info.compress_size > 0xFFFFFFFF or info.file_size > 0xFFFFFFFF
        descriptor_size = 24 if zip64 else 16
        if descriptor_prefix != b"PK\x07\x08":
            descriptor_size -= 4
        stream.seek(descriptor_size - 4, os.SEEK_CUR)
        record_end += descriptor_size
    return matches, record_end

def validate_macho_stream(stream, file_size):
    thin_formats = {
        b"\xfe\xed\xfa\xce": (">", 28),
        b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xfe\xed\xfa\xcf": (">", 32),
        b"\xcf\xfa\xed\xfe": ("<", 32),
    }
    fat_formats = {
        b"\xca\xfe\xba\xbe": (">", 20),
        b"\xbe\xba\xfe\xca": ("<", 20),
        b"\xca\xfe\xba\xbf": (">", 32),
        b"\xbf\xba\xfe\xca": ("<", 32),
    }

    def validate_thin(offset, size):
        stream.seek(offset)
        magic = stream.read(4)
        if magic not in thin_formats:
            return False
        endian, header_size = thin_formats[magic]
        header = magic + stream.read(header_size - 4)
        if len(header) != header_size or size < header_size:
            return False
        cpu_type = struct.unpack(endian + "I", header[4:8])[0]
        cpu_subtype = struct.unpack(endian + "I", header[8:12])[0] & 0x00FFFFFF
        filetype = struct.unpack(endian + "I", header[12:16])[0]
        ncmds = struct.unpack(endian + "I", header[16:20])[0]
        sizeofcmds = struct.unpack(endian + "I", header[20:24])[0]
        supported_subtypes = {
            0x01000007: {3, 4, 8, 9, 10, 11, 12, 13},
            0x0100000C: {0, 1, 2},
        }
        if (
            cpu_subtype not in supported_subtypes.get(cpu_type, set())
            or filetype != 2
            or not 0 < ncmds <= 65535
        ):
            return False
        if sizeofcmds < ncmds * 8 or header_size + sizeofcmds > size:
            return False

        stream.seek(offset + header_size)
        remaining = sizeofcmds
        has_segment = False
        executable_sections = []
        entrypoint_offset = None
        minimum_command_sizes = {1: 56, 0x19: 72, 0x80000028: 24}
        for _ in range(ncmds):
            if remaining < 8:
                return False
            command = stream.read(8)
            if len(command) != 8:
                return False
            command_type = struct.unpack(endian + "I", command[:4])[0]
            command_size = struct.unpack(endian + "I", command[4:])[0]
            minimum_size = minimum_command_sizes.get(command_type, 8)
            if (
                command_size < minimum_size
                or command_size % 4
                or command_size > remaining
            ):
                return False
            load_command = command + stream.read(command_size - 8)
            if len(load_command) != command_size:
                return False
            if command_type == 1:
                section_count = struct.unpack(endian + "I", load_command[48:52])[0]
                if command_size < 56 + section_count * 68:
                    return False
                vm_size = struct.unpack(endian + "I", load_command[28:32])[0]
                vm_address = struct.unpack(endian + "I", load_command[24:28])[0]
                file_offset = struct.unpack(endian + "I", load_command[32:36])[0]
                file_size = struct.unpack(endian + "I", load_command[36:40])[0]
                max_protection = struct.unpack(endian + "I", load_command[40:44])[0]
                init_protection = struct.unpack(endian + "I", load_command[44:48])[0]
                if (
                    not vm_size
                    or file_offset + file_size > size
                    or init_protection & ~max_protection
                ):
                    return False
                for index in range(section_count):
                        section_start = 56 + index * 68
                        section_size = struct.unpack(
                            endian + "I", load_command[section_start + 36 : section_start + 40]
                        )[0]
                        section_address = struct.unpack(
                            endian + "I", load_command[section_start + 32 : section_start + 36]
                        )[0]
                        section_offset = struct.unpack(
                            endian + "I", load_command[section_start + 40 : section_start + 44]
                        )[0]
                        section_flags = struct.unpack(
                            endian + "I", load_command[section_start + 56 : section_start + 60]
                        )[0]
                        section_type = section_flags & 0xFF
                        if (
                            section_address < vm_address
                            or section_address + section_size > vm_address + vm_size
                            or (
                                section_type not in ZERO_FILL_SECTION_TYPES
                                and (
                                    section_offset < file_offset
                                    or section_offset + section_size > file_offset + file_size
                                )
                            )
                        ):
                            return False
                        if (
                            init_protection & 0x4
                            and section_type not in ZERO_FILL_SECTION_TYPES
                            and section_size
                            and section_flags & 0x80000400
                        ):
                            executable_sections.append((section_offset, section_size))
                has_segment = True
            elif command_type == 0x19:
                section_count = struct.unpack(endian + "I", load_command[64:68])[0]
                if command_size < 72 + section_count * 80:
                    return False
                vm_size = struct.unpack(endian + "Q", load_command[32:40])[0]
                vm_address = struct.unpack(endian + "Q", load_command[24:32])[0]
                file_offset = struct.unpack(endian + "Q", load_command[40:48])[0]
                file_size = struct.unpack(endian + "Q", load_command[48:56])[0]
                max_protection = struct.unpack(endian + "I", load_command[56:60])[0]
                init_protection = struct.unpack(endian + "I", load_command[60:64])[0]
                if (
                    not vm_size
                    or file_offset + file_size > size
                    or init_protection & ~max_protection
                ):
                    return False
                for index in range(section_count):
                        section_start = 72 + index * 80
                        section_size = struct.unpack(
                            endian + "Q", load_command[section_start + 40 : section_start + 48]
                        )[0]
                        section_address = struct.unpack(
                            endian + "Q", load_command[section_start + 32 : section_start + 40]
                        )[0]
                        section_offset = struct.unpack(
                            endian + "I", load_command[section_start + 48 : section_start + 52]
                        )[0]
                        section_flags = struct.unpack(
                            endian + "I", load_command[section_start + 64 : section_start + 68]
                        )[0]
                        section_type = section_flags & 0xFF
                        if (
                            section_address < vm_address
                            or section_address + section_size > vm_address + vm_size
                            or (
                                section_type not in ZERO_FILL_SECTION_TYPES
                                and (
                                    section_offset < file_offset
                                    or section_offset + section_size > file_offset + file_size
                                )
                            )
                        ):
                            return False
                        if (
                            init_protection & 0x4
                            and section_type not in ZERO_FILL_SECTION_TYPES
                            and section_size
                            and section_flags & 0x80000400
                        ):
                            executable_sections.append((section_offset, section_size))
                has_segment = True
            elif command_type == 0x80000028:
                entrypoint_offset = struct.unpack(endian + "Q", load_command[8:16])[0]
                if entrypoint_offset < header_size + sizeofcmds or entrypoint_offset >= size:
                    return False
            remaining -= command_size
        return (
            remaining == 0
            and has_segment
            and entrypoint_offset is not None
            and any(
                start <= entrypoint_offset < start + length
                for start, length in executable_sections
            )
        )

    stream.seek(0)
    magic = stream.read(4)
    if magic in thin_formats:
        return validate_thin(0, file_size)
    if magic not in fat_formats:
        return False

    endian, arch_size = fat_formats[magic]
    count_bytes = stream.read(4)
    if len(count_bytes) != 4:
        return False
    count = struct.unpack(endian + "I", count_bytes)[0]
    table_end = 8 + count * arch_size
    if not 0 < count <= 128 or table_end > file_size:
        return False
    records = []
    supported_subtypes = {
        0x01000007: {3, 4, 8, 9, 10, 11, 12, 13},
        0x0100000C: {0, 1, 2},
    }
    seen_architectures = set()
    for _ in range(count):
        arch = stream.read(arch_size)
        if len(arch) != arch_size:
            return False
        arch_cpu, arch_subtype = struct.unpack(endian + "II", arch[:8])
        arch_subtype &= 0x00FFFFFF
        if arch_size == 20:
            slice_offset, slice_size = struct.unpack(endian + "II", arch[8:16])
            alignment = struct.unpack(endian + "I", arch[16:20])[0]
        else:
            slice_offset, slice_size = struct.unpack(endian + "QQ", arch[8:24])
            alignment = struct.unpack(endian + "I", arch[24:28])[0]
        if (
            arch_cpu not in supported_subtypes
            or arch_subtype not in supported_subtypes[arch_cpu]
            or alignment > 31
            or slice_offset % (1 << alignment)
            or slice_offset < table_end
            or slice_offset + slice_size > file_size
            or (arch_cpu, arch_subtype) in seen_architectures
        ):
            return False
        seen_architectures.add((arch_cpu, arch_subtype))
        records.append((slice_offset, slice_size, arch_cpu, arch_subtype))
    previous_end = table_end
    for slice_offset, slice_size, arch_cpu, arch_subtype in sorted(records):
        if slice_offset < previous_end:
            return False
        previous_end = slice_offset + slice_size
        stream.seek(slice_offset)
        slice_magic = stream.read(4)
        if slice_magic not in thin_formats:
            return False
        slice_endian = thin_formats[slice_magic][0]
        slice_cpu = struct.unpack(slice_endian + "I", stream.read(4))[0]
        slice_subtype = struct.unpack(slice_endian + "I", stream.read(4))[0] & 0x00FFFFFF
        if (slice_cpu, slice_subtype) != (arch_cpu, arch_subtype):
            return False
        if not validate_thin(slice_offset, slice_size):
            return False
    return True


def validate_plist_data(data, expected_executable, expected_bundle_identifier=None):
    if len(data) > MAX_PLIST_BYTES:
        return "Info.plist is too large"
    try:
        plist = plistlib.loads(data)
    except (plistlib.InvalidFileException, ValueError, TypeError):
        return "Info.plist is invalid"
    if not isinstance(plist, dict):
        return "Info.plist is not a dictionary"
    if plist.get("CFBundleExecutable") != expected_executable:
        return "Info.plist executable name does not match the app"
    if (
        expected_bundle_identifier is not None
        and plist.get("CFBundleIdentifier") != expected_bundle_identifier
    ):
        return "Info.plist bundle identifier does not match the requested identity"
    return None


def validate_app_bundle(app, expected_bundle_identifier=None):
    expected_executable = app.name[:-4]
    info_path = app / "Contents" / "Info.plist"
    executable_path = app / "Contents" / "MacOS" / expected_executable
    if info_path.is_symlink() or not info_path.is_file():
        return "Info.plist is missing or not a regular file"
    if executable_path.is_symlink() or not executable_path.is_file():
        return "app executable is missing or not a regular file"
    if not (executable_path.stat().st_mode & 0o111):
        return "app executable is not executable"
    try:
        with info_path.open("rb") as stream:
            plist_error = validate_plist_data(
                stream.read(MAX_PLIST_BYTES + 1),
                expected_executable,
                expected_bundle_identifier,
            )
        with executable_path.open("rb") as stream:
            is_macho = validate_macho_stream(stream, executable_path.stat().st_size)
    except OSError as error:
        return f"app bundle could not be read: {error}"
    if plist_error:
        return plist_error
    if not is_macho:
        return "app executable is not a valid Mach-O executable"
    return None


def archive_entry_is_executable(info):
    mode = (info.external_attr >> 16) & 0o777
    return bool(mode & 0o111)

def scan_archive(archive, patterns, expected_bundle_identifier=None):
    declared_count, central_offset, central_size = archive_directory_info(archive)
    actual_count = central_directory_count(archive, central_offset, central_size)
    if actual_count > MAX_ARCHIVE_ENTRIES:
        return [(Path("<archive>"), "too many archive entries")]
    if actual_count != declared_count:
        return [(Path("<archive>"), "inconsistent archive entry count")]

    failures = []
    total_uncompressed_bytes = 0
    app_roots = set()
    info_entry = None
    executable_entry = None
    archive_label = Path("<archive>")
    local_records = []
    with archive.open("rb") as raw_archive, zipfile.ZipFile(archive) as bundle:
        infos = bundle.infolist()
        if len(infos) != actual_count:
            return [(archive_label, "inconsistent archive entry count")]
        failures.extend(
            (Path("<archive comment>"), match)
            for match in metadata_matches(bundle.comment, patterns)
        )
        for info in infos:
            name = info.filename
            relative_path = Path(name)
            if name.startswith("/") or ".." in name.split("/"):
                failures.append((relative_path, "unsafe archive path"))
                continue
            failures.extend(
                (relative_path, match)
                for match in matching_names(name.encode(), patterns)
            )
            failures.extend(
                (relative_path, match)
                for metadata in (info.comment, info.extra)
                for match in metadata_matches(metadata, patterns)
            )
            local_matches, local_end = scan_local_header(raw_archive, info, patterns)
            local_records.append((info.header_offset, local_end))
            failures.extend(
                (relative_path, match) for match in local_matches
            )

            is_symlink = archive_symlink(info)
            root = name.split("/", 1)[0]
            if root.endswith(".app"):
                app_roots.add(root)
                app_name = root[:-4]
                if name == f"{root}/Contents/Info.plist":
                    info_entry = info
                if name == f"{root}/Contents/MacOS/{app_name}":
                    executable_entry = info

            total_uncompressed_bytes += info.file_size
            if total_uncompressed_bytes > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                failures.append((archive_label, "archive is too large to scan"))
                break

            if is_symlink:
                with bundle.open(info) as stream:
                    target_bytes = stream.read(MAX_SYMLINK_TARGET + 1)
                if len(target_bytes) > MAX_SYMLINK_TARGET:
                    failures.append((relative_path, "oversized symlink target"))
                    continue
                target = os.fsdecode(target_bytes)
                failures.extend(
                    (relative_path, match)
                    for match in metadata_matches(target_bytes, patterns)
                )
                if archive_link_is_external(name, target):
                    failures.append((relative_path, "external symlink"))
                continue
            if info.is_dir() and not info.file_size:
                continue
            with bundle.open(info) as stream:
                failures.extend(
                    (relative_path, match)
                    for match in scan_stream(
                        stream,
                        patterns,
                        decode_text=not Path(name).name.startswith("._"),
                    )
                )
            structured_suffix = Path(name).suffix.lower()
            if not is_symlink and not info.is_dir() and structured_suffix in STRUCTURED_SUFFIXES:
                if info.file_size > MAX_PLIST_BYTES:
                    failures.append((relative_path, OVERSIZED_STRUCTURED_METADATA))
                else:
                    with bundle.open(info) as stream:
                        structured_data = stream.read(MAX_PLIST_BYTES + 1)
                    failures.extend(
                        (relative_path, match)
                        for match in structured_matches(name, structured_data, patterns)
                    )

        local_records.sort()
        previous_end = 0
        for start, end in local_records:
            if start != previous_end:
                failures.append((archive_label, "unexpected bytes between ZIP records"))
                break
            previous_end = end
        if local_records and previous_end != central_offset:
            failures.append((archive_label, "unexpected bytes before central directory"))

        if len(app_roots) != 1 or info_entry is None or executable_entry is None:
            failures.append((archive_label, "must contain exactly one complete app bundle"))
        else:
            app_root = next(iter(app_roots))
            expected_executable = app_root[:-4]
            if info_entry.is_dir() or archive_symlink(info_entry):
                failures.append((Path(f"{app_root}/Contents/Info.plist"), "Info.plist is invalid"))
            else:
                with bundle.open(info_entry) as stream:
                    plist_error = validate_plist_data(
                        stream.read(MAX_PLIST_BYTES + 1),
                        expected_executable,
                        expected_bundle_identifier,
                    )
                if plist_error:
                    failures.append((Path(f"{app_root}/Contents/Info.plist"), plist_error))

            executable_path = Path(f"{app_root}/Contents/MacOS/{expected_executable}")
            if (
                executable_entry.is_dir()
                or archive_symlink(executable_entry)
                or not archive_entry_is_executable(executable_entry)
            ):
                failures.append((executable_path, "app executable is invalid"))
            else:
                with bundle.open(executable_entry) as stream:
                    if not validate_macho_stream(stream, executable_entry.file_size):
                        failures.append((executable_path, "app executable is not a valid Mach-O executable"))
    return failures


def main():
    if len(sys.argv) not in {3, 4}:
        print(
            "usage: check-release-privacy.py BUNDLE_PATH REPOSITORY_ROOT [BUNDLE_IDENTIFIER]",
            file=sys.stderr,
        )
        return 2

    bundle_path = Path(sys.argv[1])
    repository_root = Path(sys.argv[2]).resolve()
    expected_bundle_identifier = sys.argv[3] if len(sys.argv) == 4 else None
    if bundle_path.is_symlink():
        print(f"bundle path must not be a symlink: {bundle_path}", file=sys.stderr)
        return 2

    try:
        patterns = build_patterns(repository_root)
        if bundle_path.is_dir():
            app = bundle_path.resolve()
            if not app.name.endswith(".app") or not (app / "Contents").is_dir():
                print(f"unsupported app bundle: {bundle_path}", file=sys.stderr)
                return 2
            app_error = validate_app_bundle(app, expected_bundle_identifier)
            failures = (
                [(Path("<bundle>"), app_error)]
                if app_error
                else scan(app, patterns)
            )
        elif bundle_path.is_file() and zipfile.is_zipfile(bundle_path):
            failures = scan_archive(
                bundle_path, patterns, expected_bundle_identifier
            )
        else:
            print(f"bundle not found or unsupported: {bundle_path}", file=sys.stderr)
            return 2
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
        print(f"release privacy check could not read bundle: {error}", file=sys.stderr)
        return 2

    if not failures:
        return 0

    print("release privacy check failed:", file=sys.stderr)
    for relative_path, name in failures:
        print(f"  {relative_path}: {name}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())