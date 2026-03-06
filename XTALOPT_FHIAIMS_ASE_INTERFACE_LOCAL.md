# XtalOpt ↔ FHI-aims (Generic Optimizer, GUI, Local) — Final Practical Guide

This is the **single polished guide** to run XtalOpt with FHI-aims in **Generic** mode on your local machine.

Target environment:

- XtalOpt installed
- FHI-aims installed
- ASE installed
- local project directory:
  `/home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/xtalopt_test`

---

## 1) What to prepare once

```bash
mkdir -p /home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/xtalopt_test/{bin,templates,runs,logs}
cd /home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/xtalopt_test
```

Copy your four control templates:

```bash
cp /absolute/path/to/control.1.in templates/
cp /absolute/path/to/control.2.in templates/
cp /absolute/path/to/control.3.in templates/
cp /absolute/path/to/control.4.in templates/
```

Set runtime variables:

```bash
export FHIAIMS=/home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/bin/aims.250822.scalapack.mpi.x
export NP=10
# required by FHI-aims to avoid stack-related aborts
ulimit -s unlimited
# for quick tests: export NSTEPS=1 (or 2/3/4)
export NSTEPS=1
```


### Parallelism behavior (important)

With the provided setup, each candidate run executes:

```bash
mpirun -np "$NP" "$FHIAIMS"
```

inside that candidate directory. So:

- **Per structure**: FHI-aims uses `NP` MPI ranks (for you, `NP=10`).
- **Across structures**: XtalOpt may still run multiple candidates concurrently depending on queue/settings.

For stable local testing, start with effectively one structure at a time (small population and conservative queue settings), then increase concurrency only after validation.


---

## 2) Generic mode architecture (important)

In XtalOpt **generic** mode:

1. XtalOpt writes a template (e.g. `job.in`) in each candidate folder.
2. XtalOpt replaces placeholders such as `%POSCAR%`, `%filename%`, `%user1%`, etc.
3. XtalOpt launches the configured generic executable (a wrapper script).
4. Your scripts run FHI-aims and must write parseable output for XtalOpt.

So the Generic executable path is expected to be a wrapper, not directly `aims.x`.

---

## 3) Scripts you need

## 3.1 ASE converter (`bin/ase_convert.py`)

```python
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
```

```bash
chmod +x bin/ase_convert.py
```

---

## 3.2 4-step runner (`bin/run_aims_4step_local.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

