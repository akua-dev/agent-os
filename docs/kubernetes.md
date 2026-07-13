# Kubernetes Agent OS demo

This demo runs Firstmate as the persistent controller of an isolated agent cluster.
Kubernetes distributes and isolates the crew; it does not replace Firstmate's supervision model or Herdr's terminal/session interface.

The local topology is deliberately small:

- `agent-os-firstmate-0` is a StatefulSet with a 20 Gi persistent home.
- Herdr 0.7.3 is PID 1 and remains the visible session backend.
- the primary's local-demo ServiceAccount has `cluster-admin`, so it can shape its own crew and workspace;
- every crewmate is an adaptable Agent OS container with its own 10 Gi PVC;
- crewmates do not receive Kubernetes service-account credentials by default.

The primary and crewmates run as UID 0 inside their containers.
OrbStack's built-in Kubernetes does not support Pod user namespaces, so container root is also root on the dedicated OrbStack VM node.
The Pods do not use privileged mode, host namespaces, host mounts, or raw block devices.
This root policy and the broad primary grant are only for the isolated local agent cluster.
They are not a production-cluster access pattern.

## Requirements

- OrbStack with Kubernetes enabled
- Docker
- `kubectl`

The helper refuses ambient Kubernetes contexts.
It uses `orbstack` unless a different context is deliberately enabled with `AGENT_OS_ALLOW_NON_ORBSTACK=1`.

## Run the demo

```sh
bin/agent-os-local.sh build
bin/agent-os-local.sh deploy
bin/agent-os-local.sh status
bin/agent-os-local.sh shell
```

The image includes Firstmate's complete required toolchain, including `gh`, `rg`, `fd`, Akua, `kubectl`, K9s, treehouse, no-mistakes, and every required AXI CLI.
Authenticate GitHub inside the primary with `gh auth login`.
Authenticate Pi using `/login` and the provider flow you choose.
Host credentials are intentionally excluded from the image and are never copied automatically.
Authentication stored below `/home/agent` persists on the individual agent PVC.

Tools installed below `/home/agent/.local`, `/home/agent/.bun`, `/home/agent/.cargo`, or `/usr/local` survive Pod replacement.
Global npm installs use the persistent `/usr/local` prefix.
`apt` is available because the container runs as root, but packages written elsewhere in the container filesystem are ephemeral.

Start Pi from the tracked distro and attach to Herdr from another terminal:

```sh
# inside the primary shell
cd /opt/agent-os
pi --model openai-codex/gpt-5.6-terra --thinking low

# on the host
bin/agent-os-local.sh attach
```

During the current local evaluation, the OrbStack manifest also converges
`config/crew-dispatch.json` and `config/secondmate-harness` on every primary Pod
start. Crewmates and Secondmates therefore launch through Pi with
`openai-codex/gpt-5.6-terra` and low thinking. The reusable image and Akua
packages remain model-agnostic when those local test environment variables are
absent. The same opt-in policy updates Pi's own `defaultProvider`,
`defaultModel`, and `defaultThinkingLevel`, so a plain `pi` primary session uses
Terra-low too.

The primary can create and manage isolated crewmates directly:

```sh
bin/agent-os-crewmate.sh create scout-1
bin/agent-os-crewmate.sh status scout-1
bin/agent-os-crewmate.sh delete scout-1
```

The prepared package is an optional alternative when typed, editable manifests are useful:

```sh
akua render \
  --package tools/agent-os/packages/mate/package.k \
  --inputs tools/agent-os/packages/mate/inputs.example.yaml \
  --out /tmp/scout-1
kubectl apply -f /tmp/scout-1
```

Firstmate may inspect or edit the result, change the package, compose raw YAML, or use the compatibility helper.
Agent OS does not wrap these capable tools into a second workflow CLI.

AI credentials are an explicit per-mate grant.
Create or select a Kubernetes Secret containing an `auth.json` key, then pass only its name as the package's `piAuthSecret` input.
The package mounts that file read-only and never discovers credentials by itself.

```sh
kubectl -n agent-os-demo create secret generic agent-os-mate-scout-1-pi-auth \
  --from-file=auth.json=/home/agent/.pi/agent/auth.json
```

Do this only when copying that selected credential set was authorized.
Prefer an already curated Secret when one exists.

Give each launched Herdr agent a task-unique name and an explicit completion artifact in its brief.
Use ordinary Herdr and Kubernetes commands to launch, inspect, steer, and retrieve it.

```sh
kubectl -n agent-os-demo exec agent-os-mate-scout-1 -- \
  herdr agent start scout-1-research --cwd /home/agent --no-focus -- pi "$(cat /tmp/scout-1.prompt)"
kubectl -n agent-os-demo exec agent-os-mate-scout-1 -- \
  test -s /home/agent/data/scout-1.md
```

Do not treat Herdr `idle` alone as completion because a newly launched agent may briefly be idle before it starts work.
Check the declared artifact or delivered Git state and read the pane when it is absent.
Before reusing a name restored from a persistent Herdr session, verify that no agent process is live and close only the confirmed stale pane.

When run on a host, the compatibility helper requires an explicit context:

```sh
AGENT_OS_CONTEXT=orbstack bin/agent-os-crewmate.sh status scout-1
```

Inside an authorized Firstmate Pod, Agent OS creates a rotation-safe kubeconfig that references the projected ServiceAccount token file.
It never copies the token value into the kubeconfig.

Destroying the demo requires confirmation and deletes only the demo namespace:

```sh
bin/agent-os-local.sh destroy --yes
```

## What the demo proves

The primary and child homes survive Pod replacement.
Tools installed into the persistent home prefixes and `/usr/local` also survive Pod replacement.
A child cannot use the Kubernetes API through an automatically mounted token.
The primary can create, inspect, and delete child Pods and PVCs using ordinary `kubectl`.
No custom agent communication protocol or GitOps controller is required.

This is the local substrate, not the final access model.
Remote Agent OS clusters should keep the intelligence cluster isolated and grant product or production access deliberately per task, with Akua providing stable infrastructure primitives and guardrails.
