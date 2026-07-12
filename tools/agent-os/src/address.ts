import {
  V,
  multiaddr,
  registry,
  type Component,
  type ProtocolCodec,
} from "@multiformats/multiaddr";

const APPLICATION_PROTOCOL_BASE = 0x300000;
const DNS_LABEL = /^[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?$/;

export const AGENT_OS_PROTOCOL_CODES = Object.freeze({
  local: APPLICATION_PROTOCOL_BASE,
  k8s: APPLICATION_PROTOCOL_BASE + 1,
  namespace: APPLICATION_PROTOCOL_BASE + 2,
  mate: APPLICATION_PROTOCOL_BASE + 3,
  herdr: APPLICATION_PROTOCOL_BASE + 4,
});

export type AgentAddress =
  | {
      address: string;
      location: "local";
      mateId: string;
      protocol: "herdr";
    }
  | {
      address: string;
      cluster: string;
      location: "kubernetes";
      mateId: string;
      namespace: string;
      protocol: "herdr";
    };

export interface KubernetesAddressOptions {
  cluster?: string;
  namespace?: string;
}

export class AgentAddressError extends Error {
  override name = "AgentAddressError";
}

function validateLabel(value: string, component: string): void {
  if (!DNS_LABEL.test(value)) {
    throw new AgentAddressError(
      `Invalid ${component} value ${JSON.stringify(value)}: expected a lowercase DNS label`,
    );
  }
}

const agentOsProtocols: ProtocolCodec[] = [
  {
    code: AGENT_OS_PROTOCOL_CODES.local,
    name: "local",
    size: 0,
  },
  {
    code: AGENT_OS_PROTOCOL_CODES.k8s,
    name: "k8s",
    size: V,
    validate: (value) => validateLabel(value, "k8s cluster alias"),
  },
  {
    code: AGENT_OS_PROTOCOL_CODES.namespace,
    name: "namespace",
    size: V,
    validate: (value) => validateLabel(value, "namespace"),
  },
  {
    code: AGENT_OS_PROTOCOL_CODES.mate,
    name: "mate",
    size: V,
    validate: (value) => validateLabel(value, "mate ID"),
  },
  {
    code: AGENT_OS_PROTOCOL_CODES.herdr,
    name: "herdr",
    size: 0,
  },
];

function findProtocol(key: string | number): ProtocolCodec | undefined {
  try {
    return registry.getProtocol(key);
  } catch {
    return undefined;
  }
}

export function registerAgentOsProtocols(): void {
  for (const protocol of agentOsProtocols) {
    const byCode = findProtocol(protocol.code);
    const byName = findProtocol(protocol.name);

    if (byCode == null && byName == null) {
      registry.addProtocol(protocol);
      continue;
    }

    if (byCode?.name !== protocol.name || byName?.code !== protocol.code) {
      throw new AgentAddressError(
        `Multiaddr protocol collision for ${protocol.name}/${protocol.code}`,
      );
    }
  }
}

registerAgentOsProtocols();

function componentValue(component: Component, name: string): string {
  if (component.value == null || component.value === "") {
    throw new AgentAddressError(`Agent OS address component ${name} needs a value`);
  }

  return component.value;
}

function hasNames(components: Component[], names: string[]): boolean {
  return (
    components.length === names.length &&
    components.every((component, index) => component.name === names[index])
  );
}

export function parseAgentAddress(input: string): AgentAddress {
  let parsed;

  try {
    parsed = multiaddr(input);
  } catch (error) {
    throw new AgentAddressError(`Invalid Agent OS address: ${String(error)}`);
  }

  const address = parsed.toString();
  const components = parsed.getComponents();

  if (hasNames(components, ["local", "mate", "herdr"])) {
    return {
      address,
      location: "local",
      mateId: componentValue(components[1]!, "mate"),
      protocol: "herdr",
    };
  }

  if (
    hasNames(components, ["k8s", "namespace", "mate", "herdr"])
  ) {
    return {
      address,
      cluster: componentValue(components[0]!, "k8s"),
      location: "kubernetes",
      mateId: componentValue(components[2]!, "mate"),
      namespace: componentValue(components[1]!, "namespace"),
      protocol: "herdr",
    };
  }

  throw new AgentAddressError(`Unsupported Agent OS address: ${address}`);
}

export function formatLocalAgentAddress(mateId: string): string {
  validateLabel(mateId, "mate ID");
  return parseAgentAddress(`/local/mate/${mateId}/herdr`).address;
}

export function formatKubernetesAgentAddress(
  mateId: string,
  options: KubernetesAddressOptions = {},
): string {
  const cluster = options.cluster ?? "in-cluster";
  const namespace = options.namespace ?? "agent-os";

  validateLabel(cluster, "k8s cluster alias");
  validateLabel(namespace, "namespace");
  validateLabel(mateId, "mate ID");

  return parseAgentAddress(
    `/k8s/${cluster}/namespace/${namespace}/mate/${mateId}/herdr`,
  ).address;
}
