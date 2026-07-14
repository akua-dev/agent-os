---
name: akua-intelligence-bootstrap
description: "Bootstrap or recover a dedicated Agent OS intelligence cluster through Akua's native API, MCP, CLI, Akua packages, and Kubernetes without adding an Agent OS provisioning service."
user-invocable: false
metadata:
  internal: true
---

# Akua intelligence bootstrap

Load this skill before provisioning, recovering, or handing off a Firstmate in an Akua-managed intelligence cluster.

## Boundary

- The Akua workspace and Hetzner project must be dedicated to Agent OS infrastructure and contain no product, production, or customer resources.
- Provisioning machines, creating or revoking credentials, retrieving kubeconfig, and granting cluster-admin require the captain's explicit approval for the exact run.
- An available credential proves capability, not approval.
- Use Akua's native Platform MCP, REST API, CLI, and packages directly.
- Do not build or invoke an Agent OS provisioning wrapper, controller, Install, or GitOps workflow.
- Use a fresh idempotency key for each intended create and reuse that key only when retrying the same intended operation.
- Never put an Akua token, Hetzner token, kubeconfig, or authorization header in Git, a prompt, a status file, command arguments, or retained evidence.

## Native API surface

The current public API base is `https://api.akua.dev/v1`.
When using REST, keep a complete HTTP authorization header in a mode-`0400` file and pass it with curl's native `-H @file` support.
Write secret-bearing JSON through protected files or stdin, never shell arguments.

Use the Platform MCP `search` tool again before a mutation so current schemas outrank this routing table.

| Outcome | Native endpoint |
| --- | --- |
| Store the approved Hetzner token | `POST /secrets`, kind `cloud_provider/hcloud` |
| Validate the provider token | `POST /secrets/validate_token` |
| Create managed KaaS | `POST /clusters` |
| Wait for cluster creation | `POST /operations/{id}:wait?timeout=60` |
| Create Hetzner compute configuration | `POST /compute/configs` |
| Inspect available capacity and price | `GET /compute/instance_types?config={config}` |
| Create a worker | `POST /compute/machines` |
| Inspect worker state | `GET /compute/machines/{providerId}` |
| Retrieve the approved owner kubeconfig | `GET /clusters/{id}/kubeconfig` |
| Create the clustered-Firstmate token | `POST /api_tokens` |
| Inventory tokens | `GET /api_tokens` |
| Revoke the local bootstrap token | `DELETE /api_tokens/{id}` |

## Authorization overlay contract

The public Firstmate package never accepts an Akua credential input or renders an Akua Secret reference.
Akua authorization belongs to the separate namespace-local integration overlay under `deploy/akua/`.
The grant patch mounts only the selected Secret at `/var/run/secrets/agent-os/akua` and sets `AKUA_AUTH_HEADER_FILE=/var/run/secrets/agent-os/akua/authorization`.
The Secret must contain one `authorization` key with the complete header and must live in the same namespace as the Firstmate StatefulSet.
Never put the Secret value into the overlay, package inputs, or command arguments.

Set `context` and `namespace` from the separately approved target and grant the overlay through the serialized integration helper:

```sh
AGENT_OS_CONTEXT="$context" AGENT_OS_NAMESPACE="$namespace" bin/agent-os-akua-auth.sh grant "$secret_name"
```

The helper holds the installation-wide lifecycle Lease, validates exact StatefulSet UID and resourceVersion, verifies the named Secret reference without reading Secret bytes, applies one CAS strategic patch, and verifies both the retained StatefulSet overlay and its exact-owned Pod.

Revocation is owned by the same integration boundary.
Revoke the Akua API token and prove it fails first, then revoke the overlay through the same serialized helper:

```sh
AGENT_OS_CONTEXT="$context" AGENT_OS_NAMESPACE="$namespace" bin/agent-os-akua-auth.sh revoke "$secret_name"
```

Delete only the named namespace-local Secret after explicit cleanup approval.
The revoke patch removes the environment entry, volume mount, and volume without changing the public package or any other Firstmate setting.

## Bootstrap procedure

1. Record the approved workspace ID, intended region, machine constraints, expiration or cleanup condition, and evidence directory without recording secrets.
2. Read the live workspace, Secret, cluster, compute configuration, machine, and token inventories before creating anything.
3. Stop if the workspace or Hetzner project contains production resources or if an existing matching resource makes intent ambiguous.
4. Validate the provider token without storing it, then create or select the `cloud_provider/hcloud` Secret and require server validation state `valid` before creating compute.
5. Create the managed cluster with an idempotency key, preserve its operation ID, and wait for terminal `SUCCEEDED` state.
6. Create the compute configuration from the validated Secret, inspect available instance types, and select the smallest type satisfying the approved CPU, RAM, disk, architecture, price, and region constraints.
7. Create the worker, then verify both Akua machine state and Kubernetes Node readiness.
8. Retrieve kubeconfig only into a protected temporary file and verify the cluster identity before applying anything.
9. Build or select a published Agent OS image by immutable digest.
10. Render `tools/agent-os/packages/firstmate/package.k` with `akua render`, inspect the ordinary credential-free YAML, and apply it with `kubectl`.
11. Create a distinct clustered-Firstmate API token, create the namespace-local authorization Secret from a protected header file, and apply the grant overlay exactly as defined above.
12. Verify the StatefulSet is ready, Herdr responds, the persistent home is writable, the `in-cluster` context is cluster-admin only in this intelligence cluster, and the Pod can list its Akua workspace through `curl -H @"$AKUA_AUTH_HEADER_FILE"`.
13. Probe the approved primary model route with a bounded request and record only provider, model, result, timing, and cost.
    If there is no independently approved fallback provider, record the single-provider availability risk instead of presenting the fleet as quota-resilient.
14. From the clustered Firstmate, inventory all workspace token IDs and prove the new token can perform the required Akua and Kubernetes reads.
15. Only after that handoff succeeds, revoke the known local bootstrap token and prove it now receives an authentication failure.
16. Destroy every protected temporary file and record only non-secret resource IDs, operation IDs, timestamps, states, image digest, test results, costs, and interventions.

## Recovery and cleanup

- A Pod restart reuses the Firstmate PVC and the authorization mount declared by the separate overlay.
- A worker replacement must preserve or reattach every PVC holding unique work before deleting the old worker.
- Do not claim cluster-loss recovery until an external encrypted backup has been restored in a clean cluster.
- Machine, cluster, authorization overlay, Secret, token, and workspace deletion are separate destructive actions.
- Execute only the approved cleanup scope and verify retained resources afterward.

## Completion evidence

The bootstrap is complete only when current external state proves all of these:

- Akua operation IDs reached `SUCCEEDED`;
- the worker is ready in Akua and Kubernetes;
- the Firstmate StatefulSet and Herdr server are ready;
- at least one approved model route completes a bounded request;
- the home and installed-tool paths survive a Pod replacement;
- the clustered token works from the Pod;
- the bootstrap token is revoked and fails authentication;
- no product or production resource exists in the intelligence workspace; and
- the evidence record contains no secret values.
