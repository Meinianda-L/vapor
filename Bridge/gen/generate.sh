#!/bin/bash
# Regenerates bridge/generated/* from Steamworks SDK headers in a Proton lsteamclient
# checkout (input data only; the headers are not redistributed), and validates the
# result against Proton's own generated code.
#   git clone --depth 1 --filter=blob:none --sparse https://github.com/ValveSoftware/Proton.git
#   git -C Proton sparse-checkout set lsteamclient
# usage: gen/generate.sh <path to Proton/lsteamclient>
set -euo pipefail
cd "$(dirname "$0")"
python3 gen_bridge.py "$1" out
python3 validate.py "$1" out
python3 gen_code.py out ../generated
