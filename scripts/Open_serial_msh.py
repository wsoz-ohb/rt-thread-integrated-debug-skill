from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import serial
from serial.tools import list_ports


def list_serial_ports() -> list[dict]:
    ports = []
    for port in list_ports.comports():
        ports.append(
            {
                "device": port.device,
                "name": port.name,
                "description": port.description,
                "hwid": port.hwid,
                "vid": port.vid,
                "pid": port.pid,
                "serial_number": port.serial_number,
                "manufacturer": port.manufacturer,
                "product": port.product,
                "interface": port.interface,
            }
        )
    return ports


def decode_bytes(data: bytes) -> str:
    if not data:
        return ""
    return data.decode("utf-8", errors="replace")


def read_for(ser: serial.Serial, duration: float) -> str:
    deadline = time.monotonic() + max(duration, 0)
    chunks: list[str] = []
    while time.monotonic() < deadline:
        waiting = ser.in_waiting
        if waiting:
            chunks.append(decode_bytes(ser.read(waiting)))
        else:
            time.sleep(0.05)
    waiting = ser.in_waiting
    if waiting:
        chunks.append(decode_bytes(ser.read(waiting)))
    return "".join(chunks)


def normalize_command(command: str, newline: str) -> bytes:
    line_ending = {
        "crlf": "\r\n",
        "lf": "\n",
        "cr": "\r",
    }[newline]
    return (command + line_ending).encode("utf-8")


def analyze_log(text: str) -> dict:
    lower = text.lower()
    has_rtthread = "rt-thread" in lower or "rtthread" in lower
    has_msh = bool(re.search(r"msh\s*[>/]", text, re.IGNORECASE))
    has_assert = "assert" in lower
    has_hardfault = "hard fault" in lower or "hardfault" in lower
    has_reboot = any(token in lower for token in ("reboot", "reset", "restart"))
    has_error = any(token in lower for token in ("error", "fail", "failed", "fault", "panic"))
    return {
        "hasRtThreadBanner": has_rtthread,
        "hasMshPrompt": has_msh,
        "hasAssert": has_assert,
        "hasHardFault": has_hardfault,
        "hasRebootEvidence": has_reboot,
        "hasErrorKeyword": has_error,
    }


def write_log(path: str | None, text: str) -> str | None:
    if not path:
        return None
    resolved = Path(path).resolve()
    resolved.parent.mkdir(parents=True, exist_ok=True)
    resolved.write_text(text, encoding="utf-8")
    return str(resolved)


def remove_old_logs(directory: Path, pattern: str, keep: int) -> int:
    if keep < 0 or not directory.exists():
        return 0
    files = sorted(
        (path for path in directory.glob(pattern) if path.is_file()),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    deleted = 0
    for path in files[keep:]:
        try:
            path.unlink()
            deleted += 1
        except OSError:
            pass
    return deleted


def print_json(data: dict) -> None:
    print(json.dumps(data, ensure_ascii=True, indent=2))


def open_and_interact(args: argparse.Namespace) -> dict:
    sent_commands: list[str] = []
    command_outputs: list[dict] = []
    all_text_parts: list[str] = []

    with serial.Serial(
        port=args.port,
        baudrate=args.baudrate,
        bytesize=args.bytesize,
        parity=args.parity,
        stopbits=args.stopbits,
        timeout=args.timeout,
        write_timeout=args.timeout,
        rtscts=args.rtscts,
        dsrdtr=args.dsrdtr,
    ) as ser:
        if args.dtr is not None:
            ser.dtr = args.dtr
        if args.rts is not None:
            ser.rts = args.rts

        time.sleep(args.open_delay)
        if args.flush_input:
            ser.reset_input_buffer()

        initial_text = read_for(ser, args.read_seconds)
        all_text_parts.append(initial_text)

        for command in args.command:
            payload = normalize_command(command, args.newline)
            ser.write(payload)
            ser.flush()
            sent_commands.append(command)
            text = read_for(ser, args.after_command_seconds)
            command_outputs.append({"command": command, "output": text})
            all_text_parts.append(text)

    combined_text = "".join(all_text_parts)
    log_path = write_log(args.log_path, combined_text)
    old_log_deleted_count = 0
    if log_path:
        old_log_deleted_count = remove_old_logs(Path(log_path).parent, "rt-thread-serial-*.log", args.keep_logs)
    analysis = analyze_log(combined_text)

    return {
        "port": args.port,
        "baudrate": args.baudrate,
        "bytesize": args.bytesize,
        "parity": args.parity,
        "stopbits": args.stopbits,
        "opened": True,
        "sentCommands": sent_commands,
        "commandOutputs": command_outputs,
        "analysis": analysis,
        "keepLogs": args.keep_logs,
        "oldLogDeletedCount": old_log_deleted_count,
        "logPath": log_path,
        "logPreview": combined_text[-args.preview_chars :] if args.preview_chars > 0 else "",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Open a serial terminal for RT-Thread MSH/FinSH runtime verification.")
    parser.add_argument("--list", action="store_true", help="List available serial ports and exit.")
    parser.add_argument("--port", help="Serial port, such as COM3.")
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--bytesize", type=int, default=8)
    parser.add_argument("--parity", default="N", choices=["N", "E", "O", "M", "S"])
    parser.add_argument("--stopbits", type=float, default=1)
    parser.add_argument("--timeout", type=float, default=0.2)
    parser.add_argument("--open-delay", type=float, default=0.2)
    parser.add_argument("--read-seconds", type=float, default=3.0)
    parser.add_argument("--after-command-seconds", type=float, default=3.0)
    parser.add_argument("--command", action="append", default=[], help="Command to send to MSH/FinSH. Can be repeated.")
    parser.add_argument("--newline", choices=["crlf", "lf", "cr"], default="crlf")
    parser.add_argument("--log-path", default="")
    parser.add_argument("--keep-logs", type=int, default=10)
    parser.add_argument("--preview-chars", type=int, default=2000)
    parser.add_argument("--flush-input", action="store_true")
    parser.add_argument("--rtscts", action="store_true")
    parser.add_argument("--dsrdtr", action="store_true")
    parser.add_argument("--dtr", type=lambda x: x.lower() in {"1", "true", "yes", "on"}, default=None)
    parser.add_argument("--rts", type=lambda x: x.lower() in {"1", "true", "yes", "on"}, default=None)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.list:
        print_json({"ports": list_serial_ports()})
        return 0

    if not args.port:
        parser.error("--port is required unless --list is used.")

    try:
        result = open_and_interact(args)
        print_json(result)
        return 0
    except Exception as exc:
        print_json(
            {
                "port": args.port,
                "baudrate": args.baudrate,
                "opened": False,
                "error": str(exc),
                "availablePorts": list_serial_ports(),
            }
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
