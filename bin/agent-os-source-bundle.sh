#!/usr/bin/env bash
set -eu

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(cd "${AGENT_OS_SOURCE_ROOT:-$SCRIPT_ROOT}" && pwd)
OUTPUT_DIR=${1:-"$ROOT/image"}
SOURCE_MODE=${AGENT_OS_SOURCE_MODE:-main}
SOURCE_BRANCH=main
SOURCE_ORIGIN=https://github.com/akua-dev/agent-os.git
SOURCE_REF=refs/heads/main
RELEASE_TAG=${AGENT_OS_SOURCE_RELEASE_TAG:-}
RELEASE_RECORD_COMMIT=${AGENT_OS_RELEASE_RECORD_COMMIT:-}
EVENT_COMMIT=${AGENT_OS_SOURCE_EVENT_COMMIT:-}
SOURCE_ARCHIVE="$OUTPUT_DIR/agent-os-source.tar"
BOOTSTRAP_ARCHIVE="$OUTPUT_DIR/agent-os-bootstrap.tar"
ATTESTATION="$OUTPUT_DIR/agent-os-source.attestation"
TEMP="$OUTPUT_DIR/.agent-os-source.$$"

git_isolated() {
  env -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    -u GIT_SSH -u GIT_SSH_COMMAND GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c core.hooksPath=/dev/null \
    -c http.proxy= -c https.proxy= "$@"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

[ "$(git_isolated -C "$ROOT" remote get-url origin)" = "$SOURCE_ORIGIN" ] || {
  echo "error: repository origin is not the exact trusted HTTPS origin" >&2
  exit 2
}
[ -z "$(git_isolated -C "$ROOT" status --porcelain --untracked-files=all)" ] || {
  echo "error: exact-source image builds require a clean worktree" >&2
  exit 2
}

mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP"
mkdir -p "$TEMP"
trap 'rm -rf "$TEMP" "$SOURCE_ARCHIVE.tmp.$$" "$BOOTSTRAP_ARCHIVE.tmp.$$" "$ATTESTATION.tmp.$$"' EXIT
git_isolated init --bare "$TEMP/bootstrap.git" >/dev/null

case "$SOURCE_MODE" in
  main)
    git_isolated --git-dir="$TEMP/bootstrap.git" fetch --depth=1 --no-tags "$SOURCE_ORIGIN" \
      refs/heads/main:refs/heads/main
    ;;
  event)
    [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [[ "$EVENT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
      echo "error: event source mode is restricted to an exact pull-request event commit" >&2
      exit 2
    }
    [ "$(git_isolated -C "$ROOT" rev-parse --verify HEAD)" = "$EVENT_COMMIT" ] || {
      echo "error: event checkout does not match the declared pull-request head" >&2
      exit 2
    }
    git_isolated -c protocol.file.allow=always --git-dir="$TEMP/bootstrap.git" fetch --depth=1 --no-tags \
      "file://$ROOT" "$EVENT_COMMIT:refs/heads/main"
    SOURCE_REF="event:$EVENT_COMMIT"
    ;;
  release)
    [[ "$RELEASE_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] && \
      [[ "$RELEASE_RECORD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
      echo "error: release mode requires a canonical semver tag and immutable record commit" >&2
      exit 2
    }
    command -v jq >/dev/null 2>&1 || { echo "error: jq is required for release records" >&2; exit 2; }
    git_isolated --git-dir="$TEMP/bootstrap.git" fetch --depth=1 --no-tags "$SOURCE_ORIGIN" \
      "$RELEASE_RECORD_COMMIT:refs/agent-os/release-record"
    git_isolated --git-dir="$TEMP/bootstrap.git" fetch --depth=1 --no-tags "$SOURCE_ORIGIN" \
      "refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
    [ "$(git_isolated --git-dir="$TEMP/bootstrap.git" cat-file -t "refs/tags/$RELEASE_TAG")" = tag ] || {
      echo "error: release tag must be annotated" >&2
      exit 2
    }
    git_isolated --git-dir="$TEMP/bootstrap.git" show "refs/agent-os/release-record:image/releases/$RELEASE_TAG.json" > "$TEMP/release.json"
    jq -e --arg tag "$RELEASE_TAG" '
      .tag == $tag and (.commit|test("^[0-9a-f]{40}$")) and (.tree|test("^[0-9a-f]{40}$")) and
      (.source_archive_sha256|test("^[0-9a-f]{64}$")) and (.package_sha256|test("^[0-9a-f]{64}$")) and
      (.schema_sha256|test("^[0-9a-f]{64}$")) and (.image_digest|test("^sha256:[0-9a-f]{64}$")) and
      (.sbom_sha256|test("^[0-9a-f]{64}$")) and (.provenance_sha256|test("^[0-9a-f]{64}$")) and
      (.quickstart_sha256|test("^[0-9a-f]{64}$")) and (.tag_ruleset_id|type == "number") and
      (.tag_ruleset_sha256|test("^[0-9a-f]{64}$"))' "$TEMP/release.json" >/dev/null || {
      echo "error: release record is incomplete or malformed" >&2
      exit 2
    }
    SOURCE_REF="refs/tags/$RELEASE_TAG"
    git_isolated --git-dir="$TEMP/bootstrap.git" update-ref refs/heads/main "refs/tags/$RELEASE_TAG^{}"
    ;;
  *) echo "error: unsupported source mode" >&2; exit 2 ;;
