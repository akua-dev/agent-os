#!/usr/bin/env bash
set -eu

attempt_state=${1:?attempt state is required}
evidence_state=${2:?evidence state is required}
claim_state=${3:?claim state is required}

case "$claim_state" in
  exact) ;;
  missing|mismatched|unreadable|ambiguous)
    echo "error: candidate claim state is not exact: $claim_state" >&2
    exit 2
    ;;
  *)
    echo "error: unsupported candidate claim state: $claim_state" >&2
    exit 2
    ;;
esac

case "$attempt_state" in
  absent|attempted) ;;
  corrupt|mismatched|unreadable|metadata-read-error|partial|ambiguous)
    echo "error: candidate attempt state is not exact: $attempt_state" >&2
    exit 2
    ;;
  *)
    echo "error: unsupported candidate attempt state: $attempt_state" >&2
    exit 2
    ;;
esac

case "$evidence_state" in
  exact-record)
    [ "$attempt_state" = attempted ] || {
      echo "error: exact candidate record has no owner-bound build attempt" >&2
      exit 2
    }
    printf 'reuse-record\n'
    ;;
  exact-build)
    [ "$attempt_state" = attempted ] || {
      echo "error: exact candidate build has no owner-bound build attempt" >&2
      exit 2
    }
    printf 'reuse-build\n'
    ;;
  absent)
    [ "$attempt_state" = absent ] || {
      echo "error: candidate build attempt has no durable exact evidence; refusing rebuild" >&2
      exit 2
    }
    printf 'build\n'
    ;;
  corrupt|mismatched|unreadable|metadata-read-error|partial|ambiguous)
    echo "error: candidate evidence state is not exact: $evidence_state" >&2
    exit 2
    ;;
  *)
    echo "error: unsupported candidate evidence state: $evidence_state" >&2
    exit 2
    ;;
esac
