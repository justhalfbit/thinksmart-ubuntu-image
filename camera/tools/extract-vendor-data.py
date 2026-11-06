#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Re-derive the S5KC505A data in camera/ from the device's own stock firmware.

Nothing from the stock firmware is committed except the numbers this script prints. Given
the vendor partition of your own full eMMC backup (README section A2), it

  * writes s5kc505a_regs.h: the init and mode register sequences from
    libmmcamera_s5kc505a.so (tables of {u16 addr, u16 value, u32 delay_ms});
  * prints the chip id, I2C address and power-up sequence from the same library;
  * prints the colour correction matrices in libchromatix_s5kc505a_default_preview_3a.so
    (s5kc505a.yaml uses the one at 0x4428).

Usage:
  # vendor partition of the backup: sectors 4069376..4855807 (sgdisk -p stock-full-emmc.bin)
  dd if=stock-full-emmc.bin of=vendor.img bs=512 skip=4069376 count=786432
  debugfs -R 'dump /lib/libmmcamera_s5kc505a.so libmmcamera_s5kc505a.so' vendor.img
  debugfs -R 'dump /lib/libchromatix_s5kc505a_default_preview_3a.so 3a.so' vendor.img
  camera/tools/extract-vendor-data.py libmmcamera_s5kc505a.so 3a.so > s5kc505a_regs.h
"""
import struct
import sys

import numpy as np

# The sensor library's .data section starts at file offset 0x3000 (readelf -S).
DATA_START = 0x3000
TABLES = [  # file offset, name in s5kc505a_regs.h
    (0x6E20, "init"),
    (0x3EEE4, "mode_2608x1960"),
    (0x42EF4, "mode_1304x980"),
    (0x46F04, "mode_1936x1096"),
    (0x4AF14, "mode_1296x736"),
    (0x4EF24, "mode_640x490"),
]


def table(lib, off):
    rows = []
    while True:
        addr, val, delay = struct.unpack_from("<HHI", lib, off + 8 * len(rows))
        if addr == 0 or delay >= 1000:
            return rows
        rows.append((addr, val, delay))


def regs_header(lib):
    out = [
        "/* SPDX-License-Identifier: GPL-2.0-only */",
        "/*",
        " * Register tables for the Samsung S5KC505A, extracted from the vendor",
        " * libmmcamera_s5kc505a.so shipped on the Lenovo ThinkSmart View (CD-18781Y)",
        " * by camera/tools/extract-vendor-data.py. Generated file - do not edit by hand.",
        " */",
        "#ifndef __S5KC505A_REGS_H",
        "#define __S5KC505A_REGS_H",
        "",
    ]
    for off, name in TABLES:
        rows = table(lib, off)
        label = "init" if name == "init" else name[5:]
        out.append(f"/* {label} ({len(rows)} writes, vendor offset {off:#x}) */")
        out.append(f"static const struct cci_reg_sequence s5kc505a_{name}_regs[] = {{")
        for addr, val, delay in rows:
            note = f" /* vendor delay {delay} ms, handled in code */" if delay else ""
            out.append(f"\t{{ CCI_REG8(0x{addr:04x}), 0x{val:02x} }},{note}")
        out.append("};\n")
    out.append("#endif")
    return "\n".join(out) + "\n"


def sensor_info(lib):
    # sensor_slave_info right after the name "s5kc505a" at the start of .data
    base = lib.index(b"s5kc505a\0", DATA_START)
    slave, = struct.unpack_from("<H", lib, base + 0x20)
    id_reg, chip_id = struct.unpack_from("<HH", lib, base + 0x30)
    print(f"# I2C address 0x{slave:02x} (8-bit) = 0x{slave >> 1:02x} (7-bit)", file=sys.stderr)
    print(f"# chip id register 0x{id_reg:04x} = 0x{chip_id:04x}", file=sys.stderr)
    # power_setting_t {type, seq, config, delay} x 4 bytes, from base + 0x38
    names = {0: "CLK", 1: "GPIO", 2: "VREG"}
    gpio = {0: "RESET", 1: "STANDBY", 4: "VANA", 5: "VDIG"}
    vreg = {0: "VDIG", 1: "VIO", 2: "VANA"}
    print("# power-up:", file=sys.stderr)
    for i in range(10):
        t, s, c, d = struct.unpack_from("<IIII", lib, base + 0x38 + 16 * i)
        what = {1: gpio.get(s, s), 2: vreg.get(s, s), 0: "MCLK"}.get(t, s)
        val = f"{c / 1e6:g} MHz" if t == 0 else ("high" if c == 2 else "low" if t == 1 else "on")
        print(f"#   {names.get(t, t):4} {what!s:8} {val:9} then {d} ms", file=sys.stderr)


def ccms(lib3a):
    print("# colour correction matrices (rows R', G', B'):", file=sys.stderr)
    for off in range(0x4000, 0x4A00, 4):
        m = np.frombuffer(lib3a[off:off + 36], "<f4").reshape(3, 3)
        if (np.all(np.isfinite(m)) and np.allclose(m.sum(1), 1, atol=0.03)
                and np.all((np.diag(m) > 1.05) & (np.diag(m) < 3.5)) and (m < 0).sum() >= 3):
            print(f"#   {off:#06x}: {np.round(m.astype(float), 3).tolist()}", file=sys.stderr)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    lib = open(sys.argv[1], "rb").read()
    lib3a = open(sys.argv[2], "rb").read()
    sensor_info(lib)
    ccms(lib3a)
    sys.stdout.write(regs_header(lib))


if __name__ == "__main__":
    main()
