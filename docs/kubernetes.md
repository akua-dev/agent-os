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

The package requires one complete 64-hex image digest because a mutable or malformed reference cannot identify an upgrade or recovery input.
The source tree contains an intentionally non-installable placeholder until the first public image release is published.
Replace it only with the digest recorded by that release workflow.

## Source and image provenance

`SOURCE_PROVENANCE.json` records the exact repositories, full input commits, normal merge order, licenses, and explicit exclusions for the portable MIT source package.
`bin/agent-os-source-context.sh <empty-directory> <full-commit>` assembles a clean build context from Git-tracked files only, preserving symlinks and executable bits without copying untracked credentials or operational state.
The image workflow records the selected commit, Git tree, stable `git archive --format=tar` SHA-256, and OCI source/revision/version labels while BuildKit emits the multi-architecture SBOM and provenance attestations.
A branch or PR reference is mutable and is not a release source pin; merge and publication remain separate approvals.

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
The namespace in the rendered StatefulSet is authoritative, and an inconsistent `AGENT_OS_NAMESPACE` stops the operation before any Kubernetes request.
With `createNamespace: true`, install creates only an absent namespace or reuses one carrying the exact package installation identity.
It refuses to adopt a pre-existing unowned or foreign namespace.
With `createNamespace: false`, the selected namespace must already exist without Agent OS ownership metadata and remains outside package ownership.

The default `rbac: namespace` creates a ServiceAccount plus a Role and RoleBinding scoped to the selected namespace.
That Role allows Firstmate to manage runtime crewmate Pods and PVCs and inspect its StatefulSet.
Set `rbac: none` only when another reviewed authority handles those runtime operations.
Set `rbac: cluster-admin` only for an isolated intelligence cluster after reviewing the broader ClusterRoleBinding.

The persistent home PVC defaults to `20Gi` and is mounted at `/home/agent`.
Image-owned `/usr/local` remains immutable, while user-installed tools persist under `/home/agent/.local` and the other home-scoped prefixes on the PVC.
The init container authenticates an image ownership manifest and refuses ambiguous legacy `/usr/local` migrations instead of retaining stale image binaries.

## Operations

To upgrade, use a new released digest in the same input file and apply it through the same package.

```sh
bin/agent-os-kubernetes.sh upgrade
```

Upgrade applies and verifies the desired workload and RBAC before removing obsolete namespace Role and RoleBinding resources.
Routine `namespace` and `none` operations never inspect or delete cluster-scoped RBAC.
When a downgrade may leave the exact package-owned ClusterRoleBinding, upgrade exits incomplete and prints a separately confirmed `cleanup-cluster-rbac --yes` command plus the required absence evidence.
Run that command only through an explicitly approved cluster-admin identity.
It refuses to delete a same-name binding unless its ownership label and installation annotation both match.

To roll back only the Firstmate workload revision, use Kubernetes StatefulSet history.
This does not roll back package inputs, RBAC, or persistent data.

```sh
bin/agent-os-kubernetes.sh rollback
```

To inspect the workload, use the same explicit context and namespace.

```sh
bin/agent-os-kubernetes.sh status
```

Uninstall is deliberately confirmed and bounded to namespaced resources from a fresh render plus the deterministic namespace Role and RoleBinding names.
It retains the namespace by default and reports possible cluster-scoped residue without requesting cluster-wide authority.
Use the separately printed privileged cleanup command to remove an exactly owned ClusterRoleBinding.
The optional `--delete-namespace` flag works only for `createNamespace: true`, rechecks the exact installation identity, inventories every listable namespaced resource type, and refuses deletion while any foreign resource remains.
With `createNamespace: false`, the namespace is never deleted.

```sh
bin/agent-os-kubernetes.sh uninstall --yes
```

To delete an exactly owned and otherwise empty namespace as part of the confirmed uninstall, use:

```sh
bin/agent-os-kubernetes.sh uninstall --yes --delete-namespace
```

## Runtime mates

Firstmate creates a separate-Pod crewmate at runtime with the internal `crewmate.yaml` template in the canonical package.
It is not a second public package and is not a Marketplace product.
Each runtime mate has its own PVC and no ambient Kubernetes ServiceAccount token.
Creating one requires an explicitly authorized, pre-created Secret in the same namespace with an `auth.json` key.
Pass only that Secret's name through `AGENT_OS_AI_SECRET`; the helper never discovers or copies the primary credential.
The Secret projects only `auth.json` into a dedicated read-only runtime directory, and the entrypoint links that file into the writable PVC-backed Pi state without copying credential bytes.
A missing Secret or key keeps the Pod unready, so creation fails closed and removes the non-running Pod while retaining its PVC for an authorized retry.

```sh
AGENT_OS_AI_SECRET=scout-1-ai-auth bin/agent-os-crewmate.sh create scout-1
```

Use `stop` for a Pod-only shutdown and `restart` for a Pod-only replacement after an approved Secret rotation.
The ambiguous `delete` operation is rejected.
Only `purge <id> --yes` removes the PVC, and it requires the owned Pod to be absent, exact ownership, a fresh clean checkpoint annotation from the stopped home, and a non-secret evidence file.
The full rotation, urgent-revocation, checkpoint, and purge procedure is owned by the `kubernetes-fleet` operating skill.

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
