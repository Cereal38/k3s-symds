#!/bin/sh

set -e

# Stop the port-forwards started by up.sh, if still running.
for pidfile in .pf/*.pid; do
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
  fi
done
rm -rf .pf

k3d cluster delete k3s-symds
