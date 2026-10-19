#!/bin/sh
# Install agent-relay-logs into a target repository.
# All arguments are forwarded to scripts/relay_setup.py install.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$here/relay_setup.py" install "$@"
