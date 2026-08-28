#!/usr/bin/env python3
"""Generate a static dual-hart riscv-dv image and run Spike in the VM.

The generated artifacts live below the VMware shared directory.  The helper
itself is deployed by the Windows WebUI to a private VM cache directory.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any


SHARED_ROOT = Path("/mnt/hgfs/share/comp_log_dvspike").resolve()
DEFAULT_RISCV_DV = Path("/home/mtw/riscv-dv")
DEFAULT_CACHE = Path("/home/mtw/.cache/eh2logcomp_automation")
VCS_HOME = Path("/home/mtw/synopsys/vcs_2016.06/vcs/O-2018.09-SP2")
RESET_VECTOR = 0x80000000
PROGRAM_LIMIT = 0xA0000000
LSU_BASE = 0xA0000000
LSU_LIMIT = 0x1_0000_0000
DATA_BASE = 0xA0000000
DATA_LIMIT = 0xD0000000
AMO_BASE = 0xF0040000
AMO_LIMIT = 0xF0050000
GLOBAL_RE = re.compile(r"\.glob(?:l|al)\s+([A-Za-z_.$][\w.$]*)")
SPIKE_COMMIT_RE = re.compile(
    r"^core\s+(?P<hart>\d+):\s+\d+\s+0x[0-9a-fA-F]+\s+"
    r"\(0x(?P<insn>[0-9a-fA-F]{8})\)(?P<effects>.*)$"
)
SPIKE_MEM_RE = re.compile(r"\bmem\s+0x([0-9a-fA-F]{8})")


def atomic_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # VMware HGFS can transiently reject replacing a file while Windows is
    # reading it.  A per-process temporary name plus bounded retry prevents a
    # harmless WebUI poll from terminating the complete generation job.
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for attempt in range(20):
        try:
            os.replace(temporary, path)
            return
        except PermissionError:
            if attempt == 19:
                break
            time.sleep(0.05)
    # Direct replacement is less atomic but keeps the runner alive on HGFS.
    # Windows read_status already treats a transient partial JSON as "retry".
    path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.unlink(missing_ok=True)


def publish_file(source: Path, target: Path) -> None:
    """Publish one completed VM-local artifact to HGFS without partial reads."""

    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    shutil.copyfile(source, temporary)
    for attempt in range(20):
        try:
            os.replace(temporary, target)
            return
        except PermissionError:
            if attempt == 19:
                break
            time.sleep(0.05)
    # The WebUI cannot observe program.bin until PROGRAM_READY is reported,
    # and cannot compare spike.log until SPIKE_DONE is reported.  This direct
    # fallback is therefore safe if VMware refuses atomic replacement.
    shutil.copyfile(source, target)
    temporary.unlink(missing_ok=True)


def archive_failed_work_dir(work_dir: Path, shared_run_dir: Path) -> Path:
    """Keep local generator/compiler artifacts only when this run fails."""

    target = shared_run_dir / "vm_failure_artifacts"
    if target.exists():
        raise RuntimeError(f"failure artifact directory already exists: {target}")
    shutil.copytree(work_dir, target)
    return target


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class Status:
    def __init__(self, run_dir: Path, seed: int, target: int, chunks: int):
        self.path = run_dir / "status.json"
        self.started = time.time()
        self.monotonic_started = time.monotonic()
        self.current_stage = "STARTING"
        self.stage_started = self.monotonic_started
        self.stage_durations: dict[str, float] = {}
        self.document: dict[str, Any] = {
            "stage": "STARTING",
            "seed": seed,
            "target_instructions_per_hart": target,
            "total_chunks": chunks,
            "generated_chunks": 0,
            "compiled_chunks": 0,
            "program_ready": False,
            "spike_done": False,
            "failed": False,
            "message": "remote runner starting",
            "updated_at": time.time(),
            "stage_durations_seconds": {},
            "current_stage_elapsed_seconds": 0.0,
        }
        self.write()

    def update(self, stage: str | None = None, **values: Any) -> None:
        now_monotonic = time.monotonic()
        if stage is not None and stage != self.current_stage:
            elapsed = now_monotonic - self.stage_started
            self.stage_durations[self.current_stage] = (
                self.stage_durations.get(self.current_stage, 0.0) + elapsed
            )
            self.current_stage = stage
            self.stage_started = now_monotonic
        if stage is not None:
            self.document["stage"] = stage
        self.document.update(values)
        self.document["updated_at"] = time.time()
        self.document["elapsed_seconds"] = round(
            now_monotonic - self.monotonic_started, 3
        )
        self.document["stage_durations_seconds"] = {
            key: round(value, 3)
            for key, value in self.stage_durations.items()
        }
        self.document["current_stage_elapsed_seconds"] = round(
            now_monotonic - self.stage_started, 3
        )
        self.write()

    def write(self) -> None:
        atomic_json(self.path, self.document)


def checked_run(command: list[str], *, env: dict[str, str], cwd: Path, log: Path) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as output:
        process = subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    if process.returncode:
        raise RuntimeError(f"command failed ({process.returncode}); see {log}: {' '.join(command)}")


def vcs_environment() -> dict[str, str]:
    env = os.environ.copy()
    env["VCS_HOME"] = str(VCS_HOME)
    env["VCS_ARCH_OVERRIDE"] = "linux"
    env["VCS_TARGET_ARCH"] = "amd64"
    env["LM_LICENSE_FILE"] = "27000@mtw-virtual-machine"
    env["PATH"] = f"{VCS_HOME / 'bin'}:{env.get('PATH', '')}"
    return env


def ensure_generator(cache: Path, riscv_dv: Path, helper_dir: Path, status: Status) -> Path:
    generator = cache / "vcs_multi_harts" / "vcs_simv"
    lock_path = cache / "generator.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w", encoding="ascii") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if generator.is_file():
            return generator
        status.update("BUILD_GENERATOR", message="compiling cached riscv-dv VCS generator")
        output = generator.parent
        output.mkdir(parents=True, exist_ok=True)
        command = [
            "python3", str(riscv_dv / "run.py"),
            "--custom_target", str(riscv_dv / "target" / "multi_harts"),
            "--testlist", str(helper_dir / "automation_testlist.yaml"),
            "--test", "eh2_automation",
            "--simulator", "vcs",
            "--steps", "gen",
            "--co",
            "--output", str(output),
        ]
        checked_run(command, env=vcs_environment(), cwd=riscv_dv, log=output / "compile.log")
        if not generator.is_file():
            raise RuntimeError("riscv-dv VCS generator compile completed without vcs_simv")
    return generator


def run_generator_worker(
    worker_id: int,
    generator: Path,
    run_dir: Path,
    first_index: int,
    count: int,
    chunk_instructions: int,
    seed: int,
    cancel_path: Path,
) -> None:
    if count <= 0:
        return
    generated = run_dir / "riscvdv"
    generated.mkdir(parents=True, exist_ok=True)
    command = [
        str(generator),
        f"+ntb_random_seed={seed}",
        "+UVM_TESTNAME=riscv_instr_base_test",
        "+UVM_VERBOSITY=UVM_LOW",
        "+UVM_NO_RELNOTES",
        f"+num_of_tests={count}",
        f"+start_idx={first_index}",
        f"+asm_file_name={generated / 'rdv'}",
        f"+instr_cnt={chunk_instructions}",
        "+num_of_sub_program=0",
        "+no_branch_jump=1",
        "+no_load_store=0",
        "+enable_unaligned_load_store=0",
        "+directed_instr_0=riscv_load_store_rand_instr_stream,4",
        "+directed_instr_1=riscv_amo_instr_stream,2",
        "+directed_instr_2=riscv_lr_sc_instr_stream,2",
        "+no_csr_instr=1",
        "+no_fence=1",
        "+boot_mode=m",
        "-l", str(run_dir / f"generator_worker_{worker_id}.log"),
    ]
    env = vcs_environment()
    with (run_dir / f"generator_worker_{worker_id}.stdout.log").open("wb") as output:
        process = subprocess.Popen(command, cwd=run_dir, env=env, stdout=output, stderr=subprocess.STDOUT)
        while True:
            code = process.poll()
            if code is not None:
                if code:
                    raise RuntimeError(f"riscv-dv worker {worker_id} failed with exit code {code}")
                return
            if cancel_path.exists():
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                raise RuntimeError("run cancelled")
            time.sleep(1)


def replace_word(text: str, old: str, new: str) -> str:
    return re.sub(rf"(?<![\w.$]){re.escape(old)}(?![\w.$])", new, text)


def split_atomic_page(text: str, prefix: str) -> str:
    """Give each hart a private copy of riscv-dv's shared amo_0 page.

    A shared page makes two-hart AMO return values depend on simulator/core
    scheduling.  Private pages retain random atomic instruction coverage while
    making the FPGA-versus-Spike architectural comparison deterministic.
    """

    h0 = text.find("h0_main:")
    h1 = text.find("h1_main:")
    data = text.find(".section .h0_region_0", h1)
    if min(h0, h1, data) < 0 or not h0 < h1 < data:
        raise RuntimeError("cannot split riscv-dv atomic page by hart")
    h0_symbol = f"{prefix}h0_amo_0"
    h1_symbol = f"{prefix}h1_amo_0"
    text = (
        text[:h0]
        + replace_word(text[h0:h1], "amo_0", h0_symbol)
        + replace_word(text[h1:data], "amo_0", h1_symbol)
        + text[data:]
    )

    block_pattern = re.compile(
        r"^\.section \.amo_0,[^\n]*\namo_0:\n(?P<body>.*?)(?=^\.section )",
        re.MULTILINE | re.DOTALL,
    )
    match = block_pattern.search(text)
    if match is None:
        raise RuntimeError("cannot locate riscv-dv amo_0 data page")
    body = match.group("body")
    replacement = (
        f'.section .eh2_amo_h0_{prefix},"aw",@progbits;\n'
        f"{h0_symbol}:\n{body}"
        f'.section .eh2_amo_h1_{prefix},"aw",@progbits;\n'
        f"{h1_symbol}:\n{body}"
    )
    return text[:match.start()] + replacement + text[match.end():]


def patch_chunk(source: Path, target: Path, index: int, chunks: int) -> None:
    text = source.read_text(encoding="utf-8", errors="strict")
    prefix = f"eh2c{index:04d}_"
    next_h0 = f"eh2c{index + 1:04d}_h0_main" if index + 1 < chunks else "eh2_h0_tail"
    next_h1 = f"eh2c{index + 1:04d}_h1_main" if index + 1 < chunks else "eh2_h1_tail"

    h0 = text.find("h0_main:")
    h1 = text.find("h1_main:")
    if h0 < 0 or h1 < 0 or h1 <= h0:
        raise RuntimeError(f"cannot locate dual-hart main labels in {source}")

    tail_pattern = re.compile(
        r"(?P<indent>^[ \t]*)la\s+x(?P<jumpreg>\d+),\s*test_done\s*\n"
        r"(?P=indent)jalr\s+x0,\s*x(?P=jumpreg),\s*0",
        re.MULTILINE,
    )
    h0_match = tail_pattern.search(text, h0, h1)
    h1_match = tail_pattern.search(text, h1)
    if h0_match is None or h1_match is None:
        raise RuntimeError(f"cannot locate main-program tails in {source}")

    def tail(next_label: str, match: re.Match[str]) -> str:
        indent = match.group("indent")
        register = match.group("jumpreg")
        return f"{indent}la x{register}, {next_label}\n{indent}jalr x0, x{register}, 0"

    text = text[:h1_match.start()] + tail(next_h1, h1_match) + text[h1_match.end():]
    text = text[:h0_match.start()] + tail(next_h0, h0_match) + text[h0_match.end():]
    text = split_atomic_page(text, prefix)

    globals_found = set(GLOBAL_RE.findall(text))
    for symbol in sorted(globals_found, key=len, reverse=True):
        text = replace_word(text, symbol, prefix + symbol)
    text = replace_word(text, "h0_main", prefix + "h0_main")
    text = replace_word(text, "h1_main", prefix + "h1_main")
    text = (
        f".globl {prefix}h0_main\n.globl {prefix}h1_main\n"
        + text
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8", newline="\n")


def compile_chunk(
    index: int,
    chunks: int,
    run_dir: Path,
    riscv_dv: Path,
    cancel_path: Path,
) -> Path:
    if cancel_path.exists():
        raise RuntimeError("run cancelled")
    source = run_dir / "riscvdv" / f"rdv_{index}.S"
    transformed = run_dir / "chunks" / f"chunk_{index:04d}.S"
    obj = run_dir / "objects" / f"chunk_{index:04d}.o"
    if not source.is_file():
        raise RuntimeError(f"missing generated chunk {source}")
    patch_chunk(source, transformed, index, chunks)
    obj.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "/usr/bin/clang", "--target=riscv32-unknown-elf",
        "-march=rv32imac", "-mabi=ilp32", "-mcmodel=medany", "-mno-relax",
        "-I", str(riscv_dv / "user_extension"),
        "-c", str(transformed), "-o", str(obj),
    ]
    checked_run(command, env=os.environ.copy(), cwd=run_dir, log=run_dir / "compile_logs" / f"chunk_{index:04d}.log")
    return obj


def harness_source(spike: bool) -> str:
    private_instruction = "nop" if spike else "csrw 0x7fc, t6"
    h0_stop = "nop" if spike else "sw t5, 0(t4)"
    h1_stop = "nop" if spike else "sw t5, 0(t4)"
    # Spike's boot ROM enters the payload with a0/a1 holding platform values,
    # while EH2 starts at RESET_VECTOR with a different implementation-defined
    # GPR state. The trace below RESET_VECTOR is intentionally not compared, so
    # normalize every GPR observable by the random body here. sp is assigned a
    # hart-private deterministic value immediately afterwards.
    clear_gprs = "\n".join(
        f"  li x{register}, 0"
        for register in range(1, 32)
        if register != 2
    )
    if spike:
        post = r"""
