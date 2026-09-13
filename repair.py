#!/usr/bin/env python3
"""Repair the malformed Mach-O signatures seen in injected IPA files."""

from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path

from repair_macho_signature import (
    LC_CODE_SIGNATURE,
    LC_SEGMENT_64,
    MACH_HEADER_64_SIZE,
    MH_MAGIC_64,
    repair,
)


UNSUPPORTED_MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",  # fat, big endian
    b"\xbe\xba\xfe\xca",  # fat, little endian
    b"\xca\xfe\xba\xbf",  # fat64, big endian
    b"\xbf\xba\xfe\xca",  # fat64, little endian
    b"\xfe\xed\xfa\xcf",  # 64-bit Mach-O, big endian
    b"\xce\xfa\xed\xfe",  # 32-bit Mach-O, little endian
    b"\xfe\xed\xfa\xce",  # 32-bit Mach-O, big endian
}


@dataclass(frozen=True)
class RepairCandidate:
    path: Path
    signature_size: int
    zero_padding_size: int


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def inspect_file(path: Path) -> tuple[RepairCandidate | None, bool]:
    """Return a repair candidate and whether this is an unsupported Mach-O."""
    with path.open("rb") as stream:
        magic_bytes = stream.read(4)
    if len(magic_bytes) != 4:
        return None, False
    if magic_bytes in UNSUPPORTED_MACHO_MAGICS:
        return None, True
    if struct.unpack("<I", magic_bytes)[0] != MH_MAGIC_64:
        return None, False

    data = path.read_bytes()
    if len(data) < MACH_HEADER_64_SIZE:
        raise ValueError("Mach-O header is truncated")

    _, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data, 0)
    commands_end = MACH_HEADER_64_SIZE + sizeofcmds
    if commands_end > len(data):
        raise ValueError("load-command table extends past end of file")

    signatures: list[tuple[int, int]] = []
    linkedits: list[tuple[int, int]] = []
    offset = MACH_HEADER_64_SIZE
    for _ in range(ncmds):
        if offset + 8 > commands_end:
            raise ValueError("truncated load command")
        command, command_size = struct.unpack_from("<2I", data, offset)
        if command_size < 8 or offset + command_size > commands_end:
            raise ValueError("invalid load-command size")
        if command == LC_CODE_SIGNATURE:
            if command_size != 16:
                raise ValueError("unexpected LC_CODE_SIGNATURE size")
            signatures.append(struct.unpack_from("<2I", data, offset + 8))
        elif command == LC_SEGMENT_64 and command_size >= 72:
            segment_name = data[offset + 8 : offset + 24].rstrip(b"\0")
            if segment_name == b"__LINKEDIT":
                linkedits.append(struct.unpack_from("<2Q", data, offset + 40))
        offset += command_size

    if offset != commands_end:
        raise ValueError("load-command sizes do not match Mach-O header")
    if not signatures:
        return None, False
    if len(signatures) != 1:
        raise ValueError(f"found {len(signatures)} LC_CODE_SIGNATURE commands")

    signature_offset, signature_size = signatures[0]
    signature_end = signature_offset + signature_size
    if signature_offset < commands_end or signature_end > len(data):
        raise ValueError("embedded-signature range is invalid")
    if signature_end == len(data):
        return None, False

    trailing = data[signature_end:]
    if any(trailing):
        raise ValueError("non-zero data exists after the embedded signature")
    if len(linkedits) != 1:
        raise ValueError(f"found {len(linkedits)} __LINKEDIT segments")
    linkedit_offset, linkedit_size = linkedits[0]
    if linkedit_offset + linkedit_size != len(data):
        raise ValueError("__LINKEDIT does not end at the end of the file")

    return RepairCandidate(path, signature_size, len(trailing)), False


