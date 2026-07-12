# Local Root Agents and Persistent Toolchain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run every local Agent OS Pod as container root while providing Firstmate's complete baseline toolchain and preserving runtime-installed tools across Pod replacement.

**Architecture:** Extend the reproducible image with exact binary and npm package versions, then seed the image's `/usr/local` tree into each agent PVC from an init container. The main container mounts that tree at `/usr/local`, uses the same PVC for `/home/agent`, and runs as UID 0 on the isolated local OrbStack VM node.

**Tech Stack:** Docker, Bash, Kubernetes v1.34, Kustomize, StatefulSet, Pods, PVCs, Herdr, Pi, Node.js, npm.

## Global Constraints

- Every primary and crewmate Pod sets `runAsUser: 0` and `runAsGroup: 0`.
- OrbStack's unsupported `hostUsers: false` field is omitted from this isolated local demo.
- The primary retains the existing local-demo `cluster-admin` ServiceAccount binding, while crewmates receive no Kubernetes credentials by default.
- No Pod uses privileged mode, host PID, host IPC, host networking, raw block devices, or host-path mounts.
- Each agent has its own PVC-backed `/home/agent` and `/usr/local`; no persistent state is shared between agents.
- Runtime additions in `/usr/local` and persistent home prefixes survive Pod replacement.
- Runtime `apt` changes outside the persistent prefixes remain intentionally ephemeral.
- Host model and GitHub credentials never enter the image or Docker build context.
- Host Kubernetes commands always pin `--context orbstack`.
- Use TDD for every behavior change and run `bin/fm-lint.sh` before shipping.
- Do not run no-mistakes unless the captain asks for it again.

---

### Task 1: Complete the reproducible image toolchain

**Files:**
- Modify: `Dockerfile`
- Modify: `tests/agent-os-container.test.sh`

**Interfaces:**
- Consumes: Docker BuildKit `TARGETARCH` values `amd64` and `arm64`.
- Produces: image commands `gh`, `rg`, `fd`, `treehouse`, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, and `quota-axi`.

- [ ] **Step 1: Add failing static pin assertions**

Add these assertions to `tests/agent-os-container.test.sh`:

```bash
assert_grep 'ARG GH_VERSION=2.96.0' "$ROOT/Dockerfile" "image must pin GitHub CLI 2.96.0"
assert_grep 'ARG TREEHOUSE_VERSION=2.0.0' "$ROOT/Dockerfile" "image must pin treehouse 2.0.0"
assert_grep 'ARG NO_MISTAKES_VERSION=1.34.0' "$ROOT/Dockerfile" "image must pin no-mistakes 1.34.0"
assert_grep 'gh-axi@0.1.27' "$ROOT/Dockerfile" "image must pin gh-axi 0.1.27"
assert_grep 'chrome-devtools-axi@0.1.26' "$ROOT/Dockerfile" "image must pin chrome-devtools-axi 0.1.26"
assert_grep 'lavish-axi@0.1.40' "$ROOT/Dockerfile" "image must pin lavish-axi 0.1.40"
assert_grep 'tasks-axi@0.2.2' "$ROOT/Dockerfile" "image must pin tasks-axi 0.2.2"
assert_grep 'quota-axi@0.1.5' "$ROOT/Dockerfile" "image must pin quota-axi 0.1.5"
assert_grep 'ripgrep' "$ROOT/Dockerfile" "image must install ripgrep"
assert_grep 'fd-find' "$ROOT/Dockerfile" "image must install fd"
```

- [ ] **Step 2: Run the test and observe the missing pins**

Run: `bash tests/agent-os-container.test.sh`

Expected: FAIL at `image must pin GitHub CLI 2.96.0`.

- [ ] **Step 3: Install the Debian and exact npm baseline**

Add `fd-find`, `ripgrep`, and `rsync` to the existing apt package list.
Create `/usr/local/bin/fd` as a symlink to `/usr/bin/fdfind`.
Replace the existing Pi-only npm install with this exact install:

