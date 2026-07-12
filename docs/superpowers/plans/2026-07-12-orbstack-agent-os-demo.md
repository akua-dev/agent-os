# OrbStack Agent OS Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package this Firstmate fork as a persistent Kubernetes-native Agent OS demo that runs on OrbStack and can launch one isolated crewmate Pod.

**Architecture:** Keep Firstmate's supervision and Herdr backend unchanged. Add one OCI image, one namespace-scoped manifest set, and thin Bash CLIs that always target an explicit Kubernetes context. The trusted primary Pod gets cluster-admin only for the local demo; crewmate Pods get no service-account token and keep work on their own PVC.

**Tech Stack:** Bash, Docker, Kubernetes YAML, Kustomize, OrbStack Kubernetes, Herdr 0.7.3, Node.js 24, Pi 0.80.6.

## Global Constraints

- Every host-side `kubectl` command must pass `--context`, defaulting to `orbstack`.
- The demo namespace is exactly `agent-os-demo`; scripts must not enumerate, mutate, or delete unrelated namespaces.
- No host model credentials, kubeconfigs, Git credentials, or home directories may enter the image build context.
- The primary home is a PVC mounted at `/home/agent`; each crewmate gets a different PVC.
- Herdr remains an unmodified separate AGPL executable and must ship with its license and exact source link.
- Firstmate remains usable outside Kubernetes; no existing backend contract is replaced.
- Tests use fake `docker`, `kubectl`, and `orbctl` commands and run before any live mutation.

---

### Task 1: Guarded local bootstrap CLI

**Files:**
- Create: `tests/agent-os-local.test.sh`
- Create: `bin/agent-os-local.sh`

**Interfaces:**
- Consumes: `docker`, `kubectl`, and optional `orbctl` executables from `PATH`.
- Produces: `bin/agent-os-local.sh build|deploy|status|shell|attach|destroy` and environment variables `AGENT_OS_CONTEXT`, `AGENT_OS_NAMESPACE`, and `AGENT_OS_IMAGE`.

- [ ] **Step 1: Write the failing CLI test**

Create a fake-tool directory that appends every invocation to a log, run `status`, `deploy`, and `destroy`, and assert the exact safety contract:

```bash
PATH="$fakebin:$PATH" AGENT_OS_TEST_LOG="$log" bin/agent-os-local.sh status
grep -F 'kubectl --context orbstack -n agent-os-demo get statefulset agent-os-firstmate' "$log"

PATH="$fakebin:$PATH" AGENT_OS_TEST_LOG="$log" bin/agent-os-local.sh deploy
grep -F 'kubectl --context orbstack apply -k deploy/orbstack' "$log"

if PATH="$fakebin:$PATH" bin/agent-os-local.sh destroy 2>/dev/null; then
  fail "destroy must require --yes"
fi
```

Also assert that `AGENT_OS_CONTEXT=minekube-prod` is rejected unless `AGENT_OS_ALLOW_NON_ORBSTACK=1`, and that no command omits `--context`.

- [ ] **Step 2: Run the test to verify RED**

Run: `bash tests/agent-os-local.test.sh`

Expected: FAIL because `bin/agent-os-local.sh` does not exist.

- [ ] **Step 3: Implement the minimal guarded CLI**

Implement strict Bash with these command mappings:

```bash
build) docker build -t "$IMAGE" . ;;
deploy) kubectl --context "$CONTEXT" apply -k deploy/orbstack ;;
status) kubectl --context "$CONTEXT" -n "$NAMESPACE" get statefulset agent-os-firstmate ;;
shell) kubectl --context "$CONTEXT" -n "$NAMESPACE" exec -it statefulset/agent-os-firstmate -- bash ;;
attach) kubectl --context "$CONTEXT" -n "$NAMESPACE" exec -it statefulset/agent-os-firstmate -- herdr ;;
destroy) [ "${2:-}" = --yes ] || exit 2; kubectl --context "$CONTEXT" delete namespace "$NAMESPACE" ;;
```

`deploy` may call `orbctl start k8s` only when the context is `orbstack`; it must then wait with `kubectl --context orbstack wait --for=condition=Ready node/orbstack --timeout=120s`.

