#!/usr/bin/env python3
"""Bounded TCP listener scan for the user's local Ubuntu VM."""

from __future__ import annotations

import argparse
import asyncio


async def probe(host: str, port: int, timeout: float, gate: asyncio.Semaphore) -> int | None:
    async with gate:
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(host, port), timeout=timeout
            )
            writer.close()
            await writer.wait_closed()
            return port
        except (TimeoutError, ConnectionError, OSError):
            return None


async def scan(host: str, timeout: float, concurrency: int) -> list[int]:
    gate = asyncio.Semaphore(concurrency)
    tasks = [probe(host, port, timeout, gate) for port in range(1, 65536)]
    return sorted(port for port in await asyncio.gather(*tasks) if port is not None)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("--timeout", type=float, default=0.15)
    parser.add_argument("--concurrency", type=int, default=512)
    args = parser.parse_args()
    for port in asyncio.run(scan(args.host, args.timeout, args.concurrency)):
        print(port)


if __name__ == "__main__":
    main()
