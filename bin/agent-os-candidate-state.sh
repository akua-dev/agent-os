#!/usr/bin/env bash
set -eu

state_file=${1:?candidate claim-chain state file is required}
[ -f "$state_file" ] && [ ! -L "$state_file" ] || {
  echo "error: candidate claim-chain state is unreadable" >&2
  exit 2
}

attempted_count=0
build_owner=
record_owner=
record_total=0
build_total=0
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
  if [ "$artifact_count" -eq 1 ]; then
    [ "$attempt" = attempted ] || {
      echo "error: candidate build evidence is not bound to its build attempt" >&2
      exit 2
    }
    build_total=$((build_total + 1))
  fi
  if [ "$record_count" -eq 1 ]; then
    [ "$attempted_count" -eq 1 ] || {
      echo "error: candidate record evidence precedes its build attempt" >&2
      exit 2
    }
    record_total=$((record_total + 1))
    record_owner=$owner
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
[ "$record_total" -le 1 ] && [ "$build_total" -le 1 ] || {
  echo "error: candidate claim chain contains conflicting durable evidence" >&2
  exit 2
}
if [ "$attempted_count" -eq 0 ]; then
  printf 'build\n'
  exit 0
fi
case "$record_total:$build_total" in
  1:1) printf 'reuse-record-pair\t%s\t%s\n' "$record_owner" "$build_owner" ;;
  1:0)
    [ "$record_owner" = "$build_owner" ] || {
      echo "error: recovered candidate record lacks exact build evidence" >&2
      exit 2
    }
    printf 'reuse-record\t%s\n' "$record_owner"
    ;;
  0:1) printf 'reuse-build\t%s\n' "$build_owner" ;;
  0:0)
    echo "error: candidate build attempt has no durable exact evidence; refusing rebuild" >&2
    exit 2
    ;;
esac
