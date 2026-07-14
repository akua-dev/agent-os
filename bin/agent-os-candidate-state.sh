#!/usr/bin/env bash
set -eu

state_file=${1:?candidate claim-chain state file is required}
[ -f "$state_file" ] && [ ! -L "$state_file" ] || {
  echo "error: candidate claim-chain state is unreadable" >&2
  exit 2
}

attempted_count=0
build_owner=
build_evidence=
seen_owners='|'
seen_claims='|'
entries=0
while IFS=$'\t' read -r owner claim attempt evidence extra || [ -n "${owner:-}" ]; do
  [ -z "${extra:-}" ] || {
    echo "error: candidate claim-chain state has extra fields" >&2
    exit 2
  }
  [[ "$owner" =~ ^[0-9]+$ ]] && [[ "$claim" =~ ^[0-9a-f]{40}$ ]] || {
    echo "error: candidate claim-chain identity is invalid" >&2
    exit 2
  }
  case "$seen_owners" in *"|$owner|"*) echo "error: candidate claim owner is duplicated" >&2; exit 2 ;; esac
  case "$seen_claims" in *"|$claim|"*) echo "error: candidate claim commit is duplicated" >&2; exit 2 ;; esac
  seen_owners="${seen_owners}${owner}|"
  seen_claims="${seen_claims}${claim}|"
  entries=$((entries + 1))
  case "$attempt" in
    absent) ;;
    attempted)
      attempted_count=$((attempted_count + 1))
      build_owner=$owner
      build_evidence=$evidence
      ;;
    *)
      echo "error: candidate attempt state is not exact: $attempt" >&2
      exit 2
      ;;
  esac
  case "$evidence" in
    absent) ;;
    exact-record|exact-build)
      [ "$attempt" = attempted ] || {
        echo "error: candidate evidence is not bound to its build attempt" >&2
        exit 2
      }
      ;;
    *)
      echo "error: candidate evidence state is not exact: $evidence" >&2
      exit 2
      ;;
  esac
done < "$state_file"

[ "$entries" -gt 0 ] || {
  echo "error: candidate claim chain is empty" >&2
  exit 2
}
[ "$attempted_count" -le 1 ] || {
  echo "error: candidate claim chain contains multiple build attempts" >&2
  exit 2
}
if [ "$attempted_count" -eq 0 ]; then
  printf 'build\n'
  exit 0
fi
case "$build_evidence" in
  exact-record) printf 'reuse-record\t%s\n' "$build_owner" ;;
  exact-build) printf 'reuse-build\t%s\n' "$build_owner" ;;
  absent)
    echo "error: candidate build attempt has no durable exact evidence; refusing rebuild" >&2
    exit 2
    ;;
esac
