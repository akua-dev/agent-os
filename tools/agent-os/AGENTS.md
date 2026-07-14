# Agent OS Tool Development Guide

These instructions apply only inside `tools/agent-os/`.
They govern development of the operating tool and must not be copied into the root Firstmate instructions.

## Purpose

This tool owns only stable Agent OS primitives that the underlying general-purpose tools do not already provide.
It extends Firstmate's existing files and lifecycle rather than introducing a parallel state store, controller, or agent model.
Keep compatibility with the root distro's `data/`, `state/`, briefs, status events, and guarded teardown behavior.
Use the Bun channel declared in `.bun-version`.
Keep `.bun-version`, `packageManager`, and the matching Bun type definitions aligned on the latest stable release.

## Effect

Use Effect for effectful workflows whose failure modes, dependencies, cleanup, concurrency, retries, or observability benefit from typed composition.
Keep small total functions and straightforward value transformations in plain TypeScript.
Use official Effect documentation and the ignored `.repos/effect` checkout for source verification before changing Effect code.
Do not copy that checkout into the container image or commit it as a source snapshot.

## Addresses

Use Multiaddr strings as the single locator for supervised mates.
Persist the canonical string form only.
Do not persist Multiaddr bytes while Agent OS protocols use application-private numeric codes.
Keep credentials, resource requests, authority grants, Pod names, UIDs, and IP addresses out of addresses.
Use stable mate IDs and let each resolver discover the current runtime resource.
Treat `in-cluster` as the reserved alias for the cluster containing the caller.
The address grammar and validation contract are owned by `src/address.ts` and its tests.

## Command Execution

Keep the bundled `akua` CLI available for Firstmate's direct use instead of proxying it through this tool.
Use Bun Shell's `$` for finite calls to trusted CLIs only when implementing a genuinely missing Agent OS primitive.
Interpolate dynamic values directly so Bun treats each value as a literal argument.
Never use `{ raw: value }` for dynamic data.
Avoid `bash -c` and validate values that an external command could interpret as flags.
Keep non-zero exits throwing by default and use `.nothrow()` only for an expected negative probe.
Set environment and working directory per command instead of mutating the global `$` instance.
Use `Bun.spawn()` for interactive agents, servers, watches, live logs, cancellation, and other long-running processes.
Existing Bash scripts may be invoked explicitly during migration, but do not move adaptable orchestration into TypeScript merely because it is currently written in Bash or instructions.

## Kubernetes package

The canonical portable Firstmate package lives at `packages/firstmate/` and renders ordinary Kubernetes YAML.
Mate creation uses that package's internal `crewmate.yaml` template at runtime instead of a separately installable package.
Keep the portable package free of Akua accounts, credentials, services, and marketplace-specific behavior.

## Scope Discipline

Prefer no adapter when an agent can reliably compose the underlying tools itself.
When a stable safety boundary truly needs code, prefer the thinnest adapter that owns only that boundary.
Do not wrap a capable general-purpose CLI merely to encode one Agent OS workflow.
Prefer instructions, skills, and direct composition of Akua, Kubernetes, Herdr, Git, and other trusted tools.
Add TypeScript only for a stable primitive the underlying tools do not already provide, such as the Agent OS address grammar, or when repeated failures prove a reusable safety boundary is missing.
Keep policy and desired outcomes in instructions instead of hardcoding how an adaptable agent must sequence tools.
Do not add a database, daemon, custom inter-agent protocol, Kubernetes controller, or duplicate task specification.
Keep mates general-purpose and keep parent-only communication unchanged across local and remote addresses.
Use Kubernetes APIs and later Agent Sandbox only as runtime resolvers behind the same logical address.

## Verification

Run `bun run check` from this directory after changes.
Add focused Bun tests beside every new address, resolver, or command contract.
Test failure, ambiguity, and unsafe input paths as well as successful execution.
