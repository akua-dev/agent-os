#!/usr/bin/env bash

export AGENT_OS_BOUND_PATH

agent_os_open_bound_dir() {
  local dir=$1 fd fd_root
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  exec {fd}<"$dir" || return 1
  if [ -d "/proc/self/fd/$fd" ]; then
    fd_root=/proc/self/fd
    [ "$dir" -ef "$fd_root/$fd" ] || {
      exec {fd}<&-
      return 1
    }
    AGENT_OS_BOUND_PATH=$fd_root/$fd
    return 0
  elif [ "${AGENT_OS_TEST_BOUND_PATHS:-}" = true ]; then
    exec {fd}<&-
    AGENT_OS_BOUND_PATH=$(cd "$dir" && pwd -P)
    return 0
  else
    exec {fd}<&-
    return 1
  fi
}

agent_os_bound_dir_matches() {
  local dir=$1 bound=$2
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$dir" -ef "$bound" ]
}

agent_os_bound_git() {
  local git_dir=$1 work_tree=$2
  shift 2
  trusted_git --git-dir="$git_dir" --work-tree="$work_tree" "$@"
}
