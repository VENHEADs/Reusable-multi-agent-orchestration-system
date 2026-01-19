#!/usr/bin/env python3
from __future__ import annotations

import sys
from datetime import datetime, timezone


def main() -> int:
    for line in sys.stdin:
        ts = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
        sys.stdout.write(f"{ts} {line}")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