```dockerfile
RUN npm install --global \
  @earendil-works/pi-coding-agent@0.80.6 \
  gh-axi@0.1.27 \
  chrome-devtools-axi@0.1.26 \
  lavish-axi@0.1.40 \
  tasks-axi@0.2.2 \
  quota-axi@0.1.5
```

- [ ] **Step 4: Install checksum-verified GitHub CLI**

Add `ARG GH_VERSION=2.96.0` and a `RUN` block that downloads `gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz`, verifies the architecture checksum, and copies `bin/gh` into `/usr/local/bin`.
Use these checksums:

```text
amd64 83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60
arm64 06f86ec7103d41993b76cd78072f43595c34aaa56506d971d9860e67140bf909
```

- [ ] **Step 5: Install checksum-verified treehouse and no-mistakes**

Add `ARG TREEHOUSE_VERSION=2.0.0` and `ARG NO_MISTAKES_VERSION=1.34.0`.
Download the matching Linux tarball for `TARGETARCH`, verify it, and install its binary into `/usr/local/bin`.
Use these checksums:

```text
treehouse amd64 b7926c19633ee94582b7f1b58369f22b304ae7228a47253c2148e3a8176f03b0
treehouse arm64 91bca451bab84df685ee17975c8a9d8cf671b3e95c96b7fc6ff0121ea0aae991
no-mistakes amd64 449d0276e1b35369ea332dae0eddb5be326c2d4fc9643270af98858cf3906536
no-mistakes arm64 f157df3e18350edea8abdaa065681bd115a9d321fca86f51e9a0184b3a9d8756
```

- [ ] **Step 6: Run static tests**

Run: `bash tests/agent-os-container.test.sh`

Expected: PASS with `container files pin dependencies and exclude host credentials`.

- [ ] **Step 7: Build and verify every baseline command**

Run:

```bash
bin/agent-os-local.sh build
docker run --rm --entrypoint bash agent-os:dev -lc '
  for tool in bash curl git ssh jq tmux ps rsync gh rg fd node npm pi herdr kubectl treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do
    command -v "$tool" || exit 1
  done
  FM_HOME=/tmp/fm HOME=/tmp/fm mkdir -p /tmp/fm/config /tmp/fm/data /tmp/fm/state
  FM_HOME=/tmp/fm HOME=/tmp/fm FM_BOOTSTRAP_DETECT_ONLY=1 /opt/agent-os/bin/fm-bootstrap.sh | grep "^MISSING:" && exit 1 || true
'
```

Expected: every command resolves and bootstrap emits no `MISSING:` line.

- [ ] **Step 8: Commit the image baseline**

```bash
git add Dockerfile tests/agent-os-container.test.sh
git commit -m "feat: bundle the Firstmate toolchain"
```

---

### Task 2: Add the persistent-prefix initializer

**Files:**
- Create: `bin/agent-os-init.sh`
- Create: `tests/agent-os-init.test.sh`
- Modify: `Dockerfile`
- Modify: `bin/agent-os-container-entrypoint.sh`

**Interfaces:**
- Consumes: `AGENT_OS_PERSISTENT_ROOT`, defaulting to `/persistent-agent`, and `AGENT_OS_IMAGE_USR_LOCAL`, defaulting to `/opt/image-usr-local`.
- Produces: a PVC root used as `/home/agent` and a seeded `$AGENT_OS_PERSISTENT_ROOT/usr-local`.

- [ ] **Step 1: Write failing initializer tests**

Create `tests/agent-os-init.test.sh` with image-baseline and runtime-added fixtures:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot agent-os-init)
mkdir -p "$TMP/source/bin" "$TMP/persistent/.local/bin" "$TMP/persistent/usr-local/bin"
printf 'baseline\n' > "$TMP/source/bin/baseline"
printf 'runtime\n' > "$TMP/persistent/usr-local/bin/runtime-added"

