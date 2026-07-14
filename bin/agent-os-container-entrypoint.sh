#!/usr/bin/env bash
# agent-os-container-entrypoint.sh - seed a persistent home and run Herdr.
set -eu

FM_HOME=${FM_HOME:-/home/agent}
export FM_HOME HOME="$FM_HOME"
FM_ROOT=${FM_ROOT_OVERRIDE:-$FM_HOME/firstmate}
IMAGE_SOURCE=${AGENT_OS_IMAGE_SOURCE:-/opt/agent-os-bootstrap.git}
SOURCE_COMMIT=$(cat /opt/agent-os-source.commit)
SOURCE_TREE=$(cat /opt/agent-os-source.tree)
SOURCE_BRANCH=$(cat /opt/agent-os-source.branch)
SOURCE_ORIGIN=$(cat /opt/agent-os-source.origin)
SOURCE_MODE=$(cat /opt/agent-os-source.mode)
SOURCE_REF=$(cat /opt/agent-os-source.ref)
case "$SOURCE_BRANCH" in ''|*[!A-Za-z0-9._/-]*|/*|*/|*..*) echo "error: image source branch provenance is invalid" >&2; exit 2 ;; esac
[ "$SOURCE_ORIGIN" = https://github.com/akua-dev/agent-os.git ] || { echo "error: image source origin is invalid" >&2; exit 2; }
case "$SOURCE_MODE" in
  main) [ "$SOURCE_REF" = refs/heads/main ] || exit 2; TRUSTED_REF=refs/remotes/agent-os-verified/main ;;
  release) [[ "$SOURCE_REF" =~ ^refs/tags/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 2; TRUSTED_REF=refs/remotes/agent-os-verified/release ;;
  event) echo "error: pull-request validation images are not runnable" >&2; exit 2 ;;
  *) echo "error: image source mode is invalid" >&2; exit 2 ;;
esac
IMAGE_REF="refs/remotes/agent-os-image/$SOURCE_BRANCH"

trusted_git() {
  env -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    -u GIT_SSH -u GIT_SSH_COMMAND GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c core.hooksPath=/dev/null \
    -c http.proxy= -c https.proxy= "$@"
}

validate_git_config() {
  local config="$FM_ROOT/.git/config" key value
  [ -f "$config" ] || { echo "error: canonical FM_ROOT Git config is unavailable" >&2; exit 2; }
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value=$(trusted_git config --file "$config" --no-includes --get-all "$key" || true)
    [ -n "$value" ] && [ "$value" = "$(printf '%s\n' "$value" | head -n 1)" ] || {
      echo "error: canonical FM_ROOT Git config key is duplicated or empty" >&2
      exit 2
    }
    case "$key" in
      core.repositoryformatversion) [ "$value" = 0 ] ;;
      core.filemode) [ "$value" = true ] || [ "$value" = false ] ;;
      core.bare) [ "$value" = false ] ;;
      core.logallrefupdates) [ "$value" = true ] ;;
      remote.origin.url) [ "$value" = "$SOURCE_ORIGIN" ] && [ "$value" = https://github.com/akua-dev/agent-os.git ] ;;
      remote.origin.fetch)
        [ "$value" = '+refs/heads/*:refs/remotes/origin/*' ] || \
          [ "$value" = "+refs/heads/$SOURCE_BRANCH:refs/remotes/origin/$SOURCE_BRANCH" ]
        ;;
      branch."$SOURCE_BRANCH".remote) [ "$value" = origin ] ;;
      branch."$SOURCE_BRANCH".merge) [ "$value" = "refs/heads/$SOURCE_BRANCH" ] ;;
      *) echo "error: canonical FM_ROOT Git config key is not allowlisted: $key" >&2; exit 2 ;;
    esac || { echo "error: canonical FM_ROOT Git config value is invalid: $key" >&2; exit 2; }
  done < <(trusted_git config --file "$config" --no-includes --name-only --list)
  [ "$(trusted_git config --file "$config" --no-includes --get remote.origin.url || true)" = "$SOURCE_ORIGIN" ] || {
    echo "error: canonical FM_ROOT origin provenance changed" >&2
    exit 2
  }
}

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
  trusted_git -c protocol.file.allow=always clone --no-local --branch "$SOURCE_BRANCH" "$IMAGE_SOURCE" "$FM_ROOT"
  trusted_git -C "$FM_ROOT" remote set-url origin "$SOURCE_ORIGIN"
  validate_git_config
  [ "$(trusted_git -C "$FM_ROOT" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || {
    echo "error: canonical FM_ROOT bootstrap commit provenance failed" >&2
    exit 2
  }
  rm -rf "$FM_ROOT/.git/hooks"
