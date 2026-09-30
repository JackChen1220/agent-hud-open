#!/usr/bin/env python3
"""Measure a macOS process over a window, rather than reporting lifetime CPU averages."""
import argparse
import ctypes
import json
import math
import struct
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--interval", type=float, default=5)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This reader requires macOS libproc")
    if args.pid <= 0 or not all(map(math.isfinite, (args.interval, args.duration))) or not 0 < args.interval <= args.duration:
        parser.error("Use a positive PID and 0 < interval <= duration")

    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    read_usage = lib.proc_pid_rusage
    read_usage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    read_usage.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)

    def cpu_time():
        if read_usage(args.pid, 2, ctypes.byref(buffer)) != 0:
            raise OSError(ctypes.get_errno(), "Cannot read the process; it may have exited")
        # rusage_info_v2 begins with a 16-byte UUID, then user/system CPU time in nanoseconds.
        return sum(struct.unpack_from("QQ", buffer.raw, 16)) / 1e9

    try:
        started = stamp = time.monotonic()
        first = previous = cpu_time()
        samples = []
        while stamp - started < args.duration:
            time.sleep(min(args.interval, args.duration - (stamp - started)))
            current, now = cpu_time(), time.monotonic()
            samples.append({"seconds": round(now - stamp, 3), "cpu_percent": round((current - previous) / (now - stamp) * 100, 3)})
            previous, stamp = current, now
        print(json.dumps({"pid": args.pid, "seconds": round(stamp - started, 3),
                          "mean_cpu_percent": round((previous - first) / (stamp - started) * 100, 3),
                          "max_sample_cpu_percent": max(s["cpu_percent"] for s in samples), "samples": samples}, indent=2))
    except OSError as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
