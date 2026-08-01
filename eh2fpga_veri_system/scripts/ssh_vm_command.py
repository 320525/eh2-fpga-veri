#!/usr/bin/env python3
"""Run one command through the user's local Ubuntu VM SSH service."""

from __future__ import annotations

import argparse
import os
import sys

import paramiko


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?")
    parser.add_argument("--host", default="192.168.88.128")
    parser.add_argument("--user", default="mtw")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--upload", nargs=2, metavar=("LOCAL", "REMOTE"))
    parser.add_argument("--download", nargs=2, metavar=("REMOTE", "LOCAL"))
    args = parser.parse_args()
    action_count = sum(
        value is not None
        for value in (args.command, args.upload, args.download)
    )
    if action_count != 1:
        parser.error("specify exactly one command, --upload, or --download")

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
            with client.open_sftp() as sftp:
                sftp.put(local, remote)
            status = 0
        elif args.download:
            remote, local = args.download
            with client.open_sftp() as sftp:
                sftp.get(remote, local)
            status = 0
        else:
            _, stdout, stderr = client.exec_command(
                args.command, timeout=args.timeout
            )
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
