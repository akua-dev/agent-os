# Firstmate package verification

Date: 2026-07-12
Akua CLI: 0.8.20
Kubernetes: OrbStack 1.34.8
Agent OS image: `sha256:f87ae0f5f93d2781700a7c3a0828833433565322b7bb3e8f1d49244b40b8580e`

## Claim

The optional Firstmate Akua package renders ordinary resources and can start a persistent, cluster-admin Firstmate with a read-only Akua authorization mount in a dedicated Kubernetes namespace.

## Render evidence

Command:

```sh
akua render --no-json --no-interactive \
  --package tools/agent-os/packages/firstmate/package.k \
  --inputs tools/agent-os/packages/firstmate/inputs.example.yaml \
  --out /tmp/agent-os-firstmate-render
```

Result:

```text
rendered: 6 manifest(s) (sha256:4965345d355a00530a887f8f24454d5e858664c7fa4328ba584c15f96703ca0d)
Namespace
ServiceAccount
PersistentVolumeClaim
Service
ClusterRoleBinding
StatefulSet
```

## Disposable-cluster evidence

The live eval used namespace `agent-os-package-eval`, the local immutable image above, `imagePullPolicy: Never`, and a synthetic authorization Secret.
It rendered with `createNamespace: false`, applied five manifests, waited for the StatefulSet, and ran the checks inside the Pod.

Commands:

```sh
kubectl --context orbstack apply -f /tmp/agent-os-firstmate-eval
kubectl --context orbstack -n agent-os-package-eval \
  rollout status statefulset/agent-os-firstmate --timeout=120s
kubectl --context orbstack -n agent-os-package-eval \
  exec statefulset/agent-os-firstmate -- herdr status --json
kubectl --context orbstack -n agent-os-package-eval \
  exec statefulset/agent-os-firstmate -- kubectl auth can-i '*' '*' --all-namespaces
```

Result:

```text
rendered: 5 manifest(s) (sha256:ecf9cfb0052ca90677f14987ff823637aa27d3e914be9b7ab66906b55e99acc4)
partitioned roll out complete: 1 new pods have been updated
herdr=ready
home=writable
auth_mount=readonly
context=in-cluster
cluster_admin=yes
```

The write probe against `/var/run/secrets/agent-os/akua/authorization` failed with `Read-only file system`.
The eval namespace and its cluster-scoped binding were deleted after the checks.

## Scope

This proves the Kubernetes package contract locally.
It does not prove Akua workspace authentication, managed KaaS creation, Hetzner worker lifecycle, successor-token handoff, public-image availability, or bootstrap-token revocation.