else
  [ -d "$FM_ROOT/.git" ] || { echo "error: canonical FM_ROOT Git metadata is invalid" >&2; exit 2; }
  validate_git_config
  [ -z "$(trusted_git -C "$FM_ROOT" status --porcelain)" ] || { echo "error: canonical FM_ROOT is not clean" >&2; exit 2; }
  trusted_git -c protocol.file.allow=always -C "$FM_ROOT" fetch --no-tags "$IMAGE_SOURCE" \
    "refs/heads/$SOURCE_BRANCH:$IMAGE_REF"
  [ "$(trusted_git -C "$FM_ROOT" rev-parse "$IMAGE_REF")" = "$SOURCE_COMMIT" ] || {
    echo "error: image source trusted ref provenance failed" >&2
    exit 2
  }
  [ "$(trusted_git -C "$FM_ROOT" rev-parse "$IMAGE_REF^{tree}")" = "$SOURCE_TREE" ] || {
    echo "error: image source trusted tree provenance failed" >&2
    exit 2
  }
  current_branch=$(trusted_git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD || true)
  if [ -z "$current_branch" ]; then
    trusted_git -C "$FM_ROOT" merge-base --is-ancestor HEAD "$IMAGE_REF" || {
      echo "error: detached canonical FM_ROOT lacks trusted fast-forward provenance" >&2
      exit 2
    }
    if trusted_git -C "$FM_ROOT" show-ref --verify --quiet "refs/heads/$SOURCE_BRANCH"; then
      [ "$(trusted_git -C "$FM_ROOT" rev-parse "refs/heads/$SOURCE_BRANCH")" = "$(trusted_git -C "$FM_ROOT" rev-parse HEAD)" ] || {
        echo "error: canonical default branch conflicts with detached provenance" >&2
        exit 2
      }
    else
      trusted_git -C "$FM_ROOT" branch "$SOURCE_BRANCH" HEAD
    fi
    trusted_git -C "$FM_ROOT" checkout "$SOURCE_BRANCH"
  fi
  [ "$(trusted_git -C "$FM_ROOT" symbolic-ref --short HEAD)" = "$SOURCE_BRANCH" ] || {
    echo "error: canonical FM_ROOT is not on the declared default branch" >&2
    exit 2
  }
  if trusted_git -C "$FM_ROOT" merge-base --is-ancestor HEAD "$IMAGE_REF"; then
    trusted_git -C "$FM_ROOT" merge --ff-only "$IMAGE_REF"
  elif ! trusted_git -C "$FM_ROOT" merge-base --is-ancestor "$SOURCE_COMMIT" HEAD; then
    echo "error: canonical FM_ROOT source transition is not fast-forward compatible" >&2
    exit 2
  fi
  trusted_git -C "$FM_ROOT" update-ref -d "$IMAGE_REF"
fi

[ "$(trusted_git -C "$FM_ROOT" symbolic-ref --short HEAD)" = "$SOURCE_BRANCH" ] || {
  echo "error: canonical FM_ROOT is not on the declared default branch" >&2
  exit 2
}
[ "$(trusted_git -C "$FM_ROOT" rev-parse "$SOURCE_COMMIT^{tree}")" = "$SOURCE_TREE" ] || {
  echo "error: canonical FM_ROOT image source tree provenance failed" >&2
  exit 2
}
validate_git_config
trusted_git -C "$FM_ROOT" fetch --no-tags --prune "$SOURCE_ORIGIN" \
  "$SOURCE_REF:$TRUSTED_REF" || {
  echo "error: fresh trusted source provenance is unavailable" >&2
  exit 3
}
trusted_git -C "$FM_ROOT" merge-base --is-ancestor "$SOURCE_COMMIT" "$TRUSTED_REF" || {
  echo "error: image source commit is not reachable from the fresh trusted ref" >&2
  exit 2
}
if [ "$SOURCE_MODE" = main ]; then
  trusted_git -C "$FM_ROOT" merge-base --is-ancestor HEAD "$TRUSTED_REF" || {
    echo "error: canonical FM_ROOT contains source not reachable from the fresh trusted ref" >&2
    exit 2
  }
  trusted_git -C "$FM_ROOT" merge --ff-only "$TRUSTED_REF"
else
  [ "$(trusted_git -C "$FM_ROOT" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || {
    echo "error: release FM_ROOT differs from its immutable release commit" >&2
    exit 2
  }
fi
[ "$(trusted_git -C "$FM_ROOT" rev-parse HEAD)" = "$(trusted_git -C "$FM_ROOT" rev-parse "$TRUSTED_REF^{commit}")" ] || {
  echo "error: canonical FM_ROOT HEAD is not the exact fresh trusted source ref" >&2
  exit 2
}
trusted_git -C "$FM_ROOT" update-ref "refs/remotes/origin/$SOURCE_BRANCH" "$TRUSTED_REF"
[ -z "$(trusted_git -C "$FM_ROOT" status --porcelain)" ] || { echo "error: canonical FM_ROOT is not clean" >&2; exit 2; }
[ -z "$(trusted_git -C "$FM_ROOT" ls-files -- config data projects state .no-mistakes)" ] || {
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
