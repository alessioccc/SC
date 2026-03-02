#!/usr/bin/env bash
set -euo pipefail

WORKDIR=${1:?usage: run_aims_4step_local.sh <workdir> [nsteps]}
NSTEPS=${2:-${NSTEPS:-4}}   # easy switch: pass arg or export NSTEPS=1..4
FHIAIMS=${FHIAIMS:?set FHIAIMS}
NP=${NP:-10}
BASE=/home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/xtalopt_test

if [[ ! -x "$FHIAIMS" ]]; then
  echo "FHI-aims executable not found or not executable: $FHIAIMS" >&2
  exit 127
fi

if (( NSTEPS < 1 || NSTEPS > 4 )); then
  echo "NSTEPS must be between 1 and 4" >&2
  exit 2
fi

cd "$WORKDIR"

# FHI-aims requirement: unlimited stack
ulimit -s unlimited

# if XtalOpt provides POSCAR, convert to geometry.in
if [[ -f POSCAR && ! -f geometry.in ]]; then
  python3 "$BASE/bin/ase_convert.py" --infile POSCAR --informat vasp --outfile geometry.in --outformat aims
fi

for step in $(seq 1 "$NSTEPS"); do
  cp "$BASE/templates/control.${step}.in" control.in

  # dynamic k-grid from current geometry.in
  # KDENS here is interpreted in 2π/Å units (your convention)
  case "$step" in
    1) KDENS=0.12 ;;
    2) KDENS=0.10 ;;
    3) KDENS=0.08 ;;
    4) KDENS=0.08 ;;
  esac

read -r KX KY KZ < <(python3 - <<'PYK' "$KDENS"
import sys, math
from ase.io import read

# KDENS = target spacing in reciprocal space, units: 2π/Å
dk2pi = float(sys.argv[1])

# safety caps for structural relaxation in searches
KMIN, KMAX = 1, 12

at = read('geometry.in', format='aims')
L = at.cell.lengths()  # Å

vals = []
for x in L:
    if x < 1e-8:
        n = 1
    else:
        # If dk is in 2π/Å, |b_i| = 1/L_i in same units -> N ≈ (1/L)/dk
        n = int(math.ceil(1.0 / (dk2pi * x)))
    n = max(KMIN, min(KMAX, n))
    vals.append(n)

print(vals[0], vals[1], vals[2])
PYK
)
  sed -i '/^\s*k_grid\s\+/d' control.in
  echo "k_grid ${KX} ${KY} ${KZ}" >> control.in
  echo "step=$step KDENS=$KDENS k_grid=$KX $KY $KZ"

  mpirun -np "$NP" "$FHIAIMS" > "aims.step${step}.out"

  # if present, use relaxed geometry for next step
  if [[ -f geometry.in.next_step ]]; then
    cp geometry.in.next_step geometry.in
  fi
done

cp "aims.step${NSTEPS}.out" aims.log