.section .text.eh2_post,"ax",@progbits
eh2_h0_post:
  la t0, eh2_spike_h0_done
  li t1, 1
  sw t1, 0(t0)
  la t0, eh2_spike_h1_done
1: lw t2, 0(t0)
  beqz t2, 1b
  j eh2_spike_exit
eh2_h1_post:
  la t0, eh2_spike_h1_done
  li t1, 1
  sw t1, 0(t0)
2: wfi
  j 2b
eh2_spike_exit:
  la t0, tohost
  li t1, 1
  sw t1, 0(t0)
3: wfi
  j 3b
"""
    else:
        post = r"""
.section .text.eh2_post,"ax",@progbits
eh2_h0_post:
1: wfi
  j 1b
eh2_h1_post:
2: wfi
  j 2b
"""
    return f"""
.option push
.option norvc
.section .text.eh2_start,"ax",@progbits
.globl _start
_start:
  csrr s0, mhartid
  bnez s0, eh2_h1_delay
  # The Ethernet image writes DDR0, not EH2's internal DCCM.  Hart0 clears
  # every private AMO page before releasing hart1 so repeated board rounds
  # and Spike both begin with identical atomic memory.
  la t0, __amo_start
  la t1, __amo_end
eh2_clear_amo:
  bgeu t0, t1, eh2_clear_amo_done
  sw zero, 0(t0)
  addi t0, t0, 4
  j eh2_clear_amo
