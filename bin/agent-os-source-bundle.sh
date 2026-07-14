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
GIT_BIN=/usr/bin/git
[ -x "$GIT_BIN" ] || { echo "error: trusted Git executable is unavailable" >&2; exit 2; }

git_isolated() {
  env -i HOME=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    "$GIT_BIN" -c credential.helper= -c core.hooksPath=/dev/null \
    -c http.proxy= -c https.proxy= "$@"
}

canonical_github_origin() {
  case "$1" in
    https://github.com/akua-dev/agent-os|https://github.com/akua-dev/agent-os.git)
      printf '%s' "$SOURCE_ORIGIN"
      ;;
    *) return 1 ;;
  esac
}

validate_source_git_config() {
  local key value origin worktree_config worktree_config_enabled worktree_keys
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value=$(git_isolated -C "$ROOT" config --local --no-includes --get-all "$key" || true)
    [ -n "$value" ] && [ "$value" = "$(printf '%s\n' "$value" | head -n 1)" ] || {
      echo "error: source repository Git config key is duplicated or empty" >&2
      exit 2
    }
    case "$key" in
      core.repositoryformatversion) [ "$value" = 0 ] ;;
      core.filemode|core.ignorecase|core.precomposeunicode|core.logallrefupdates|core.bare)
        [ "$value" = true ] || [ "$value" = false ]
        ;;
      extensions.worktreeconfig|receive.advertisepushoptions)
        [ "$value" = true ] || [ "$value" = false ]
        ;;
      gc.auto) [ "$value" = 0 ] ;;
      maintenance.auto) [ "$value" = false ] ;;
      remote.origin.url) canonical_github_origin "$value" >/dev/null ;;
      remote.origin.fetch) [ "$value" = '+refs/heads/*:refs/remotes/origin/*' ] ;;
      remote.origin.tagopt) [ "$value" = --no-tags ] ;;
      branch.main.remote) [ "$value" = origin ] ;;
      branch.main.merge) [ "$value" = refs/heads/main ] ;;
      *) echo "error: source repository Git config key is not allowlisted: $key" >&2; exit 2 ;;
    esac || { echo "error: source repository Git config value is invalid: $key" >&2; exit 2; }
  done < <(git_isolated -C "$ROOT" config --local --no-includes --name-only --list)
  worktree_config_enabled=$(git_isolated -C "$ROOT" config --local --type=bool --get extensions.worktreeconfig || true)
  if [ "$worktree_config_enabled" = true ]; then
    worktree_config=$(git_isolated -C "$ROOT" rev-parse --path-format=absolute --git-path config.worktree)
    if [ -f "$worktree_config" ]; then
      worktree_keys=$(git_isolated config --file "$worktree_config" --no-includes --name-only --list)
      [ -z "$worktree_keys" ] || {
        echo "error: source repository worktree Git config is not allowed" >&2
        exit 2
      }
    fi
  fi
  origin=$(git_isolated -C "$ROOT" config --local --no-includes --get remote.origin.url || true)
  [ "$(canonical_github_origin "$origin" 2>/dev/null || true)" = "$SOURCE_ORIGIN" ] || {
    echo "error: repository origin is not the exact trusted HTTPS origin" >&2
    exit 2
  }
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

validate_source_git_config
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
  main|candidate)
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
      (.bootstrap_archive_sha256|test("^[0-9a-f]{64}$")) and
      (.schema_sha256|test("^[0-9a-f]{64}$")) and (.image_digest|test("^sha256:[0-9a-f]{64}$")) and
      (.sbom_sha256|test("^[0-9a-f]{64}$")) and (.provenance_sha256|test("^[0-9a-f]{64}$")) and
      (.buildkit_outputs_sha256|test("^[0-9a-f]{64}$")) and
      (.platform_manifests_sha256|test("^[0-9a-f]{64}$")) and
      (.candidate_record_digest|test("^sha256:[0-9a-f]{64}$")) and
      .source_mode == "candidate" and
      .image_repository == "ghcr.io/akua-dev/agent-os" and
      (.platform_manifests|type == "array" and length == 2) and
      ([.platform_manifests[].platform] | sort == ["linux/amd64","linux/arm64"]) and
      (all(.platform_manifests[]; (.digest|test("^sha256:[0-9a-f]{64}$")) and
        (.mediaType|type == "string" and length > 0) and (.size|type == "number" and . > 0))) and
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
if [ "$SOURCE_MODE" = candidate ]; then
  SOURCE_REF="refs/agent-os/candidates/$SOURCE_COMMIT"
fi
if [ "$SOURCE_MODE" = main ] || [ "$SOURCE_MODE" = candidate ]; then
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

git_isolated init --bare "$TEMP/sanitized.git" >/dev/null
git_isolated -c protocol.file.allow=always --git-dir="$TEMP/sanitized.git" fetch --depth=1 --no-tags \
  "file://$TEMP/bootstrap.git" "$SOURCE_COMMIT:refs/heads/main"
rm -rf "$TEMP/bootstrap.git"
mv "$TEMP/sanitized.git" "$TEMP/bootstrap.git"

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
if [ "$SOURCE_MODE" = release ] && [ "$BOOTSTRAP_SHA" != "$(jq -r .bootstrap_archive_sha256 "$TEMP/release.json")" ]; then
  echo "error: bootstrap archive differs from the immutable release record" >&2
  exit 2
fi
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
