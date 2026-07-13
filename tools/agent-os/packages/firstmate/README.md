# Agent OS package

This is the one public, versioned Agent OS package.
It renders ordinary Kubernetes resources for one persistent Firstmate: an optional namespace, ServiceAccount, persistent home, headless Service, StatefulSet, and explicit RBAC.
It requires an immutable Agent OS image digest and no Akua account, API key, service, or credential.

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

The default `rbac: namespace` grants the Firstmate ServiceAccount only the namespace-scoped Pod, Pod exec/log, PVC, and StatefulSet reads needed for runtime mate management.
Set `rbac: none` when a separate authority mechanism manages mates.
Set `rbac: cluster-admin` only for an isolated intelligence cluster after a reviewed grant.

The package carries no credential value or Secret reference.
Any runtime credential is a separately created Kubernetes Secret, mounted only after its owner has approved that authority.