AGENT_OS_IMAGE_USR_LOCAL="$TMP/source" \
AGENT_OS_PERSISTENT_ROOT="$TMP/persistent" \
  "$ROOT/bin/agent-os-init.sh"

assert_grep baseline "$TMP/persistent/usr-local/bin/baseline" "initializer must seed image tools"
assert_grep runtime "$TMP/persistent/usr-local/bin/runtime-added" "initializer must preserve runtime tools"

pass "initializer preserves image and runtime-installed tools"
```

- [ ] **Step 2: Run the test and observe the missing initializer**

Run: `bash tests/agent-os-init.test.sh`

Expected: FAIL because `bin/agent-os-init.sh` does not exist.

- [ ] **Step 3: Implement the initializer**

Create `bin/agent-os-init.sh` as a strict Bash script.
Read three integers from the first UID-map row.
Require inside UID `0`, outside UID greater than `0`, and range at least `65536`.
Create persistent `.config`, `.cache`, `.local/bin`, `.local/share`, `.bun`, `.cargo`, and `usr-local` directories below the PVC root.
Copy the image baseline with `rsync -a "$IMAGE_USR_LOCAL/" "$PERSISTENT_ROOT/usr-local/"` and do not pass `--delete`.

- [ ] **Step 4: Configure persistent package-manager paths**

In `Dockerfile`, set:

```dockerfile
ENV FM_HOME=/home/agent \
    HOME=/home/agent \
    XDG_CONFIG_HOME=/home/agent/.config \
    XDG_DATA_HOME=/home/agent/.local/share \
    XDG_CACHE_HOME=/home/agent/.cache \
    NPM_CONFIG_PREFIX=/usr/local \
    BUN_INSTALL=/home/agent/.bun \
    CARGO_HOME=/home/agent/.cargo \
    PATH=/home/agent/.local/bin:/home/agent/.bun/bin:/home/agent/.cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    HERDR_SESSION=default
```

Remove `USER node` and create `/opt/image-usr-local` as a snapshot of the built `/usr/local` tree before runtime mounts hide it.

- [ ] **Step 5: Make runtime setup persistent and idempotent**

Update `bin/agent-os-container-entrypoint.sh` to create persistent XDG, local-bin, Bun, and Cargo directories.
After the Herdr backend configuration, install the three AXI SessionStart hooks into persistent HOME only when their marker is absent:

```bash
for tool in gh-axi chrome-devtools-axi lavish-axi; do
  marker="$HOME/.config/agent-os/setup-$tool"
  if [ ! -e "$marker" ]; then
    "$tool" setup hooks
    mkdir -p "$(dirname "$marker")"
    : > "$marker"
  fi
