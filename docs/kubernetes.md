# Kubernetes Agent OS demo

This demo runs Firstmate as the persistent controller of an isolated agent
cluster. Kubernetes distributes and isolates the crew; it does not replace
Firstmate's supervision model or Herdr's terminal/session interface.

The local topology is deliberately small:

- `agent-os-firstmate-0` is a StatefulSet with a 20 Gi persistent home.
- Herdr 0.7.3 is PID 1 and remains the visible session backend.
- the primary's local-demo ServiceAccount has `cluster-admin`, so it can shape
  its own crew and workspace;
- every crewmate is an adaptable Agent OS container with its own 10 Gi PVC;
- crewmates do not receive Kubernetes service-account credentials by default.

The broad primary grant is only for the isolated local agent cluster. It is not
a production-cluster access pattern.

## Requirements

- OrbStack with Kubernetes enabled
- Docker
- `kubectl`

The helper refuses ambient Kubernetes contexts. It uses `orbstack` unless a
different context is deliberately enabled with `AGENT_OS_ALLOW_NON_ORBSTACK=1`.

## Run the demo

```sh
bin/agent-os-local.sh build
bin/agent-os-local.sh deploy
bin/agent-os-local.sh status
bin/agent-os-local.sh shell
```

Inside the primary container, authenticate the Pi harness using the provider
flow you choose. Host model credentials are intentionally excluded from the
image and are never copied automatically. The authenticated home persists on
the primary PVC.

Start Pi from the tracked distro and attach to Herdr from another terminal:

```sh
# inside the primary shell
cd /opt/agent-os
pi

# on the host
bin/agent-os-local.sh attach
```

The primary can create and manage isolated crewmates directly:

```sh
bin/agent-os-crewmate.sh create scout-1
bin/agent-os-crewmate.sh status scout-1
bin/agent-os-crewmate.sh delete scout-1
```

When run on a host, the crewmate helper requires an explicit context:

```sh
AGENT_OS_CONTEXT=orbstack bin/agent-os-crewmate.sh status scout-1
```

Destroying the demo requires confirmation and deletes only the demo namespace:

```sh
bin/agent-os-local.sh destroy --yes
```

## What the demo proves

The primary and child homes survive Pod replacement. A child cannot use the
Kubernetes API through an automatically mounted token. The primary can create,
inspect, and delete child Pods and PVCs using ordinary `kubectl`; no custom
agent communication protocol or GitOps controller is required.

This is the local substrate, not the final access model. Remote Agent OS
clusters should keep the intelligence cluster isolated and grant product or
production access deliberately per task, with Akua providing stable
infrastructure primitives and guardrails.
