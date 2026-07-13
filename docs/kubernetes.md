# Kubernetes Agent OS

Agent OS installs one persistent Firstmate from the public, versioned package at `tools/agent-os/packages/firstmate/`.
The package renders ordinary Kubernetes resources.
It is free to render and apply on any conformant Kubernetes cluster without an Akua account, API key, managed control plane, or Akua-hosted worker.
Kubernetes distributes and isolates the crew; it does not replace Firstmate's supervision model or Herdr's terminal/session interface.

## Requirements

- A Kubernetes context that you are authorized to use explicitly.
- `kubectl` and the public `akua` renderer CLI on your PATH.
- Permission to create the selected namespace when `createNamespace: true`, plus the rendered ServiceAccount, Role, RoleBinding, Service, PVC, and StatefulSet.
- A default or selected StorageClass that satisfies the `ReadWriteOnce` PVC request.
- An immutable image digest published by an Agent OS release.

No Kubernetes Secret is required for the portable install.
The package has no credential field or Secret reference.
Runtime AI, GitHub, or other authority is created separately by its owner after installation and is never supplied through package inputs, command arguments, or rendered YAML.

The package requires an image digest because a mutable tag cannot identify an upgrade or recovery input.
The source tree contains an intentionally non-installable placeholder until the first public image release is published.
Replace it only with the digest recorded by that release workflow.

## Generic quickstart

Start from a tagged Agent OS source checkout that matches the image release.
Copy the stable input schema and replace its image value with that release's immutable digest.

```sh
cp tools/agent-os/packages/firstmate/inputs.example.yaml /tmp/agent-os-inputs.yaml
$EDITOR /tmp/agent-os-inputs.yaml

export AGENT_OS_CONTEXT=your-kubernetes-context
export AGENT_OS_NAMESPACE=agent-os
export AGENT_OS_INPUTS=/tmp/agent-os-inputs.yaml

bin/agent-os-kubernetes.sh install
```

The installer renders only `tools/agent-os/packages/firstmate/package.k`, applies that fresh output to the named context, and waits for `agent-os-firstmate` to roll out.
It never reads an ambient Kubernetes context.

The default `rbac: namespace` creates a ServiceAccount plus a Role and RoleBinding scoped to the selected namespace.
That Role allows Firstmate to manage runtime crewmate Pods and PVCs and inspect its StatefulSet.
Set `rbac: none` only when another reviewed authority handles those runtime operations.
Set `rbac: cluster-admin` only for an isolated intelligence cluster after reviewing the broader ClusterRoleBinding.

The persistent home PVC defaults to `20Gi` and is mounted at `/home/agent`.
`/usr/local` is a subpath of that same PVC so user-installed global tools survive Pod replacement.

## Operations

To upgrade, use a new released digest in the same input file and apply it through the same package.

```sh
bin/agent-os-kubernetes.sh upgrade
```

To roll back only the Firstmate workload revision, use Kubernetes StatefulSet history.
This does not roll back package inputs, RBAC, or persistent data.

```sh
bin/agent-os-kubernetes.sh rollback
```

To inspect the workload, use the same explicit context and namespace.

```sh
bin/agent-os-kubernetes.sh status
```

Uninstall is deliberately confirmed and bounded to a fresh render of the selected package inputs.
When those inputs create the namespace, deleting that rendered Namespace also removes everything in that namespace.
When `createNamespace: false`, the command deletes only the rendered Agent OS resources in the existing namespace.

```sh
bin/agent-os-kubernetes.sh uninstall --yes
```

## Runtime mates

Firstmate creates a separate-Pod crewmate at runtime with the internal `crewmate.yaml` template in the canonical package.
It is not a second public package and is not a Marketplace product.
Each runtime mate has its own PVC and no ambient Kubernetes ServiceAccount token.

The existing [same-Pod](evidence/2026-07-13-same-pod-firstmate.md) and [separate-Pod recovery](evidence/2026-07-13-separate-pod-recovery.md) records remain local lifecycle evidence.
They do not substitute for a clean published-image installation.

## OrbStack profile

OrbStack is a test profile of the canonical package, not the default product contract.
Its `deploy/orbstack/inputs.yaml` changes only the local environment inputs: the isolated `agent-os-demo` namespace, a local image source with `imagePullPolicy: Never` and `allowMutableImage: true`, and its explicit local-demo `cluster-admin` grant.
The profile uses the same package, ServiceAccount, persistent home, runtime mate template, and lifecycle commands.

```sh
bin/agent-os-local.sh build
bin/agent-os-local.sh deploy
bin/agent-os-local.sh status
bin/agent-os-local.sh shell
```

The local helper refuses a non-OrbStack context unless `AGENT_OS_ALLOW_NON_ORBSTACK=1` is set deliberately.
It tags each rebuilt local image by content before rendering the profile so a deployment cannot reuse a stale mutable image.
The local profile is an isolated test environment only.
Its broad RoleBinding and container-root policy are not a production-cluster access pattern.