eh2_clear_amo_done:
  li t6, 2
.globl eh2_hart_start_patch
eh2_hart_start_patch:
  {private_instruction}
  j eh2_dispatch
eh2_h1_delay:
  # Spike starts both harts immediately, whereas EH2 releases hart1 through
  # CSR 0x7fc.  A fixed-count delay preserves the same hart1 instruction
  # trace in both environments and comfortably covers hart0's DCCM clear.
  li t0, 256
eh2_h1_delay_loop:
  addi t0, t0, -1
  bnez t0, eh2_h1_delay_loop
eh2_dispatch:
  csrr t0, mhartid
  beqz t0, eh2_h0_prelude
  j eh2_h1_prelude

.section .text.eh2_prelude,"ax",@progbits
eh2_h0_prelude:
{clear_gprs}
  la sp, eh2_h0_stack_end
  j eh2c0000_h0_main
eh2_h1_prelude:
{clear_gprs}
  la sp, eh2_h1_stack_end
  j eh2c0000_h1_main

.section .text.eh2_tail,"ax",@progbits
.globl eh2_h0_tail
eh2_h0_tail:
  li t4, 0xd0580000
  li t5, 0x00320525
.globl eh2_h0_stop_patch
eh2_h0_stop_patch:
  {h0_stop}
  # EH2 can retire younger instructions while this marker store is still in
  # the LSU/AXI write path.  Drain the store before the parking jump so the
  # AXI-side capture stop is asserted before any post-marker instruction can
  # enter the Info stream.
  fence rw, rw
  j eh2_h0_post
