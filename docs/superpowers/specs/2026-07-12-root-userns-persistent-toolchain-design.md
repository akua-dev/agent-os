# Local root agents and persistent toolchain design

**Date:** 2026-07-12

## Purpose

Agent OS Pods must be able to administer their own container environment in the isolated local OrbStack cluster.
The image must already contain the complete Firstmate toolchain so a fresh controller can begin useful work without an installation round.
Tools and authentication added by an agent at runtime must survive Pod replacement.

## Decisions

Every Agent OS Pod runs as UID 0 inside its container.
OrbStack's built-in Kubernetes uses cri-dockerd and rejects `hostUsers: false`, so the local demo does not request a Pod user namespace.
Container root is therefore root on the dedicated OrbStack VM node for this local demo.
No Agent OS Pod uses privileged mode, a host PID namespace, a host IPC namespace, a host network namespace, a raw block device, or a host-path mount.

The image remains the reproducible baseline.
Each agent receives its own PVC-backed home and persistent `/usr/local` tree for runtime adaptation.
No agent mounts another agent's persistent state.

## Image baseline

The image includes the universal Firstmate toolchain and the Kubernetes demo runtime:

- Bash, CA certificates, curl, Git, OpenSSH client, jq, tmux, procps, and rsync.
- GitHub CLI, ripgrep, and fd.
- Node.js, npm, and Pi.
- Herdr and kubectl.
- treehouse and no-mistakes.
- gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi, and quota-axi.

The Herdr backend does not require Orca.
Agent harnesses other than Pi remain optional runtime additions rather than baseline requirements.
Downloaded release binaries use exact versions and checksums where upstream publishes them.
Global npm packages use exact versions.
The build fails for an unsupported architecture or failed integrity check.

## Persistent filesystem model

Every agent PVC contains two independently used trees:

- `/home/agent` stores Agent OS state, GitHub and model authentication, configuration, projects, package-manager state, and user-installed binaries.
- a PVC subdirectory mounted at `/usr/local` stores global npm packages and tools that installers place in `/usr/local`.

An init container runs from the same image before the agent starts.
It copies the image's `/usr/local` baseline into the PVC-backed `/usr/local` without deleting agent-installed files.
Image-owned files overwrite older image-owned copies so a new image can update the baseline.
Agent-added paths that do not collide with the baseline remain intact.

The runtime environment puts `/home/agent/.local/bin`, `/home/agent/.bun/bin`, `/home/agent/.cargo/bin`, and `/usr/local/bin` before system paths.
It sets persistent XDG directories below `/home/agent` and configures npm's global prefix to `/usr/local`.
Installers that honor HOME, XDG paths, npm prefix, Bun home, Cargo home, or `/usr/local` therefore survive Pod replacement.

`apt` remains available because the process is root inside the container.
Packages installed into `/usr`, `/etc`, or `/var` with `apt` are intentionally ephemeral and disappear on Pod replacement.
Firstmate's required tools do not depend on runtime `apt` because they are part of the image baseline.
An agent that needs an additional durable CLI should prefer `/usr/local` or a persistent home prefix.

## Pod security and authority

The primary and crewmate containers set `runAsUser: 0` and `runAsGroup: 0`.
The init container uses the same container-root identity to seed the persistent tool tree.
The Pods use the runtime's normal container isolation and do not request privileged mode.

The Firstmate ServiceAccount retains cluster-admin only for the isolated local Agent OS cluster.
Crewmates continue to receive no Kubernetes ServiceAccount token by default.
Container root and Kubernetes API authority remain separate controls.

This root policy is explicitly limited to the disposable, agents-only local OrbStack VM cluster.
A remote or shared Agent OS cluster must define and verify its own stronger runtime isolation before reusing this policy.

## Startup flow

1. Kubernetes creates or reattaches the agent's PVC.
2. The init container ensures the persistent home and `/usr/local` directories exist.
3. The init container refreshes image-owned `/usr/local` files while preserving runtime additions.
4. The main container starts as container root with the persistent environment configured.
5. Herdr starts as PID 1.
6. Firstmate bootstrap finds its required tools and reports only missing authentication or genuinely optional additions.

## Failure behavior

The image build stops on missing releases, unsupported architectures, checksum failures, or missing baseline commands.
The init container stops startup if it cannot seed the persistent tool tree.
No fallback grants privileged mode, host namespaces, or host mounts.

## Verification

Static tests assert that both primary and generated crewmate Pod specs use container UID 0 without requesting the unsupported `hostUsers: false` field.
Container tests assert every baseline command is present and Firstmate bootstrap emits no `MISSING:` diagnostics.
Runtime tests prove root can write to normal container paths and durable installs can write to both persistent prefixes.
Persistence tests write one tool below `/home/agent/.local/bin` and one below `/usr/local/bin`, replace the Pod, and execute both tools afterward.
Isolation tests prove crewmates have distinct PVCs and no ServiceAccount token.
Authentication verification checks that GitHub CLI configuration survives Pod replacement without embedding credentials in the image.

## Out of scope

This change does not persist the entire mutable container root filesystem.
It does not add privileged Pods, host mounts, a custom package service, GitOps, or a new inter-agent protocol.
It does not define production-cluster RBAC beyond retaining the existing local-demo boundary.

## Sources

- Kubernetes v1.34 user-namespace documentation, which records cri-dockerd as unsupported: <https://v1-34.docs.kubernetes.io/docs/concepts/workloads/pods/user-namespaces/>.
- Firstmate's universal toolchain contract: `docs/configuration.md` under `Toolchain` and `bin/fm-bootstrap.sh`.
