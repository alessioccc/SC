#!/usr/bin/env bash
set -euo pipefail

# XtalOpt executes this inside each candidate working directory.
# Run the generated template script.
bash job.in > job.stdout 2> job.stderr
