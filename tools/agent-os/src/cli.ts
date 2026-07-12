#!/usr/bin/env bun

import { parseArgs } from "node:util";
import { Effect } from "effect";

import {
  formatKubernetesAgentAddress,
  formatLocalAgentAddress,
  parseAgentAddress,
} from "./address.ts";
import { renderMatePackage } from "./mate-package.ts";

const usage = `Usage:
  agent-os address local <mate-id>
  agent-os address k8s <mate-id> [--cluster <alias>] [--namespace <name>]
  agent-os address inspect <multiaddr>
  agent-os mate render <mate-id> [--cluster <alias>] [--namespace <name>] [--image <image>] [--out <dir>]`;

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

async function runMateCommand(args: string[]): Promise<void> {
  const [command, ...rest] = args;

  if (command !== "render") {
    throw new Error(usage);
  }

  const { positionals, values } = parseArgs({
    allowPositionals: true,
    args: rest,
    options: {
      cluster: {
        default: "in-cluster",
        type: "string",
      },
      image: {
        default: "agent-os:dev",
        type: "string",
      },
      namespace: {
        default: "agent-os",
        type: "string",
      },
      out: {
        type: "string",
      },
    },
    strict: true,
  });
  const mateId = requireSingleArgument(positionals);
  const result = await Effect.runPromise(
    renderMatePackage({
      cluster: values.cluster,
      image: values.image,
      mateId,
      namespace: values.namespace,
      outDir: values.out,
    }).pipe(
      Effect.catchAll((error) => Effect.fail(new Error(error.message))),
    ),
  );

  console.log(JSON.stringify(result, null, 2));
}

async function main(): Promise<void> {
  const [command, ...rest] = Bun.argv.slice(2);

  switch (command) {
    case "address":
      runAddressCommand(rest);
      return;
    case "mate":
      await runMateCommand(rest);
      return;
    default:
      throw new Error(usage);
  }
}

try {
  await main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
