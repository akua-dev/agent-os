# Agent OS Tool Development Guide

These instructions apply only inside `tools/agent-os/`.
They govern development of the operating tool and must not be copied into the root Firstmate instructions.

## Purpose

This tool incrementally moves complex fleet mechanics from Bash into a small Bun and TypeScript CLI.
It extends Firstmate's existing files and lifecycle rather than introducing a parallel state store, controller, or agent model.
Keep compatibility with the root distro's `data/`, `state/`, briefs, status events, and guarded teardown behavior.
Use the Bun channel declared in `.bun-version`.
Keep `.bun-version`, `packageManager`, and the matching Bun type definitions aligned on the latest stable release.

## Effect

Use Effect for effectful workflows whose failure modes, dependencies, cleanup, concurrency, retries, or observability benefit from typed composition.
Keep small total functions and straightforward value transformations in plain TypeScript.
Load the scoped `effect-ts` skill installed from `Effect-TS/skills` before changing Effect code.
Use the ignored `.repos/effect` checkout for source verification when the skill's focused guides do not answer the question.
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

Use the official `@akua-dev/sdk` for Akua operations implemented inside this TypeScript tool.
Keep the bundled `akua` CLI available for Firstmate's direct and interactive use.
Use Bun Shell's `$` for other finite calls to trusted CLIs such as `kubectl`, `herdr`, `treehouse`, and Git.
Interpolate dynamic values directly so Bun treats each value as a literal argument.
Never use `{ raw: value }` for dynamic data.
Avoid `bash -c` and validate values that an external command could interpret as flags.
Keep non-zero exits throwing by default and use `.nothrow()` only for an expected negative probe.
Set environment and working directory per command instead of mutating the global `$` instance.
Use `Bun.spawn()` for interactive agents, servers, watches, live logs, cancellation, and other long-running processes.
Existing Bash scripts may be invoked explicitly during migration, but new orchestration and state transitions belong in TypeScript.

## Akua packages

The prepared mate package lives at `packages/mate/` and renders ordinary Kubernetes YAML.
Treat it as an editable convenience, not a required abstraction or controller.
Firstmate may use `agent-os mate render`, invoke `akua render` itself, edit the result, or author equivalent YAML directly.

## Scope Discipline

Prefer a thin adapter over a new framework.
Do not add a database, daemon, custom inter-agent protocol, Kubernetes controller, or duplicate task specification.
Keep mates general-purpose and keep parent-only communication unchanged across local and remote addresses.
Use Kubernetes APIs and later Agent Sandbox only as runtime resolvers behind the same logical address.

## Verification

Run `bun run check` from this directory after changes.
Add focused Bun tests beside every new address, resolver, or command contract.
Test failure, ambiguity, and unsafe input paths as well as successful execution.