- [ ] **Step 4: Run the test to verify GREEN**

Run: `bash tests/agent-os-local.test.sh`

Expected: all assertions print `ok` and exit 0.

### Task 2: Reproducible container and persistent primary

**Files:**
- Create: `tests/agent-os-container.test.sh`
- Create: `.dockerignore`
- Create: `Dockerfile`
- Create: `bin/agent-os-container-entrypoint.sh`
- Create: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Consumes: repository source as Docker build context.
- Produces: image `agent-os:dev`, `/opt/agent-os`, persistent `FM_HOME=/home/agent`, Herdr server as PID 1, Pi on `PATH`.

- [ ] **Step 1: Write the failing static container test**

Assert:

```bash
grep -F 'FROM node:24-bookworm-slim' Dockerfile
grep -F 'HERDR_VERSION=0.7.3' Dockerfile
grep -F '@earendil-works/pi-coding-agent@0.80.6' Dockerfile
grep -F 'FM_HOME=/home/agent' Dockerfile
grep -F 'exec herdr server' bin/agent-os-container-entrypoint.sh
grep -F '.git' .dockerignore
grep -F '.pi' .dockerignore
grep -F 'https://github.com/ogulcancelik/herdr/tree/v0.7.3' THIRD_PARTY_NOTICES.md
```

Also assert `bash -n bin/agent-os-container-entrypoint.sh` succeeds.

- [ ] **Step 2: Run the test to verify RED**

Run: `bash tests/agent-os-container.test.sh`

Expected: FAIL on the first missing file.

- [ ] **Step 3: Implement the image and entrypoint**

Use `node:24-bookworm-slim`, install only `bash`, `ca-certificates`, `curl`, `git`, `jq`, `openssh-client`, `procps`, and `tmux`, and download the architecture-specific Herdr 0.7.3 release binary.
Install Pi at the exact package version.
Copy the repository to `/opt/agent-os`.
The entrypoint must create `$FM_HOME/config`, write `herdr` to `config/backend` only when absent, set `HOME=$FM_HOME`, and execute `herdr server` without copying any credentials.

- [ ] **Step 4: Run static tests and build the image**

Run:

```bash
bash tests/agent-os-container.test.sh
docker build -t agent-os:dev .
docker run --rm --entrypoint bash agent-os:dev -lc 'herdr version && pi --version && test -x /opt/agent-os/bin/fm-spawn.sh'
```

Expected: static test exits 0, image builds, Herdr reports 0.7.3, Pi reports 0.80.6, and the Firstmate toolbelt exists.

### Task 3: Kubernetes manifests and isolated crewmate launcher