esac

SOURCE_COMMIT=$(git_isolated --git-dir="$TEMP/bootstrap.git" rev-parse --verify refs/heads/main)
SOURCE_TREE=$(git_isolated --git-dir="$TEMP/bootstrap.git" rev-parse --verify "$SOURCE_COMMIT^{tree}")
if [ "$SOURCE_MODE" = main ]; then
  [ "$(git_isolated -C "$ROOT" rev-parse --verify HEAD)" = "$SOURCE_COMMIT" ] && \
    [ "$(git_isolated -C "$ROOT" rev-parse --verify 'HEAD^{tree}')" = "$SOURCE_TREE" ] || {
    echo "error: local source does not exactly match the freshly fetched trusted source ref" >&2
    exit 2
  }
elif [ "$SOURCE_MODE" = release ]; then
  [ "$(jq -r .commit "$TEMP/release.json")" = "$SOURCE_COMMIT" ] && \
    [ "$(jq -r .tree "$TEMP/release.json")" = "$SOURCE_TREE" ] || {
    echo "error: release tag moved or differs from its immutable record" >&2
    exit 2
  }
fi

if [ "$SOURCE_MODE" = release ]; then
  git_isolated --git-dir="$TEMP/bootstrap.git" update-ref -d refs/agent-os/release-record
  git_isolated --git-dir="$TEMP/bootstrap.git" update-ref -d "refs/tags/$RELEASE_TAG"
  printf '%s\n' "$SOURCE_COMMIT" > "$TEMP/bootstrap.git/shallow"
  git_isolated --git-dir="$TEMP/bootstrap.git" reflog expire --expire=now --all
  git_isolated --git-dir="$TEMP/bootstrap.git" gc --prune=now
fi

git_isolated --git-dir="$TEMP/bootstrap.git" symbolic-ref HEAD refs/heads/main
git_isolated --git-dir="$TEMP/bootstrap.git" remote add origin "$SOURCE_ORIGIN"
rm -rf "$TEMP/bootstrap.git/hooks" "$TEMP/bootstrap.git/logs"
rm -f "$TEMP/bootstrap.git/FETCH_HEAD" "$TEMP/bootstrap.git/ORIG_HEAD"
git_isolated --git-dir="$TEMP/bootstrap.git" archive --format=tar --output="$SOURCE_ARCHIVE.tmp.$$" "$SOURCE_COMMIT"
if [ "$SOURCE_MODE" = release ]; then
  [ "$(sha256_file "$SOURCE_ARCHIVE.tmp.$$")" = "$(jq -r .source_archive_sha256 "$TEMP/release.json")" ] && \
    [ "$(git_isolated --git-dir="$TEMP/bootstrap.git" show "$SOURCE_COMMIT:tools/agent-os/packages/firstmate/package.k" | sha256_stream)" = "$(jq -r .package_sha256 "$TEMP/release.json")" ] && \
    [ "$(git_isolated --git-dir="$TEMP/bootstrap.git" show "$SOURCE_COMMIT:tools/agent-os/packages/firstmate/inputs.example.yaml" | sha256_stream)" = "$(jq -r .schema_sha256 "$TEMP/release.json")" ] && \
    [ "$(git_isolated --git-dir="$TEMP/bootstrap.git" show "$SOURCE_COMMIT:docs/kubernetes.md" | sha256_stream)" = "$(jq -r .quickstart_sha256 "$TEMP/release.json")" ] || {
    echo "error: release source artifacts differ from the immutable release record" >&2
    exit 2
  }
fi
(cd "$TEMP" && find bootstrap.git -exec touch -t 197001010000 {} + && \
  find bootstrap.git -print | LC_ALL=C sort | COPYFILE_DISABLE=1 tar -cf "$BOOTSTRAP_ARCHIVE.tmp.$$" -T -)
SOURCE_SHA=$(sha256_file "$SOURCE_ARCHIVE.tmp.$$")
BOOTSTRAP_SHA=$(sha256_file "$BOOTSTRAP_ARCHIVE.tmp.$$")
{
  printf 'mode=%s\ncommit=%s\ntree=%s\nbranch=%s\norigin=%s\nref=%s\n' \
    "$SOURCE_MODE" "$SOURCE_COMMIT" "$SOURCE_TREE" "$SOURCE_BRANCH" "$SOURCE_ORIGIN" "$SOURCE_REF"
  printf 'source_sha256=%s\nbootstrap_sha256=%s\n' "$SOURCE_SHA" "$BOOTSTRAP_SHA"
  if [ "$SOURCE_MODE" = release ]; then
    printf 'release_record_commit=%s\nrelease_record_sha256=%s\n' \
      "$RELEASE_RECORD_COMMIT" "$(sha256_file "$TEMP/release.json")"
  fi
} > "$ATTESTATION.tmp.$$"
mv "$SOURCE_ARCHIVE.tmp.$$" "$SOURCE_ARCHIVE"
mv "$BOOTSTRAP_ARCHIVE.tmp.$$" "$BOOTSTRAP_ARCHIVE"
mv "$ATTESTATION.tmp.$$" "$ATTESTATION"
trap - EXIT
rm -rf "$TEMP"
cat "$ATTESTATION"
