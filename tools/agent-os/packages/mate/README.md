# Agent OS mate package

This Akua package is a prepared convenience for rendering one general-purpose mate Pod and its persistent home.
It is not a controller, required operating model, or replacement for Kubernetes YAML.

Render the example directly:

```sh
akua render --package package.k --inputs inputs.example.yaml --out /tmp/scout-1
```

Or use the Agent OS convenience command from any directory:

```sh
agent-os mate render scout-1 --namespace agent-os-demo --image agent-os:dev --out /tmp/scout-1
```

Inspect and edit the rendered YAML before applying it:

```sh
kubectl apply -f /tmp/scout-1
```

Firstmate may change this package, supply additional inputs, edit the rendered files, or author equivalent YAML directly.
The package intentionally grants no Kubernetes token and no privileged, host-namespace, or host-mount access.
