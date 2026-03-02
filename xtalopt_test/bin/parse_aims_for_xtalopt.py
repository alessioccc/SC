#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path

ENERGY_RE = re.compile(r"\|\s+Total energy of the DFT / Hartree-Fock s\.c\.f\. calculation\s*:\s*([-+0-9Ee\.]+)")
ENTHALPY_RES = [
    re.compile(r"enthalpy\s*[:=]\s*([-+0-9Ee\.]+)", re.IGNORECASE),
    re.compile(r"total\s+enthalpy\s*[:=]\s*([-+0-9Ee\.]+)", re.IGNORECASE),
]

p = argparse.ArgumentParser()
p.add_argument('--workdir', required=True)
p.add_argument('--mode', choices=['energy', 'enthalpy'], default='energy')
a = p.parse_args()

out = Path(a.workdir) / 'aims.log'
if not out.exists():
    print('ERROR: aims.log not found', file=sys.stderr)
    sys.exit(2)

text = out.read_text(errors='replace')
energies = ENERGY_RE.findall(text)
if not energies:
    print('ERROR: total energy not found', file=sys.stderr)
    sys.exit(3)
E = float(energies[-1])

H = None
for rx in ENTHALPY_RES:
    m = rx.findall(text)
    if m:
        H = float(m[-1]); break
if H is None:
    H = E

target = H if a.mode == 'enthalpy' else E
print(f"success=1 target={target:.12f} energy={E:.12f} enthalpy={H:.12f}")
