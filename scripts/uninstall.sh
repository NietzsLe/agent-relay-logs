#!/bin/sh
# Remove agent-relay-logs from a target repository.
# All arguments are forwarded to scripts/relay_setup.py uninstall.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$here/relay_setup.py" uninstall "$@"
