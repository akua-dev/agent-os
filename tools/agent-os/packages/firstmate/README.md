# Firstmate package

This optional Akua package renders ordinary Kubernetes resources for one persistent Firstmate in a dedicated intelligence cluster.
It creates a namespace, ServiceAccount, persistent home, headless Service, StatefulSet, and - when explicitly enabled - the intelligence-cluster `cluster-admin` binding.

Render it directly with Akua:

```sh
akua render \
  --package package.k \
  --inputs inputs.example.yaml \
  --out /tmp/agent-os-firstmate
```

Inspect the YAML before applying it with `kubectl`.
The package is an editable convenience, not a controller or required workflow.
Use an immutable image digest for a real intelligence cluster; the `latest` default is only a discoverable starting point.

`akuaAuthSecret` names an existing Kubernetes Secret with an `authorization` key containing a complete HTTP authorization header for the dedicated Agent OS workspace token.
The value is mounted read-only at runtime and never belongs in inputs, rendered YAML, Git, logs, or command arguments.
Leave the input empty when Firstmate should not receive Akua workspace access.