done
```

- [ ] **Step 6: Run initializer and container tests**

Run:

```bash
bash tests/agent-os-init.test.sh
bash tests/agent-os-container.test.sh
bash -n bin/agent-os-init.sh bin/agent-os-container-entrypoint.sh
```

Expected: all tests pass and Bash reports no syntax errors.

- [ ] **Step 7: Commit the persistent initializer**

```bash
git add Dockerfile bin/agent-os-init.sh bin/agent-os-container-entrypoint.sh tests/agent-os-init.test.sh
git commit -m "feat: persist agent-installed tools"
```

---

### Task 3: Run primary and crewmates as local container root

**Files:**
- Modify: `deploy/orbstack/primary.yaml`
- Modify: `bin/agent-os-crewmate.sh`
- Modify: `tests/agent-os-kubernetes.test.sh`

**Interfaces:**
- Consumes: image path `/opt/image-usr-local` and per-agent PVC.
- Produces: Pod specs with root security context, init container `agent-os-init`, whole-PVC home mount, and `usr-local` subPath mount.

- [ ] **Step 1: Add failing manifest assertions**

Extend `tests/agent-os-kubernetes.test.sh` for both rendered primary YAML and captured child YAML:

```bash
assert_not_contains "$rendered" 'hostUsers: false' "OrbStack demo must not request unsupported Pod user namespaces"
assert_contains "$rendered" 'runAsUser: 0' "primary must run as container root"
assert_contains "$rendered" 'name: agent-os-init' "primary must seed persistent tools"
assert_contains "$rendered" 'mountPath: /usr/local' "primary must persist /usr/local"
assert_no_grep 'hostUsers: false' "$STDIN_LOG" "OrbStack children must not request unsupported Pod user namespaces"
assert_grep 'runAsUser: 0' "$STDIN_LOG" "children must run as container root"
assert_grep 'name: agent-os-init' "$STDIN_LOG" "children must seed persistent tools"
assert_grep 'mountPath: /usr/local' "$STDIN_LOG" "children must persist /usr/local"
```

Retain the existing assertion for `automountServiceAccountToken: false`.

- [ ] **Step 2: Run the Kubernetes test and observe failure**

Run: `bash tests/agent-os-kubernetes.test.sh`

Expected: FAIL while the manifest still requests unsupported Pod user namespaces.

- [ ] **Step 3: Update the primary StatefulSet**

Replace the non-root security context with `runAsUser: 0` and `runAsGroup: 0`.
Add an `agent-os-init` init container using `agent-os:dev`, command `/opt/agent-os/bin/agent-os-init.sh`, and a whole-PVC mount at `/persistent-agent`.
Mount the PVC root at `/home/agent` and PVC subPath `usr-local` at `/usr/local` in the main container.
Do not set `privileged: true` or any host namespace option.

- [ ] **Step 4: Update generated crewmate Pods**

Make `bin/agent-os-crewmate.sh create` emit the same root, init-container, home, and `/usr/local` structure.
Keep the distinct child PVC and `automountServiceAccountToken: false` contract unchanged.

- [ ] **Step 5: Run static Kubernetes tests**

Run:

```bash
bash tests/agent-os-kubernetes.test.sh
kubectl kustomize deploy/orbstack >/dev/null
bash -n bin/agent-os-crewmate.sh
```

Expected: all checks pass.

- [ ] **Step 6: Commit the Pod model**

```bash
git add deploy/orbstack/primary.yaml bin/agent-os-crewmate.sh tests/agent-os-kubernetes.test.sh
git commit -m "feat: run local agents as container root"
```

---

### Task 4: Prove the live root and persistent tool lifecycle

**Files:**
- Modify if evidence reveals a defect: files owned by Tasks 1 through 3 and their colocated tests.

**Interfaces:**
- Consumes: OrbStack context, `agent-os:dev`, namespace `agent-os-demo`.
- Produces: empirical proof for container root, baseline completeness, and durable runtime tools.

- [ ] **Step 1: Rebuild and deploy**

Run:

```bash
bin/agent-os-local.sh build
bin/agent-os-local.sh deploy
kubectl --context orbstack -n agent-os-demo rollout status statefulset/agent-os-firstmate --timeout=180s
```

Expected: the StatefulSet reaches `1/1` Ready.

- [ ] **Step 2: Verify container root**

Run:

```bash
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- id
```

Expected: `id` reports UID 0.

- [ ] **Step 3: Verify the complete baseline**

Run:

```bash
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- bash -lc '
  for tool in gh rg fd treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do command -v "$tool" || exit 1; done
  FM_BOOTSTRAP_DETECT_ONLY=1 /opt/agent-os/bin/fm-bootstrap.sh | tee /tmp/bootstrap.out
  ! grep -q "^MISSING:" /tmp/bootstrap.out