**Files:**
- Create: `tests/agent-os-kubernetes.test.sh`
- Create: `deploy/orbstack/kustomization.yaml`
- Create: `deploy/orbstack/namespace.yaml`
- Create: `deploy/orbstack/rbac.yaml`
- Create: `deploy/orbstack/primary.yaml`
- Create: `bin/agent-os-crewmate.sh`
- Create: `.agents/skills/kubernetes-fleet/SKILL.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: image `agent-os:dev`, explicit `kubectl` context on a host or in-cluster service-account configuration in the primary Pod.
- Produces: namespace `agent-os-demo`, StatefulSet `agent-os-firstmate`, PVC `agent-os-firstmate-home`, and `bin/agent-os-crewmate.sh create|status|delete <id>`.

- [ ] **Step 1: Write failing manifest and launcher tests**

Assert rendered Kustomize output contains:

```text
Namespace/agent-os-demo
ServiceAccount/agent-os-firstmate
ClusterRoleBinding/agent-os-firstmate-local-demo
PersistentVolumeClaim/agent-os-firstmate-home
StatefulSet/agent-os-firstmate
imagePullPolicy: Never
```

Use a fake `kubectl` to assert `agent-os-crewmate.sh create scout-1` applies exactly one PVC and one Pod in `agent-os-demo`, labels both with `agent-os.akua.dev/crewmate=scout-1`, sets `automountServiceAccountToken: false`, and refuses IDs outside `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`.

- [ ] **Step 2: Run tests to verify RED**

Run: `bash tests/agent-os-kubernetes.test.sh`

Expected: FAIL because the manifests and launcher do not exist.

- [ ] **Step 3: Implement manifests and launcher**

The primary StatefulSet must mount the PVC at `/home/agent`, run as UID/GID 1000, request `500m` CPU and `1Gi` memory, limit at `4` CPU and `8Gi`, and use the dedicated ServiceAccount.
The local-demo ClusterRoleBinding may grant `cluster-admin` only to `system:serviceaccount:agent-os-demo:agent-os-firstmate` and must include a comment that production installations need a reviewed narrower role.
The crewmate launcher creates a separate PVC mounted at `/home/agent`, reuses `agent-os:dev`, and disables service-account token automount.

- [ ] **Step 4: Add the conditional operating skill**

Add a focused internal skill that tells Firstmate to use the launcher only when it is running in Kubernetes, keep children general-purpose, communicate parent-to-child through terminals/files, preserve unique work on the child PVC, and never claim the local-demo RBAC is production-safe.
Add exactly one trigger line to `AGENTS.md` section 13: load the skill before creating, supervising, recovering, or deleting Kubernetes crewmates.

- [ ] **Step 5: Run tests to verify GREEN**

Run:

```bash
bash tests/agent-os-kubernetes.test.sh
for script in bin/agent-os-*.sh; do bash -n "$script"; done
kubectl kustomize deploy/orbstack >/tmp/agent-os-rendered.yaml
```

Expected: all tests exit 0 and rendering succeeds.

### Task 4: Live OrbStack proof and concise documentation

**Files:**
- Create: `docs/kubernetes.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1-3 and an active OrbStack Kubernetes context.
- Produces: reproducible local-demo commands and empirical proof of primary/child persistence.

- [ ] **Step 1: Document only the verified local path**

Document `build`, `deploy`, `status`, `shell`, `attach`, crewmate create/status/delete, and `destroy --yes`.
State that no credentials are copied automatically and that the user launches Pi from `/opt/agent-os` after authenticating inside the persistent home.
Add one concise README link; keep mechanism detail in `docs/kubernetes.md`.

- [ ] **Step 2: Deploy to OrbStack**

Run:

```bash
bin/agent-os-local.sh build
bin/agent-os-local.sh deploy
kubectl --context orbstack -n agent-os-demo rollout status statefulset/agent-os-firstmate --timeout=180s
```

Expected: the StatefulSet has one Ready replica.

- [ ] **Step 3: Prove Herdr, RBAC, and persistence**

Run:

```bash
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- herdr status --json
kubectl --context orbstack -n agent-os-demo auth can-i create pods --as system:serviceaccount:agent-os-demo:agent-os-firstmate
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- sh -lc 'printf persisted > /home/agent/persistence-proof'
kubectl --context orbstack -n agent-os-demo delete pod agent-os-firstmate-0
kubectl --context orbstack -n agent-os-demo wait --for=condition=Ready pod/agent-os-firstmate-0 --timeout=180s
kubectl --context orbstack -n agent-os-demo exec statefulset/agent-os-firstmate -- grep -F persisted /home/agent/persistence-proof
```

Expected: Herdr server is compatible, RBAC says `yes`, and the proof survives Pod replacement.

- [ ] **Step 4: Prove isolated crewmate lifecycle**

Run the launcher inside the primary Pod to create `scout-1`, wait for readiness, confirm it has a different PVC and no automounted token, write a proof file, restart it, and confirm the file remains.
Delete only `scout-1` through the launcher and confirm the primary remains Ready.

- [ ] **Step 5: Run final repository verification**

Run:

```bash
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done
bin/fm-lint.sh
bash tests/agent-os-local.test.sh
bash tests/agent-os-container.test.sh
bash tests/agent-os-kubernetes.test.sh
git diff --check
```

Expected: every command exits 0 with no warnings attributable to the new files.

- [ ] **Step 6: Commit and ship through the repository gate**

Commit the reviewed files on `feat/orbstack-demo`, initialize no-mistakes for the `akua-dev/agent-os` push target, run the configured pipeline without `--yes`, and stop at a CI-green PR for the captain's merge decision.
