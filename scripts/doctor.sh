#!/bin/sh
# Check an installed agent-relay-logs target.
# All arguments are forwarded to scripts/relay_setup.py doctor.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$here/relay_setup.py" doctor "$@"
