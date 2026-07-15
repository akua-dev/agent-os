#!/usr/bin/env bun

import { parseArgs } from "node:util";

import {
  formatKubernetesAgentAddress,
  formatLocalAgentAddress,
  parseAgentAddress,
} from "./address.ts";

const usage = `Usage:
  agent-os address local <mate-id>
  agent-os address k8s <mate-id> [--cluster <alias>] [--namespace <name>]
  agent-os address inspect <multiaddr>`;

function requireSingleArgument(args: string[]): string {
  if (args.length !== 1 || args[0] == null) {
    throw new Error(usage);
  }

  return args[0];
}

function runAddressCommand(args: string[]): void {
  const [command, ...rest] = args;

  switch (command) {
    case "local":
      console.log(formatLocalAgentAddress(requireSingleArgument(rest)));
      return;

    case "k8s": {
      const { positionals, values } = parseArgs({
        allowPositionals: true,
        args: rest,
        options: {
          cluster: {
            default: "in-cluster",
            type: "string",
          },
          namespace: {
            default: "agent-os",
            type: "string",
          },
        },
        strict: true,
      });
      const mateId = requireSingleArgument(positionals);

      console.log(
        formatKubernetesAgentAddress(mateId, {
          cluster: values.cluster,
          namespace: values.namespace,
        }),
      );
      return;
    }

    case "inspect":
      console.log(
        JSON.stringify(parseAgentAddress(requireSingleArgument(rest)), null, 2),
      );
      return;

    default:
      throw new Error(usage);
  }
}

function main(): void {
  const [command, ...rest] = Bun.argv.slice(2);

  if (command !== "address") {
    throw new Error(usage);
  }

  runAddressCommand(rest);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