.globl eh2_h1_tail
eh2_h1_tail:
  li t4, 0xd0580000
  li t5, 0x00320525
.globl eh2_h1_stop_patch
eh2_h1_stop_patch:
  {h1_stop}
  fence rw, rw
  j eh2_h1_post
{post}
.section .data,"aw",@progbits
.balign 64
eh2_spike_h0_done: .word 0
eh2_spike_h1_done: .word 0
.space 4096
eh2_h0_stack_end:
.space 4096
eh2_h1_stack_end:
.section .tohost,"aw",@progbits
.balign 64
.globl tohost
tohost: .dword 0
.globl fromhost
fromhost: .dword 0
.option pop
"""


def symbol_table(elf: Path) -> dict[str, int]:
    result = subprocess.run(["/usr/bin/readelf", "-sW", str(elf)], check=True, capture_output=True, text=True)
    symbols: dict[str, int] = {}
    for line in result.stdout.splitlines():
        columns = line.split()
        if len(columns) >= 8 and re.fullmatch(r"[0-9a-fA-F]{8,16}", columns[1]):
            symbols[columns[7]] = int(columns[1], 16)
    return symbols


def link_images(run_dir: Path, helper_dir: Path, objects: list[Path]) -> dict[str, Any]:
    hardware_source = run_dir / "hardware_harness.S"
    spike_source = run_dir / "spike_harness.S"
    hardware_source.write_text(harness_source(False), encoding="utf-8", newline="\n")
    spike_source.write_text(harness_source(True), encoding="utf-8", newline="\n")
    harness_objects: dict[str, Path] = {}
    for name, source in (("hardware", hardware_source), ("spike", spike_source)):
        target = run_dir / f"{name}_harness.o"
        checked_run([
            "/usr/bin/clang", "--target=riscv32-unknown-elf", "-march=rv32imac",
            "-mabi=ilp32", "-mcmodel=medany", "-mno-relax",
            "-c", str(source), "-o", str(target),
        ], env=os.environ.copy(), cwd=run_dir, log=run_dir / f"compile_{name}_harness.log")
        harness_objects[name] = target

    elfs: dict[str, Path] = {}
    for name in ("hardware", "spike"):
        elf = run_dir / f"program_{name}.elf"
        command = [
            "/usr/bin/clang", "--target=riscv32-unknown-elf", "-march=rv32imac",
            "-mabi=ilp32", "-mno-relax", "-nostdlib", "-fuse-ld=lld",
            f"-Wl,-T,{helper_dir / 'link.ld'}", "-Wl,--build-id=none", "-Wl,--no-relax",
            str(harness_objects[name]), *map(str, objects), "-o", str(elf),
        ]
        checked_run(command, env=os.environ.copy(), cwd=run_dir, log=run_dir / f"link_{name}.log")
        elfs[name] = elf

    hardware_symbols = symbol_table(elfs["hardware"])
    spike_symbols = symbol_table(elfs["spike"])
    layout_names = (
        "__program_start", "__program_end", "__data_start", "__data_end",
        "__amo_start", "__amo_end", "__amo_h0_start", "__amo_h0_end",
        "__amo_h1_start", "__amo_h1_end",
    )
    missing_layout = [name for name in layout_names if name not in hardware_symbols]
    if missing_layout:
        raise RuntimeError(f"linker did not export memory-layout symbols: {missing_layout}")
    missing_spike_layout = [name for name in layout_names if name not in spike_symbols]
    if missing_spike_layout:
        raise RuntimeError(f"Spike linker did not export memory-layout symbols: {missing_spike_layout}")
    # The Spike-only postamble coordinates both harts and writes tohost, so its
    # program end is intentionally later than the board image.  The shared
    # start address and every writable-data address must still be identical.
    for name in (
        "__program_start", "__data_start", "__data_end",
        "__amo_start", "__amo_end", "__amo_h0_start", "__amo_h0_end",
        "__amo_h1_start", "__amo_h1_end",
    ):
        if hardware_symbols[name] != spike_symbols.get(name):
            raise RuntimeError(f"hardware/Spike memory-layout mismatch for {name}")
    program_start = hardware_symbols["__program_start"]
    program_end = hardware_symbols["__program_end"]
    spike_program_end = spike_symbols["__program_end"]
    data_start = hardware_symbols["__data_start"]
    data_end = hardware_symbols["__data_end"]
    amo_start = hardware_symbols["__amo_start"]
    amo_end = hardware_symbols["__amo_end"]
    amo_h0_start = hardware_symbols["__amo_h0_start"]
    amo_h0_end = hardware_symbols["__amo_h0_end"]
    amo_h1_start = hardware_symbols["__amo_h1_start"]
    amo_h1_end = hardware_symbols["__amo_h1_end"]
    if not (program_start == RESET_VECTOR < program_end <= PROGRAM_LIMIT):
        raise RuntimeError(
            f"program range is invalid: 0x{program_start:08x}..0x{program_end:08x}"
        )
    if not (program_start < spike_program_end <= PROGRAM_LIMIT):
        raise RuntimeError(
            f"Spike program range is invalid: 0x{program_start:08x}..0x{spike_program_end:08x}"
        )
    if not (DATA_BASE <= data_start <= data_end <= DATA_LIMIT):
        raise RuntimeError(
            f"LSU data range is invalid: 0x{data_start:08x}..0x{data_end:08x}"
        )
    if not (LSU_BASE <= data_start <= data_end <= LSU_LIMIT):
        raise RuntimeError("ordinary LSU data leaves 0xa0000000..0xffffffff")
    if not (
        AMO_BASE <= amo_start <= amo_h0_start <= amo_h0_end
        <= amo_h1_start <= amo_h1_end <= amo_end <= AMO_LIMIT
    ):
        raise RuntimeError(
            "atomic LSU data is outside DCCM or hart pages overlap: "
            f"0x{amo_start:08x}..0x{amo_end:08x}"
        )

    program_bin = run_dir / "program.bin"
    checked_run([
        "/usr/bin/objcopy", "-I", "elf32-little", "-O", "binary",
        str(elfs["hardware"]), str(program_bin),
    ], env=os.environ.copy(), cwd=run_dir, log=run_dir / "objcopy.log")
    program_size = program_bin.stat().st_size
    expected_program_size = program_end - program_start
    if program_size > expected_program_size:
        raise RuntimeError(
            "flat program image contains low-address data or an unexpected gap: "
            f"binary={program_size}, program_window={expected_program_size}"
        )

    patch_names = ("eh2_hart_start_patch", "eh2_h0_stop_patch", "eh2_h1_stop_patch")
    patches = []
    binary = program_bin.read_bytes()
    for name in patch_names:
        hardware_pc = hardware_symbols[name]
        spike_pc = spike_symbols[name]
        if hardware_pc != spike_pc:
            raise RuntimeError(f"hardware/Spike patch PC mismatch for {name}")
        offset = hardware_pc - RESET_VECTOR
        if offset < 0 or offset + 4 > len(binary):
            raise RuntimeError(f"patch symbol {name} lies outside program binary")
        patches.append({
            "name": name,
            "pc": hardware_pc,
            "hardware_instruction": int.from_bytes(binary[offset:offset + 4], "little"),
        })
    return {
        "hardware_elf": elfs["hardware"].name,
        "spike_elf": elfs["spike"].name,
        "program_bin": program_bin.name,
        "program_bytes": program_size,
        "program_sha256": sha256_file(program_bin),
        "memory_layout": {
            "program_start": program_start,
            "program_end_exclusive": program_end,
            "spike_program_end_exclusive": spike_program_end,
            "program_limit_exclusive": PROGRAM_LIMIT,
            "data_start": data_start,
            "data_end_exclusive": data_end,
            "data_limit_exclusive": DATA_LIMIT,
            "lsu_base": LSU_BASE,
            "lsu_limit_exclusive": LSU_LIMIT,
            "amo_start": amo_start,
            "amo_end_exclusive": amo_end,
            "amo_limit_exclusive": AMO_LIMIT,
            "amo_hart0_start": amo_h0_start,
            "amo_hart0_end_exclusive": amo_h0_end,
            "amo_hart1_start": amo_h1_start,
            "amo_hart1_end_exclusive": amo_h1_end,
            "data_sections_noload": True,
            "ranges_overlap": False,
        },
        "patches": patches,
    }


def run_spike(
    work_dir: Path,
    shared_run_dir: Path,
    spike_path: Path,
    cancel_path: Path,
    status: Status,
    manifest: dict[str, Any],
) -> None:
    elf = work_dir / "program_spike.elf"
    raw_log = shared_run_dir / "spike.log"
    stdout_log = shared_run_dir / "spike_stdout.log"
    layout = manifest["memory_layout"]
    data_start = int(layout["data_start"])
    data_bytes = max(
        4096,
        ((int(layout["data_end_exclusive"]) - data_start) + 4095) & ~4095,
    ) + 4096
    amo_start = int(layout["amo_start"])
    # Map exactly the hardware DCCM aperture.  An accidental AMO/LR/SC address
    # outside [AMO_BASE, AMO_LIMIT) then traps in Spike instead of being hidden
    # by a larger reference-memory region.
    if amo_start != AMO_BASE:
        raise RuntimeError(
            f"atomic region does not start at DCCM base: 0x{amo_start:08x}"
        )
    amo_bytes = AMO_LIMIT - AMO_BASE
    high_used = max(
        int(layout["program_end_exclusive"]),
        int(layout["spike_program_end_exclusive"]),
    ) - int(layout["program_start"])
    high_bytes = max(4096, (high_used + 4095) & ~4095)
    memory_regions = (
        f"0x{RESET_VECTOR:x}:0x{high_bytes:x},"
        f"0x{data_start:x}:0x{data_bytes:x},"
        f"0x{amo_start:x}:0x{amo_bytes:x}"
    )
    command = [
        str(spike_path), "-p2", "--isa=RV32IMAC", "--log-commits",
        f"-m{memory_regions}", str(elf),
    ]
    status.update(
        "SPIKE_RUNNING",
        message="program ready; Spike commit trace running on VM-local storage",
        program_ready=True,
        spike_output_mode="vm_local_then_bulk_copy",
    )
    atomic_commits = 0
    # Spike emits one small stderr write per commit.  Writing those calls
    # directly to VMware HGFS turns a sub-second reference run into ~26 s.
    # Capture on the VM's local filesystem, validate it, then perform one
    # sequential copy to the shared run directory for Windows comparison.
    with tempfile.TemporaryDirectory(prefix="eh2logcomp_spike_", dir="/tmp") as temporary:
        local_stdout = Path(temporary) / "spike_stdout.log"
        local_raw = Path(temporary) / "spike.log"
        code = -1
        try:
            with local_stdout.open("wb") as stdout, local_raw.open("wb") as stderr:
                process = subprocess.Popen(
                    command, cwd=work_dir, stdout=stdout, stderr=stderr
                )
                last_progress_update = time.monotonic()
                while True:
                    code = process.poll()
                    if code is not None:
                        break
                    if cancel_path.exists():
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                        code = process.returncode
                        raise RuntimeError("run cancelled")
                    now = time.monotonic()
                    if now - last_progress_update >= 0.5:
                        status.update(
                            "SPIKE_RUNNING",
                            spike_log_bytes=(
                                local_raw.stat().st_size if local_raw.exists() else 0
                            ),
                        )
                        last_progress_update = now
                    time.sleep(0.05)
        finally:
            if local_stdout.exists():
                publish_file(local_stdout, stdout_log)
            if local_raw.exists():
                publish_file(local_raw, raw_log)
        if code:
            raise RuntimeError(f"Spike failed with exit code {code}")
        atomic_commits = validate_atomic_trace(local_raw, manifest)
    status.update(
        "SPIKE_DONE",
        message="Spike commit trace complete",
        program_ready=True,
        spike_done=True,
        spike_log_bytes=raw_log.stat().st_size,
        spike_log_sha256=sha256_file(raw_log),
        atomic_commit_count=atomic_commits,
        atomic_address_check="PASS",
    )


def validate_atomic_trace(spike_log: Path, manifest: dict[str, Any]) -> int:
    """Require every executed A-extension access to stay in its hart DCCM page."""

    layout = manifest["memory_layout"]
    pages = {
        0: (
            int(layout["amo_hart0_start"]),
            int(layout["amo_hart0_end_exclusive"]),
        ),
        1: (
            int(layout["amo_hart1_start"]),
            int(layout["amo_hart1_end_exclusive"]),
        ),
    }
    count = 0
    with spike_log.open(
        "r", encoding="utf-8", errors="replace", buffering=8 * 1024 * 1024
    ) as source:
        for line_number, line in enumerate(source, 1):
            commit = SPIKE_COMMIT_RE.match(line)
            if commit is None:
                continue
            instruction = int(commit["insn"], 16)
            if (instruction & 0x7F) != 0x2F:
                continue
            hart = int(commit["hart"])
            if hart not in pages:
                raise RuntimeError(
                    f"atomic commit uses unexpected hart {hart} at Spike line {line_number}"
                )
            addresses = [
                int(value, 16) for value in SPIKE_MEM_RE.findall(commit["effects"])
            ]
            if not addresses:
                raise RuntimeError(
                    f"atomic commit has no auditable memory address at Spike line {line_number}"
                )
            page_start, page_end = pages[hart]
            for address in addresses:
                if address & 3:
                    raise RuntimeError(
                        f"unaligned atomic address 0x{address:08x} at Spike line {line_number}"
                    )
                if not (
                    AMO_BASE <= address and address + 4 <= AMO_LIMIT
                    and page_start <= address and address + 4 <= page_end
                ):
                    raise RuntimeError(
                        "riscv-dv atomic address leaves the hart-private DCCM page: "
                        f"hart={hart} address=0x{address:08x} line={line_number}"
                    )
            count += 1
    if count == 0:
        raise RuntimeError("riscv-dv program executed no auditable AMO/LR/SC instruction")
    return count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--instructions-per-hart", type=int, default=10_000)
    parser.add_argument("--chunk-instructions", type=int, default=10_000)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--riscv-dv", type=Path, default=DEFAULT_RISCV_DV)
    parser.add_argument("--spike", type=Path, default=Path("/usr/bin/spike"))
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    args = parser.parse_args()

    helper_dir = Path(__file__).resolve().parent
    run_dir = args.run_dir.resolve()
    shared_runs = (SHARED_ROOT / "runs").resolve()
    if shared_runs not in run_dir.parents:
        raise SystemExit(f"run directory must be below {shared_runs}")
    if args.instructions_per_hart <= 0 or args.chunk_instructions <= 0:
        raise SystemExit("instruction counts must be positive")
    chunks = math.ceil(args.instructions_per_hart / args.chunk_instructions)
    if chunks <= 0 or chunks > 1000:
        raise SystemExit("chunk count outside safe range 1..1000")
    if args.instructions_per_hart % args.chunk_instructions:
        raise SystemExit("instructions-per-hart must be divisible by chunk-instructions")
    workers = max(1, min(args.workers, 4, chunks))
    run_dir.mkdir(parents=True, exist_ok=True)
    cancel_path = run_dir / "cancel.request"
    status = Status(run_dir, args.seed, args.instructions_per_hart, chunks)

    try:
        # riscv-dv/VCS performs many small writes: generated assembly, worker
        # logs, transformed sources, objects and linker logs.  HGFS makes
        # those writes disproportionately slow.  Keep the whole build on the
        # VM-local filesystem, exactly as the Spike trace already is, and
        # publish only artifacts the Windows WebUI actually consumes.
        with tempfile.TemporaryDirectory(
            prefix="eh2logcomp_riscvdv_", dir="/tmp"
        ) as temporary:
            work_dir = Path(temporary)
            try:
                generator = ensure_generator(
                    args.cache, args.riscv_dv.resolve(), helper_dir, status
                )
                status.update(
                    "GENERATING",
                    message=(
                        f"generating {chunks} static dual-hart IMAC chunks "
                        f"with {workers} workers on VM-local storage"
                    ),
                    generator_output_mode="vm_local_then_publish",
                )
                group = math.ceil(chunks / workers)
                futures = []
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    for worker in range(workers):
                        first = worker * group
                        count = max(0, min(group, chunks - first))
                        futures.append(pool.submit(
                            run_generator_worker, worker, generator, work_dir,
                            first, count, args.chunk_instructions,
                            args.seed + worker * 1_000_003, cancel_path,
                        ))
                    completed = 0
                    for future in as_completed(futures):
                        future.result()
                        completed += 1
                        generated_count = len(
                            list((work_dir / "riscvdv").glob("rdv_*.S"))
                        )
                        status.update(
                            "GENERATING", generated_chunks=generated_count,
                            message=(
                                f"riscv-dv workers complete "
                                f"{completed}/{workers}"
                            ),
                        )
                generated_count = len(list((work_dir / "riscvdv").glob("rdv_*.S")))
                if generated_count != chunks:
                    raise RuntimeError(
                        f"generated {generated_count} chunks, expected {chunks}"
                    )

                status.update(
                    "COMPILING", generated_chunks=chunks,
                    message="patching and compiling static chunks on VM-local storage",
                )
                objects: list[Path | None] = [None] * chunks
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    future_map = {
                        pool.submit(
                            compile_chunk, index, chunks, work_dir,
                            args.riscv_dv.resolve(), cancel_path,
                        ): index
                        for index in range(chunks)
                    }
                    completed = 0
                    for future in as_completed(future_map):
                        index = future_map[future]
                        objects[index] = future.result()
                        completed += 1
                        if completed == chunks or completed % max(1, chunks // 20) == 0:
                            status.update(
                                "COMPILING", compiled_chunks=completed,
                                message=f"compiled chunks {completed}/{chunks}",
                            )

                status.update(
                    "LINKING", generated_chunks=chunks, compiled_chunks=chunks,
                    message="linking hardware and Spike images on VM-local storage",
                )
                manifest = {
                    "format_version": 1,
                    "seed": args.seed,
                    "isa": "RV32IMAC",
                    "harts": 2,
                    "reset_vector": RESET_VECTOR,
                    "target_instructions_per_hart": args.instructions_per_hart,
                    "chunk_instructions": args.chunk_instructions,
                    "chunks": chunks,
                    "generator_workers": workers,
                    "artifact_storage": "vm_local_then_publish",
                    "riscv_dv_root": str(args.riscv_dv.resolve()),
                    "riscv_dv_commit": subprocess.run(
                        ["git", "-C", str(args.riscv_dv.resolve()), "rev-parse", "HEAD"],
                        check=True, capture_output=True, text=True,
                    ).stdout.strip(),
                    **link_images(
                        work_dir, helper_dir,
                        [item for item in objects if item is not None],
                    ),
                }
                # Publish the binary and manifest before raising PROGRAM_READY;
                # the Windows sender consumes only these two shared artifacts.
                publish_file(work_dir / "program.bin", run_dir / "program.bin")
                atomic_json(run_dir / "manifest.json", manifest)
                status.update(
                    "PROGRAM_READY",
                    message="program image published; starting Spike",
                    program_ready=True,
                    manifest=manifest,
                )
                run_spike(
                    work_dir, run_dir, args.spike.resolve(), cancel_path,
                    status, manifest,
                )
            except Exception:
                # PASS rounds discard VM-local build files at the end of this
                # context.  A failing/cancelled VM run instead copies them
                # once to the shared error directory for vmwrong diagnosis.
                archive_failed_work_dir(work_dir, run_dir)
                raise
    except Exception as exc:
        status.update("FAILED", failed=True, message=str(exc))
        raise


if __name__ == "__main__":
    main()
