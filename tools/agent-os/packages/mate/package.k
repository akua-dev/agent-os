import akua.ctx

schema Input:
    """Inputs for one general-purpose Kubernetes-backed Agent OS mate."""

    mateId: str
    namespace: str = "agent-os"
    address: str
    image: str = "agent-os:dev"
    imagePullPolicy: "Always" | "IfNotPresent" | "Never" = "IfNotPresent"
    piAuthSecret: str = ""
    storage: str = "10Gi"
    cpuRequest: str = "250m"
    memoryRequest: str = "512Mi"
    cpuLimit: str = "2"
    memoryLimit: str = "4Gi"

    check:
        len(mateId) <= 43, "mateId must leave room for the agent-os-mate- resource prefix"

input: Input = ctx.input()

labels = {
    "app.kubernetes.io/name" = "agent-os"
    "app.kubernetes.io/component" = "mate"
    "agent-os.akua.dev/mate" = input.mateId
}

piAuthMounts = [{
    name = "pi-auth"
    mountPath = "/home/agent/.pi/agent/auth.json"
    subPath = "auth.json"
    readOnly = True
}] if input.piAuthSecret else []

piAuthVolumes = [{
    name = "pi-auth"
    secret = {
        secretName = input.piAuthSecret
        defaultMode = 256
    }
}] if input.piAuthSecret else []

resources = [
    {
        apiVersion = "v1"
        kind = "PersistentVolumeClaim"
        metadata = {
            name = "agent-os-mate-${input.mateId}-home"
            namespace = input.namespace
            labels = labels
        }
        spec = {
            accessModes = ["ReadWriteOnce"]
            resources = {
                requests = { storage = input.storage }
            }
        }
    },
    {
        apiVersion = "v1"
        kind = "Pod"
        metadata = {
            name = "agent-os-mate-${input.mateId}"
            namespace = input.namespace
            labels = labels
            annotations = {
                "agent-os.akua.dev/address" = input.address
            }
        }
        spec = {
            automountServiceAccountToken = False
            securityContext = {
                fsGroup = 0
                runAsGroup = 0
                runAsUser = 0
            }
            initContainers = [{
                name = "agent-os-init"
                image = input.image
                imagePullPolicy = input.imagePullPolicy
                command = ["/opt/agent-os/bin/agent-os-init.sh"]
                volumeMounts = [{
                    name = "home"
                    mountPath = "/persistent-agent"
                }]
            }]
            containers = [{
                name = "mate"
                image = input.image
                imagePullPolicy = input.imagePullPolicy
                env = [
                    { name = "FM_HOME", value = "/home/agent" },
                    { name = "HOME", value = "/home/agent" },
                ]
                resources = {
                    requests = {
                        cpu = input.cpuRequest
                        memory = input.memoryRequest
                    }
                    limits = {
                        cpu = input.cpuLimit
                        memory = input.memoryLimit
                    }
                }
                volumeMounts = [
                    { name = "home", mountPath = "/home/agent" },
                    { name = "home", mountPath = "/usr/local", subPath = "usr-local" },
                ] + piAuthMounts
            }]
            volumes = [{
                name = "home"
                persistentVolumeClaim = { claimName = "agent-os-mate-${input.mateId}-home" }
            }] + piAuthVolumes
        }
    },
]
