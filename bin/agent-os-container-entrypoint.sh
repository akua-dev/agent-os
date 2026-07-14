#!/usr/bin/env bash
# agent-os-container-entrypoint.sh - seed a persistent home and run Herdr.
set -eu

FM_HOME=${FM_HOME:-/home/agent}
export FM_HOME HOME="$FM_HOME"
FM_ROOT=${FM_ROOT_OVERRIDE:-$FM_HOME/firstmate}
IMAGE_SOURCE=${AGENT_OS_IMAGE_SOURCE:-/opt/agent-os-bootstrap}
SOURCE_COMMIT=$(cat /opt/agent-os-source.commit)
SOURCE_TREE=$(cat /opt/agent-os-source.tree)
SOURCE_ORIGIN=$(cat /opt/agent-os-source.origin)

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

if [ ! -e "$FM_ROOT/.git" ]; then
  [ ! -e "$FM_ROOT" ] || { echo "error: canonical FM_ROOT exists without Git provenance" >&2; exit 2; }
  git clone --no-local "$IMAGE_SOURCE" "$FM_ROOT"
  git -C "$FM_ROOT" checkout --detach "$SOURCE_COMMIT"
  git -C "$FM_ROOT" remote set-url origin "$SOURCE_ORIGIN"
  rm -rf "$FM_ROOT/.git/hooks"
else
  [ -d "$FM_ROOT/.git" ] || { echo "error: canonical FM_ROOT Git metadata is invalid" >&2; exit 2; }
  [ "$(git -C "$FM_ROOT" remote get-url origin)" = "$SOURCE_ORIGIN" ] || {
    echo "error: canonical FM_ROOT origin provenance changed" >&2
    exit 2
  }
  [ -z "$(git -C "$FM_ROOT" status --porcelain)" ] || { echo "error: canonical FM_ROOT is not clean" >&2; exit 2; }
  if git -C "$FM_ROOT" merge-base --is-ancestor HEAD "$SOURCE_COMMIT"; then
    git -C "$FM_ROOT" fetch --no-tags "$IMAGE_SOURCE" "$SOURCE_COMMIT"
    git -C "$FM_ROOT" merge --ff-only "$SOURCE_COMMIT"
  elif ! git -C "$FM_ROOT" merge-base --is-ancestor "$SOURCE_COMMIT" HEAD; then
    echo "error: canonical FM_ROOT source transition is not fast-forward compatible" >&2
    exit 2
  fi
fi

[ "$(git -C "$FM_ROOT" rev-parse "$SOURCE_COMMIT^{tree}")" = "$SOURCE_TREE" ] || {
  echo "error: canonical FM_ROOT image source tree provenance failed" >&2
  exit 2
}
[ -z "$(git -C "$FM_ROOT" status --porcelain)" ] || { echo "error: canonical FM_ROOT is not clean" >&2; exit 2; }
[ -z "$(git -C "$FM_ROOT" ls-files -- config data projects state .no-mistakes)" ] || {
  echo "error: canonical FM_ROOT contains operational state" >&2
  exit 2
}
find "$FM_ROOT/.git/hooks" -mindepth 1 -print -quit 2>/dev/null | grep -q . && {
  echo "error: canonical FM_ROOT contains Git hooks" >&2
  exit 2
}
export FM_ROOT_OVERRIDE="$FM_ROOT"
ln -sfn "$FM_ROOT/tools/agent-os/src/cli.ts" "$HOME/.local/bin/agent-os"

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

cd "$FM_ROOT"
exec herdr server
