#!/usr/bin/env python3
import argparse
from ase.io import read, write

p = argparse.ArgumentParser()
p.add_argument('--infile', required=True)
p.add_argument('--outfile', required=True)
p.add_argument('--informat', required=True, choices=['vasp', 'aims'])
p.add_argument('--outformat', required=True, choices=['vasp', 'aims'])
a = p.parse_args()

atoms = read(a.infile, format=a.informat)
write(a.outfile, atoms, format=a.outformat)
