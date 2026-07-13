# Agent OS package

This is the one public, versioned Agent OS package.
It renders ordinary Kubernetes resources for one persistent Firstmate: an optional namespace, ServiceAccount, persistent home, headless Service, StatefulSet, and explicit RBAC.
It requires one complete 64-hex Agent OS image digest and no Akua account, API key, service, or credential.

Render it directly:

```sh
akua render \
  --package package.k \
  --inputs inputs.example.yaml \
  --out /tmp/agent-os
```

Inspect the YAML before applying it with `kubectl`.
The example digest is deliberately non-installable until the first public Agent OS image release exists.
Replace it only with that release's published digest.

The default `rbac: namespace` grants the Firstmate ServiceAccount only the namespace-scoped Pod, Pod exec/log, PVC, and StatefulSet operations needed for runtime mate management, including patch for idempotent apply.
Set `rbac: none` when a separate authority mechanism manages mates.
Set `rbac: cluster-admin` only for an isolated intelligence cluster after a reviewed grant.

With `createNamespace: true`, the lifecycle helper creates an absent namespace with the package's exact installation identity and refuses to adopt an existing unowned namespace.
With `createNamespace: false`, the namespace must already exist without Agent OS ownership metadata, and the lifecycle helper never deletes it.

The package carries no credential value or Secret reference.
Any runtime credential is a separately created namespace-local Kubernetes Secret, referenced by the runtime helper only after its owner has approved that authority.