WORKDIR=${1:?usage: run_aims_4step_local.sh <workdir> [nsteps]}
NSTEPS=${2:-${NSTEPS:-4}}   # easy switch: pass arg or export NSTEPS=1..4
FHIAIMS=${FHIAIMS:?set FHIAIMS}
NP=${NP:-4}
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
    # IMPORTANT: with N_i ~ 1/(KDENS*L_i), smaller KDENS means denser mesh (more expensive).
    # Keep early steps coarse/stable; tighten only later.
    1) KDENS=0.12 ;;
    2) KDENS=0.12 ;;
    3) KDENS=0.10 ;;
    4) KDENS=0.10 ;;
  esac

  # choose unit convention + optional cap (recommended for local tests)
  KUNIT=${KUNIT:-invA}          # invA or twoPiInvA
  KMAX=${KMAX:-12}              # cap to avoid accidentally huge meshes

  read -r KX KY KZ < <(python3 - <<'PYK' "$KDENS" "$KUNIT" "$KMAX"
import sys, math
from ase.io import read

kdens = float(sys.argv[1])
unit = sys.argv[2]
kmax = int(sys.argv[3])
at = read('geometry.in', format='aims')
L = at.cell.lengths()  # Å

if unit == 'twoPiInvA':
    vals = [max(1, int(round((2.0 * math.pi) / (kdens * x)))) if x > 1e-8 else 1 for x in L]
else:  # invA (recommended default)
    vals = [max(1, int(round(1.0 / (kdens * x)))) if x > 1e-8 else 1 for x in L]

vals = [min(kmax, v) for v in vals]
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
```

```bash
chmod +x bin/run_aims_4step_local.sh
```

### Unit convention note for k-density (important)

If you observe meshes like `22 22 11` for small cells, your unit convention is likely mismatched.

This guide now supports both conventions via `KUNIT`:

- `KUNIT=invA` (default, recommended):
  - `N_i = round(1 / (d_{1/Å} * L_i))`
- `KUNIT=twoPiInvA`:
  - `N_i = round(2π / (d_{2π/Å} * L_i))`

For your local tests, start with:

```bash
export KUNIT=invA
export KMAX=12
```

If you are absolutely sure your density definition is in `2π/Å`, switch to:

```bash
export KUNIT=twoPiInvA
```

---

## 3.3 Parser (`bin/parse_aims_for_xtalopt.py`)

```python
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
```

```bash
chmod +x bin/parse_aims_for_xtalopt.py
```

---

## 3.4 Generic wrapper executable (`bin/xtalopt_generic_exec.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail
bash job.in > job.stdout 2> job.stderr
```

```bash
chmod +x bin/xtalopt_generic_exec.sh
```

---

## 4) Template file used by XtalOpt (`job.in`)

In XtalOpt template editor, define `job.in` like this:

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE=/home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/xtalopt_test

# materialize structure from XtalOpt placeholder (IMPORTANT: no blank line inside heredoc)
cat > POSCAR <<'EOF_POSCAR'
%POSCAR%
EOF_POSCAR

# number of relaxation steps from XtalOpt user field (set user1 = 1..4)
# IMPORTANT: placeholder is %user1% (with both percent signs)
NSTEPS_RAW="%user1%"
if [[ "$NSTEPS_RAW" =~ ^[1-4]$ ]]; then
  NSTEPS="$NSTEPS_RAW"
else
  NSTEPS=1
fi

# preflight checks
if ! command -v mpirun >/dev/null 2>&1; then
  echo "mpirun not found in PATH" >&2
  exit 127
fi
if [[ ! -x "$FHIAIMS" ]]; then
  echo "FHIAIMS is not executable: $FHIAIMS" >&2
  exit 127
fi

# FHI-aims requirement: unlimited stack
ulimit -s unlimited

# run FHI-aims workflow
bash "$BASE/bin/run_aims_4step_local.sh" . "$NSTEPS"

# parse result
RES=$(python3 "$BASE/bin/parse_aims_for_xtalopt.py" --workdir . --mode energy)

# write fixed parse file for Generic mode (set parser target/job output to job.out)
cat > job.out <<EOF_RES
$RES
EOF_RES
```

> Use `job.out` as the parse file for Generic mode in this setup (configure Generic parser/output accordingly).
> Do not leave empty lines in the POSCAR heredoc content, otherwise ASE may fail parsing POSCAR.

---

## 5) XtalOpt GUI: exact click-by-click (your current window)

From **Optimization Settings**:

1. `Queue = local`
2. `Optimizer = generic` -> `Configure...`
   - set executable path to:
     `/home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/xtalopt_test/bin/xtalopt_generic_exec.sh`
3. `Template = job.in`
4. Keep single optimization item (`Optimization 1`)
5. Set `user1` field to the number of steps to run:
   - `1` for quick test with only `control.1.in`
   - `4` for full workflow

From **Search Settings**:

- use test run first: population `4`, generations `1`

Then click **Begin...**.

For a first smoke test set `user1=1`.

Notes:

- Do **not** use Multiobjective tab for this stage.
- Use one objective first (`--mode energy`).
- Switch to `--mode enthalpy` only if your science protocol requires enthalpy ranking and output contains enthalpy lines.

---

## 6) Validation before first population run

Check parser against your known output:

```bash
mkdir -p runs/test_parse
cp /absolute/path/to/fhi.out runs/test_parse/aims.log
python3 bin/parse_aims_for_xtalopt.py --workdir runs/test_parse --mode energy
```

Optional enthalpy check:

```bash
grep -Ei 'Total energy|enthalpy' runs/test_parse/aims.log | tail -n 20
python3 bin/parse_aims_for_xtalopt.py --workdir runs/test_parse --mode enthalpy
```

If this passes and XtalOpt creates/ranks candidates, interface is correctly set.

For a first smoke test, keep `NSTEPS=1` (only `control.1.in`). Then raise to `NSTEPS=4`.


---

## 7) Troubleshooting from your first run (the errors you reported)

Your logs show two key issues:

1. `NSTEPS=user1` then `unbound variable`
2. `%filename%` expanded to a directory path

### Fix A — `user1` placeholder

Use `%user1%` in template and guard non-numeric values:

- if `user1` is empty or malformed, fallback to `NSTEPS=1`.

Also set `user1` explicitly in GUI to `1` for first test.

### Fix B — output file path

For this setup, avoid `%filename%` entirely and always write parser output to `job.out` in each candidate folder.
Then point Generic parser/output expectations to `job.out`.

### What to check in each candidate folder

After rerun, each `runs/00001x0000X/` should contain:

- `geometry.in`
- `control.in` (or step outputs)
- `aims.step1.out` (if `user1=1`)
- `aims.log`
- parse output file (`%filename%` target or `job.out`)

If these exist and parser prints `success=1 ...`, XtalOpt should stop reporting `Error` for Step0.


### Fix C — ASE POSCAR parse failure (`The number of scaling factors must be 1 or 3`)

Root cause in your log: POSCAR file started with an empty line, so ASE tried to parse
`H9S3 /path/...` as the scaling-factor line.

Use the `job.in` POSCAR heredoc exactly as shown (no blank line at the beginning of the heredoc body).

Quick check in a failed candidate folder:

```bash
sed -n '1,5p' POSCAR | cat -A
```

Expected:

- line 1: comment (formula/path text is fine)
- line 2: scaling factor (`1`)

If line 1 is blank, remove extra newline in template and rerun.


### Fix D — XtalOpt placeholder expansion inside comments/shell syntax

XtalOpt replaces `%...%` patterns everywhere in the template text, including comments.
Two rules prevent hard-to-debug failures:

1. Do **not** include placeholder tokens inside comments (for example `%POSCAR%` in a comment line).
2. Do **not** use bash `${var%/}` parameter expansion in `job.in` because `%...` can be altered by template substitution.

Use `sed`/`printf` for path cleanup instead.


### Fix E — mpirun cannot execute FHI-aims binary

Your current blocking error is:

- `mpirun was unable to launch ... could not access or execute`.

This means the `FHIAIMS` path is wrong or not executable.

Run these checks in your terminal:

```bash
ls -l /home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/bin/aims.250822.scalapack.mpi.x
file /home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/bin/aims.250822.scalapack.mpi.x
chmod +x /home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/bin/aims.250822.scalapack.mpi.x
mpirun -np 2 /home/alessio-cucciari/Desktop/Programs/fhi-aims.250822/bin/aims.250822.scalapack.mpi.x > /tmp/aims_smoke.out
```

If the smoke run fails outside XtalOpt, fix FHI-aims binary/runtime first; XtalOpt is not the root cause.


### Fix F — stack size must be unlimited

Yes: your interpretation is correct. FHI-aims explicitly requires:

```bash
ulimit -s unlimited
```

Apply it in three places for safety:

1. your interactive shell before launching XtalOpt,
2. `job.in` template before calling runner,
3. runner script before `mpirun`.

Quick verification command (inside a candidate folder):

```bash
ulimit -s
```

Expected output: `unlimited`.


### Fix G — k_grid unexpectedly too fine

Your example (`2.37, 2.37, 4.63 Å` cell with `k_grid 22 22 11`) is mathematically consistent with `KUNIT=twoPiInvA` and `d=0.12`, but usually too expensive for screening.

Use:

```bash
export KUNIT=invA
export KMAX=12
```

This typically gives much more practical first-step meshes for evolutionary searches.

### Fix H — jobs are "Killed": how to diagnose from `log.txt`

When runs terminate with plain `Killed` / `Terminated` and no final FHI-aims stack trace, the most common cause is the Linux OOM killer (out-of-memory), especially with high `NP` and/or dense `k_grid`.

Use this quick triage on your `log.txt`:

```bash
# 1) extract kill-like signatures
grep -Eni 'killed|terminated|out of memory|oom|sigkill|signal 9|exceeded' log.txt | tail -n 50

# 2) extract the final FHI-aims context
grep -Eni 'k_grid|Total energy|SCF|Have a nice day|error|abort|mpi' log.txt | tail -n 80
```

Interpretation guide:

- `Killed` / `signal 9` near `mpirun` without a normal FHI-aims ending (`Have a nice day.`) -> likely OOM kill.
- queue messages such as `walltime exceeded` / `time limit` -> runtime limit kill.
- parser errors after abrupt stop (`total energy not found`) -> calculation was interrupted before convergence/output write.

Mitigations (apply in this order):

1. Reduce memory pressure:
   - lower ranks: `export NP=2` (or `1`) for debugging,
   - force coarser meshes: `export KUNIT=invA; export KMAX=8`.
2. Keep first validation short:
   - `user1=1` (single control step),
   - tiny population/generation in XtalOpt.
3. Keep `ulimit -s unlimited` enabled (already required above).
4. If using a scheduler, increase walltime/memory request.

Minimal safe debug profile:

```bash
export NP=2
export NSTEPS=1
export KUNIT=invA
export KMAX=8
ulimit -s unlimited
```

If this profile runs successfully and larger settings fail, the termination is resource-driven rather than an XtalOpt-Generic interface bug.


### Fix I — crash after the first relaxation step (Step2 failure)

If Step1 finishes but Step2 crashes, the most common reason in this workflow is **resource escalation at Step2**:

- the default k-grid formula is inverse in `KDENS` (`N_i ~ 1/(KDENS*L_i)`), so **lowering `KDENS` increases k-point count**;
- the cell can shrink after Step1 relaxation, which further increases k-points;
- combined with unchanged `NP`, Step2 can exceed memory and get killed.

In short: Step2 may be significantly heavier than Step1 even if the structure is similar.

Recommended fix:

1. Keep Step1/Step2 equally coarse first (`KDENS=0.12`, `KMAX=8..12`).
2. Tighten only in later steps (e.g., Step3/Step4).
3. Reduce MPI ranks for debugging (`NP=1..2`).
4. Confirm Step2 k-grid from logs before rerun:

```bash
grep -n "step=\|k_grid" aims.step1.out aims.step2.out 2>/dev/null
```

If Step2 succeeds under coarse settings, the crash cause is computational load (k-grid/memory), not a template-placeholder issue.

### Fix J — FHI-aims succeeds but XtalOpt still marks job failed (`job.in`/`job.out` handshake)

If `aims.log` shows normal completion but XtalOpt still kills/rejects the structure, the failure is usually in the **Generic parser handshake**, not in FHI-aims itself.

Typical pattern:

- `aims.step*.out`/`aims.log` contain converged SCF and normal ending,
- but XtalOpt reports parse/job failure,
- and `job.out` is missing, empty, malformed, or written to a different filename than XtalOpt expects.

Root causes to check:

1. **Mismatch between produced file and configured parse target**
   - script writes `job.out`, but XtalOpt is configured to parse `%filename%` (or vice versa).
2. **`set -e` exits before writing parse line**
   - e.g., a non-critical command fails after FHI-aims but before `job.out` is produced.
3. **Parser output not in Generic expected format**
   - must contain `success=1 target=...` on stdout (single parse line).
4. **Shell expansion collision with XtalOpt placeholders**
   - `%...%` tokens in comments/strings can be unexpectedly replaced.

Robust `job.in` tail (recommended):

```bash
# parse result (capture parser stderr to debug log, keep stdout clean)
RES=$(python3 "$BASE/bin/parse_aims_for_xtalopt.py" --workdir . --mode energy 2>> job.stderr)

# write EXACT parse file expected by XtalOpt Generic settings
printf '%s\n' "$RES" > job.out

# optional debug breadcrumb
printf 'Wrote parser line to %s/job.out\n' "$(pwd)" >> job.stdout
```

Hard checks in a failed candidate directory:

```bash
ls -l job.in job.out job.stdout job.stderr aims.log
sed -n '1,5p' job.out
python3 "$BASE/bin/parse_aims_for_xtalopt.py" --workdir . --mode energy
```

Expected `job.out` first line format:

```text
success=1 target=-123.456... energy=-123.456... enthalpy=-123.456...
```

If this line exists and XtalOpt still fails, re-open Generic configuration and ensure the parser/output filename is exactly `job.out` (not `%filename%`).
