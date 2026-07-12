#!/usr/bin/env bash
# agent-os-container-entrypoint.sh - seed a persistent home and run Herdr.
set -eu

FM_HOME=${FM_HOME:-/home/agent}
export FM_HOME HOME="$FM_HOME"

mkdir -p \
  "$FM_HOME/config" \
  "$FM_HOME/data" \
  "$FM_HOME/projects" \
  "$FM_HOME/state" \
  "$HOME/.config/agent-os" \
  "$HOME/.cache" \
  "$HOME/.local/bin" \
  "$HOME/.local/share" \
  "$HOME/.bun" \
  "$HOME/.cargo"

"$(dirname "$0")/agent-os-kubeconfig.sh"
if [ ! -e "$FM_HOME/config/backend" ]; then
  printf 'herdr\n' > "$FM_HOME/config/backend"
fi

for tool in gh-axi chrome-devtools-axi lavish-axi; do
  marker="$HOME/.config/agent-os/setup-$tool"
  if [ ! -e "$marker" ]; then
    "$tool" setup hooks
    : > "$marker"
  fi
done

cd /opt/agent-os
exec herdr server
