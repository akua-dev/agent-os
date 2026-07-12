#!/usr/bin/env bash
# agent-os-container-entrypoint.sh - seed a persistent home and run Herdr.
set -eu

FM_HOME=${FM_HOME:-/home/agent}
export FM_HOME HOME="$FM_HOME"

mkdir -p "$FM_HOME/config" "$FM_HOME/data" "$FM_HOME/projects" "$FM_HOME/state"
if [ ! -e "$FM_HOME/config/backend" ]; then
  printf 'herdr\n' > "$FM_HOME/config/backend"
fi

cd /opt/agent-os
exec herdr server

