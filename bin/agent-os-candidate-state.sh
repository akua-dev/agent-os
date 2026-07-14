#!/usr/bin/env bash
set -eu

state_file=${1:?candidate claim-chain state file is required}
[ -f "$state_file" ] && [ ! -L "$state_file" ] || {
  echo "error: candidate claim-chain state is unreadable" >&2
  exit 2
}

attempted_count=0
build_owner=
build_record_count=
build_artifact_count=
seen_owners='|'
seen_claims='|'
entries=0
while IFS=$'\t' read -r owner claim attempt record_count artifact_count extra || [ -n "${owner:-}" ]; do
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
      build_record_count=$record_count
      build_artifact_count=$artifact_count
      ;;
    *)
      echo "error: candidate attempt state is not exact: $attempt" >&2
      exit 2
      ;;
  esac
  [[ "$record_count" =~ ^[0-9]+$ ]] && [[ "$artifact_count" =~ ^[0-9]+$ ]] || {
    echo "error: candidate evidence counts are invalid" >&2
    exit 2
  }
  [ "$record_count" -le 1 ] && [ "$artifact_count" -le 1 ] || {
    echo "error: candidate evidence is ambiguous" >&2
    exit 2
  }
  if { [ "$record_count" -ne 0 ] || [ "$artifact_count" -ne 0 ]; } && \
    [ "$attempt" != attempted ]; then
    echo "error: candidate evidence is not bound to its build attempt" >&2
    exit 2
  fi
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
case "$build_record_count:$build_artifact_count" in
  1:1) printf 'reuse-record-pair\t%s\n' "$build_owner" ;;
  1:0) printf 'reuse-record\t%s\n' "$build_owner" ;;
  0:1) printf 'reuse-build\t%s\n' "$build_owner" ;;
  0:0)
    echo "error: candidate build attempt has no durable exact evidence; refusing rebuild" >&2
    exit 2
    ;;
esac