def can_adhoc_sign_copy(path: Path) -> bool:
    """Test signing on an isolated copy without changing the IPA work tree."""
    with tempfile.TemporaryDirectory(prefix="ipa-repair-verify.") as directory:
        copy = Path(directory) / path.name
        shutil.copy2(path, copy)
        sign = subprocess.run(
            ["/usr/bin/codesign", "-f", "-s", "-", str(copy)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if sign.returncode != 0:
            return False
        verify = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", str(copy)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return verify.returncode == 0


def safe_archive_members(input_path: Path) -> None:
    result = subprocess.run(
        ["/usr/bin/unzip", "-Z1", str(input_path)],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="surrogateescape",
    )
    for name in result.stdout.splitlines():
        member = Path(name)
        if member.is_absolute() or ".." in member.parts:
            raise ValueError(f"unsafe archive path: {name}")


def default_output_path(input_path: Path) -> Path:
    return input_path.with_name(f"{input_path.stem}_repaired.ipa")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "修复注入 IPA 中签名尾部为全零填充、导致 codesign 内部错误的 "
            "Mach-O 文件，并生成新的 *_repaired.ipa。"
        )
    )
    parser.add_argument("ipa", type=Path, help="需要修复的 IPA 文件")
    parser.add_argument("-o", "--output", type=Path, help="输出 IPA 路径")
    parser.add_argument(
        "-f", "--force", action="store_true", help="允许覆盖已经存在的输出文件"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_path = args.ipa.expanduser().resolve()
    output_path = (args.output or default_output_path(input_path)).expanduser().resolve()

    if not input_path.is_file():
        print(f"错误：IPA 文件不存在：{input_path}", file=sys.stderr)
        return 2
    if input_path.suffix.lower() != ".ipa":
        print(f"错误：输入文件不是 .ipa：{input_path}", file=sys.stderr)
        return 2
    if input_path == output_path:
        print("错误：输出路径不能与输入 IPA 相同", file=sys.stderr)
        return 2
    if output_path.exists() and not args.force:
        print(f"错误：输出文件已存在：{output_path}", file=sys.stderr)
        print("如确定要覆盖，请增加 --force", file=sys.stderr)
        return 2
    if not output_path.parent.is_dir():
        print(f"错误：输出目录不存在：{output_path.parent}", file=sys.stderr)
        return 2

    try:
        safe_archive_members(input_path)
        with tempfile.TemporaryDirectory(prefix="ipa-repair.") as directory:
            workdir = Path(directory)
            run(["/usr/bin/unzip", "-q", str(input_path), "-d", str(workdir)])

            payload = workdir / "Payload"
            if not payload.is_dir() or not any(payload.glob("*.app")):
                raise ValueError("archive does not contain Payload/*.app")

            candidates: list[RepairCandidate] = []
            unsupported: list[Path] = []
            unsafe: list[tuple[Path, str]] = []
            for path in workdir.rglob("*"):
                if path.is_symlink() or not path.is_file():
                    continue
                try:
                    candidate, is_unsupported = inspect_file(path)
                except (OSError, ValueError, struct.error) as error:
                    unsafe.append((path, str(error)))
                    continue
                if candidate is not None:
                    # A small amount of signature padding can be accepted by
                    # codesign. Repair only when Apple's signer demonstrably
                    # cannot replace the existing signature on a throwaway copy.
                    if not can_adhoc_sign_copy(path):
                        candidates.append(candidate)
                elif is_unsupported:
                    unsupported.append(path)

            if unsafe:
                print("发现无法安全自动处理的 Mach-O，已停止且未生成输出：", file=sys.stderr)
                for path, reason in unsafe:
                    print(f"  {path.relative_to(workdir)}: {reason}", file=sys.stderr)
                return 1

            print(f"发现 {len(candidates)} 个符合安全条件的异常 Mach-O：")
            for candidate in candidates:
                relative = candidate.path.relative_to(workdir)
                print(
                    f"  {relative}（旧签名 {candidate.signature_size} 字节，"
                    f"多余零填充 {candidate.zero_padding_size} 字节）"
                )

            for candidate in candidates:
                repair(candidate.path)
                if not can_adhoc_sign_copy(candidate.path):
                    raise ValueError(
                        f"repaired binary is still not signable: "
                        f"{candidate.path.relative_to(workdir)}"
                    )

            if unsupported:
                print(
                    f"提示：检测到 {len(unsupported)} 个无需本工具处理或暂不支持的"
                    "多架构/非 64 位 Mach-O；它们保持原样。"
                )

            temp_output = output_path.parent / (
                f".{output_path.name}.{uuid.uuid4().hex}.tmp.ipa"
            )
            try:
                top_level_entries = sorted(path.name for path in workdir.iterdir())
                environment = os.environ.copy()
                environment["COPYFILE_DISABLE"] = "1"
                subprocess.run(
                    ["/usr/bin/zip", "-q", "-y", "-r", str(temp_output), *top_level_entries],
                    cwd=workdir,
                    env=environment,
                    check=True,
                )
                run(["/usr/bin/unzip", "-tq", str(temp_output)])
                if output_path.exists():
                    output_path.unlink()
                os.replace(temp_output, output_path)
            finally:
                if temp_output.exists():
                    temp_output.unlink()

        print(f"修复完成：{output_path}")
        if not candidates:
            print("未发现本工具针对的异常模式；输出内容仅重新打包，未修改 Mach-O。")
        print(f"下一步：./resign.sh {output_path.name}")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"修复失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
