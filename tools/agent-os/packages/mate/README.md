# Agent OS mate package

This Akua package is a prepared convenience for rendering one general-purpose mate Pod and its persistent home.
It is not a controller, required operating model, or replacement for Kubernetes YAML.

Render the example directly:

```sh
akua render --package package.k --inputs inputs.example.yaml --out /tmp/scout-1
```

Inspect and edit the rendered YAML before applying it:

```sh
kubectl apply -f /tmp/scout-1
```

Firstmate may change this package, supply additional inputs, edit the rendered files, or author equivalent YAML directly.
The package intentionally grants no Kubernetes token and no privileged, host-namespace, or host-mount access.

AI credentials are an explicit grant.
Set `piAuthSecret` to the name of an existing Kubernetes Secret whose `auth.json` key contains the selected Pi credential set.
The package mounts only that Secret reference read-only; it never discovers or copies credentials by itself.
