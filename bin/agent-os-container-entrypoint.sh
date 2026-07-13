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

if [ -n "${AGENT_OS_PI_AUTH_FILE:-}" ]; then
  if [ ! -f "$AGENT_OS_PI_AUTH_FILE" ]; then
    echo "error: projected Pi authorization is unavailable" >&2
    exit 2
  fi
  mkdir -p "$HOME/.pi/agent"
  ln -sfn -- "$AGENT_OS_PI_AUTH_FILE" "$HOME/.pi/agent/auth.json"
fi

"$(dirname "$0")/agent-os-kubeconfig.sh"
if [ ! -e "$FM_HOME/config/backend" ]; then
  printf 'herdr\n' > "$FM_HOME/config/backend"
fi

# The local evaluation overlay may pin every spawned Pi agent while a model is
# under test. This is deliberately opt-in so the reusable image and Akua
# packages remain model-agnostic. Converge both dispatch files on every Pod
# start: crew-dispatch governs crewmates/scouts, while secondmate-harness is the
# separate profile used to launch Secondmates.
if [ -n "${AGENT_OS_TEST_PI_MODEL:-}" ]; then
  case "$AGENT_OS_TEST_PI_MODEL" in
    */*) ;;
    *)
      echo "error: AGENT_OS_TEST_PI_MODEL must include its provider" >&2
      exit 2
      ;;
  esac
  case "$AGENT_OS_TEST_PI_MODEL" in
    *[!A-Za-z0-9._:/-]*)
      echo "error: AGENT_OS_TEST_PI_MODEL must be one provider-qualified token" >&2
      exit 2
      ;;
  esac
  case "${AGENT_OS_TEST_PI_EFFORT:-}" in
    low|medium|high|xhigh) ;;
    *)
      echo "error: AGENT_OS_TEST_PI_EFFORT must be low, medium, high, or xhigh" >&2
      exit 2
      ;;
  esac
  cat > "$FM_HOME/config/crew-dispatch.json" <<EOF
{
  "rules": [],
  "default": {
    "harness": "pi",
    "model": "$AGENT_OS_TEST_PI_MODEL",
    "effort": "$AGENT_OS_TEST_PI_EFFORT"
  }
}
EOF
  printf 'pi %s %s\n' "$AGENT_OS_TEST_PI_MODEL" "$AGENT_OS_TEST_PI_EFFORT" \
    > "$FM_HOME/config/secondmate-harness"

  pi_provider=${AGENT_OS_TEST_PI_MODEL%%/*}
  pi_model=${AGENT_OS_TEST_PI_MODEL#*/}
  pi_settings_dir="$HOME/.pi/agent"
  pi_settings="$pi_settings_dir/settings.json"
  pi_settings_tmp="$pi_settings.tmp.$$"
  mkdir -p "$pi_settings_dir"
  umask 077
  if [ -s "$pi_settings" ] && jq -e 'type == "object"' "$pi_settings" >/dev/null 2>&1; then
    jq \
      --arg provider "$pi_provider" \
      --arg model "$pi_model" \
      --arg thinking "$AGENT_OS_TEST_PI_EFFORT" \
      '. + {defaultProvider: $provider, defaultModel: $model, defaultThinkingLevel: $thinking}' \
      "$pi_settings" > "$pi_settings_tmp"
  else
    jq -n \
      --arg provider "$pi_provider" \
      --arg model "$pi_model" \
      --arg thinking "$AGENT_OS_TEST_PI_EFFORT" \
      '{defaultProvider: $provider, defaultModel: $model, defaultThinkingLevel: $thinking}' \
      > "$pi_settings_tmp"
  fi
  mv "$pi_settings_tmp" "$pi_settings"
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
