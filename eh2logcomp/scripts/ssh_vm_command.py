#!/usr/bin/env python3
"""Run one command through the user's local Ubuntu VM SSH service."""

from __future__ import annotations

import argparse
import os
import shlex
import sys

import paramiko


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?")
    parser.add_argument("--host", default="192.168.88.128")
    parser.add_argument("--user", default="mtw")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--sudo",
        action="store_true",
        help="run the command through sudo, supplying VM_SSH_PASSWORD on stdin",
    )
    parser.add_argument("--upload", nargs=2, metavar=("LOCAL", "REMOTE"))
    parser.add_argument("--download", nargs=2, metavar=("REMOTE", "LOCAL"))
    args = parser.parse_args()
    action_count = sum(
        value is not None
        for value in (args.command, args.upload, args.download)
    )
    if action_count != 1:
        parser.error("specify exactly one command, --upload, or --download")
    if args.sudo and args.command is None:
        parser.error("--sudo is only valid with a command")

    password = os.environ.get("VM_SSH_PASSWORD")
    if not password:
        raise SystemExit("VM_SSH_PASSWORD is not set")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=args.host,
        username=args.user,
        password=password,
        timeout=args.timeout,
        auth_timeout=args.timeout,
        banner_timeout=args.timeout,
    )
    try:
        if args.upload:
            local, remote = args.upload
            try:
                with client.open_sftp() as sftp:
                    sftp.put(local, remote)
                status = 0
            except paramiko.SSHException:
                # Some of the EH2 servers accept ordinary SSH exec channels
                # but disable the SFTP subsystem.  Stream the file through an
                # SSH channel so the verification flow remains headless SSH.
                stdin, stdout, stderr = client.exec_command(
                    f"cat > {shlex.quote(remote)}", timeout=args.timeout
                )
                with open(local, "rb") as source:
                    while chunk := source.read(1024 * 1024):
                        stdin.channel.sendall(chunk)
                stdin.channel.shutdown_write()
                err = stderr.read()
                if err:
                    sys.stderr.buffer.write(err)
                status = stdout.channel.recv_exit_status()
        elif args.download:
            remote, local = args.download
            try:
                with client.open_sftp() as sftp:
                    sftp.get(remote, local)
                status = 0
            except paramiko.SSHException:
                _, stdout, stderr = client.exec_command(
                    f"cat {shlex.quote(remote)}", timeout=args.timeout
                )
                with open(local, "wb") as destination:
                    while chunk := stdout.channel.recv(1024 * 1024):
                        destination.write(chunk)
                err = stderr.read()
                if err:
                    sys.stderr.buffer.write(err)
                status = stdout.channel.recv_exit_status()
        else:
            remote_command = args.command
            if args.sudo:
                remote_command = f"sudo -S -p '' sh -c {shlex.quote(args.command)}"
            stdin, stdout, stderr = client.exec_command(
                remote_command, timeout=args.timeout
            )
            if args.sudo:
                stdin.write(password + "\n")
                stdin.flush()
                stdin.channel.shutdown_write()
            out = stdout.read()
            err = stderr.read()
            if out:
                sys.stdout.buffer.write(out)
            if err:
                sys.stderr.buffer.write(err)
            status = stdout.channel.recv_exit_status()
    finally:
        client.close()
    raise SystemExit(status)


if __name__ == "__main__":
    main()
