#!/usr/bin/env python3
"""Remove a malformed embedded signature from a thin 64-bit Mach-O file.

The tool is deliberately conservative: it only accepts little-endian 64-bit
Mach-O files, requires exactly one LC_CODE_SIGNATURE command, and refuses to
discard non-zero bytes after the declared signature blob.
"""

from __future__ import annotations

import os
import struct
import sys
import tempfile
from pathlib import Path


MH_MAGIC_64 = 0xFEEDFACF
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19
MACH_HEADER_64_SIZE = 32
ARM64_PAGE_SIZE = 0x4000


def repair(path: Path) -> None:
    original = path.read_bytes()
    if len(original) < MACH_HEADER_64_SIZE:
        raise ValueError("file is too small to be a Mach-O binary")

    magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from(
        "<8I", original, 0
    )
    if magic != MH_MAGIC_64:
        raise ValueError("only little-endian thin 64-bit Mach-O is supported")

    commands_end = MACH_HEADER_64_SIZE + sizeofcmds
    if commands_end > len(original):
        raise ValueError("load-command table extends past end of file")

    command_offset = MACH_HEADER_64_SIZE
    signature_commands: list[tuple[int, int, int, int]] = []
    linkedit_commands: list[tuple[int, int, int]] = []
    for _ in range(ncmds):
        if command_offset + 8 > commands_end:
            raise ValueError("truncated load command")
        command, command_size = struct.unpack_from("<2I", original, command_offset)
        if command_size < 8 or command_offset + command_size > commands_end:
            raise ValueError("invalid load-command size")
        if command == LC_CODE_SIGNATURE:
            if command_size != 16:
                raise ValueError("unexpected LC_CODE_SIGNATURE size")
            data_offset, data_size = struct.unpack_from(
                "<2I", original, command_offset + 8
            )
            signature_commands.append(
                (command_offset, command_size, data_offset, data_size)
            )
        elif command == LC_SEGMENT_64 and command_size >= 72:
            segment_name = original[command_offset + 8 : command_offset + 24]
            if segment_name.rstrip(b"\0") == b"__LINKEDIT":
                file_offset, file_size = struct.unpack_from(
                    "<2Q", original, command_offset + 40
                )
                linkedit_commands.append((command_offset, file_offset, file_size))
        command_offset += command_size

    if command_offset != commands_end:
        raise ValueError("load-command sizes do not match Mach-O header")
    if len(signature_commands) != 1:
        raise ValueError(
            f"expected exactly one LC_CODE_SIGNATURE, found {len(signature_commands)}"
        )
    if len(linkedit_commands) != 1:
        raise ValueError(
            f"expected exactly one __LINKEDIT segment, found {len(linkedit_commands)}"
        )

    command_offset, command_size, data_offset, data_size = signature_commands[0]
    signature_end = data_offset + data_size
    if data_offset < commands_end or signature_end > len(original):
        raise ValueError("invalid embedded-signature range")
    if any(original[signature_end:]):
        raise ValueError("refusing to discard non-zero data after embedded signature")

    repaired = bytearray(original[:data_offset])
    following_commands = original[command_offset + command_size : commands_end]
    repaired[command_offset : command_offset + len(following_commands)] = following_commands
    repaired[commands_end - command_size : commands_end] = b"\0" * command_size
    struct.pack_into("<I", repaired, 16, ncmds - 1)
    struct.pack_into("<I", repaired, 20, sizeofcmds - command_size)

    linkedit_offset, linkedit_file_offset, _ = linkedit_commands[0]
    if linkedit_file_offset > data_offset:
        raise ValueError("__LINKEDIT starts after embedded signature")
    linkedit_file_size = data_offset - linkedit_file_offset
    linkedit_vm_size = (
        (linkedit_file_size + ARM64_PAGE_SIZE - 1) // ARM64_PAGE_SIZE
    ) * ARM64_PAGE_SIZE
    struct.pack_into("<Q", repaired, linkedit_offset + 32, linkedit_vm_size)
    struct.pack_into("<Q", repaired, linkedit_offset + 48, linkedit_file_size)

    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temp:
        temp.write(repaired)
        temp_path = Path(temp.name)
    os.chmod(temp_path, mode)
    os.replace(temp_path, path)

    print(
        f"repaired {path}: removed {data_size}-byte signature and "
        f"{len(original) - signature_end}-byte zero padding"
    )


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {Path(sys.argv[0]).name} MACHO [...]", file=sys.stderr)
        return 2

    status = 0
    for argument in sys.argv[1:]:
        path = Path(argument)
        try:
            repair(path)
        except (OSError, ValueError, struct.error) as error:
            print(f"error: {path}: {error}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