'
```

Expected: all tools resolve and bootstrap reports `NEEDS_GH_AUTH` but no missing tool.

- [ ] **Step 4: Add persistent runtime tools**

Run:

```bash
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- bash -lc '
  printf "#!/bin/sh\necho home-persisted\n" > /home/agent/.local/bin/home-proof
  printf "#!/bin/sh\necho usr-local-persisted\n" > /usr/local/bin/usr-local-proof
  chmod +x /home/agent/.local/bin/home-proof /usr/local/bin/usr-local-proof
'
```

Expected: both writes succeed as container root.

- [ ] **Step 5: Replace the primary Pod and prove persistence**

Run:

```bash
kubectl --context orbstack -n agent-os-demo delete pod agent-os-firstmate-0 --wait=true
kubectl --context orbstack -n agent-os-demo rollout status statefulset/agent-os-firstmate --timeout=180s
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- home-proof
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- usr-local-proof
```

Expected: output is `home-persisted` and `usr-local-persisted`.

- [ ] **Step 6: Prove a root crewmate remains Kubernetes-unprivileged**

Run:

```bash
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- /opt/agent-os/bin/agent-os-crewmate.sh create root-proof
kubectl --context orbstack -n agent-os-demo wait --for=condition=Ready pod/agent-os-crewmate-root-proof --timeout=180s
kubectl --context orbstack -n agent-os-demo exec agent-os-crewmate-root-proof -- id
kubectl --context orbstack -n agent-os-demo exec agent-os-crewmate-root-proof -- test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- /opt/agent-os/bin/agent-os-crewmate.sh delete root-proof
```

Expected: child UID 0 is active, no ServiceAccount token exists, and cleanup removes its Pod and PVC.

- [ ] **Step 7: Convert any live defect into a failing test before fixing it**

For each failure, add the smallest regression assertion to the owning test, run it to observe failure, implement the fix, and rerun Tasks 1 through 3 tests.

- [ ] **Step 8: Commit live-proof fixes if needed**

```bash
git add Dockerfile bin deploy tests
git diff --cached --quiet || git commit -m "fix: complete the persistent root agent runtime"
```

---

### Task 5: Document, validate, and update the review branch

**Files:**
- Modify: `docs/kubernetes.md`
- Modify: `README.md` only if the current Kubernetes summary becomes inaccurate.

**Interfaces:**
- Consumes: verified runtime behavior from Task 4.
- Produces: operator guidance for root isolation, persistent installs, authentication, and known ephemeral paths.

- [ ] **Step 1: Update the Kubernetes guide**

Document these verified facts in `docs/kubernetes.md`, one sentence per physical line:

```text
Agents run as UID 0 on the isolated local OrbStack VM node.
The complete Firstmate baseline is part of the image.
Tools installed below /home/agent persistent prefixes or /usr/local survive Pod replacement.
apt remains available, but files it writes outside persistent prefixes are ephemeral.
GitHub and model authentication live on the individual agent PVC.
The Pods do not use privileged mode, host namespaces, or host mounts.
```

- [ ] **Step 2: Run the complete focused verification set**

Run:

```bash
bash tests/agent-os-local.test.sh
bash tests/agent-os-container.test.sh
bash tests/agent-os-init.test.sh
bash tests/agent-os-kubernetes.test.sh
for script in bin/agent-os-*.sh; do bash -n "$script"; done
git diff --check
bin/fm-lint.sh
```

Expected: all tests pass, `git diff --check` is silent, and `fm-lint.sh` exits zero.

- [ ] **Step 3: Commit documentation**

```bash
git add docs/kubernetes.md README.md
git diff --cached --quiet || git commit -m "docs: explain persistent root agents"
```

- [ ] **Step 4: Verify clean committed state**

Run:

```bash
git status --short --branch
git log --oneline origin/feat/orbstack-demo..HEAD
```

Expected: no uncommitted files and only the approved spec, plan, and implementation commits are ahead of the remote branch.

- [ ] **Step 5: Push the existing review branch**

Run: `git push origin feat/orbstack-demo`

Expected: GitHub updates pull request <https://github.com/akua-dev/agent-os/pull/1>.
