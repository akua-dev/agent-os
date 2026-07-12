import akua.ctx

schema Input:
    """Inputs for one persistent Firstmate in a dedicated intelligence cluster."""

    namespace: str = "agent-os"
    createNamespace: bool = True
    image: str = "ghcr.io/akua-dev/agent-os:latest"
    imagePullPolicy: "Always" | "IfNotPresent" | "Never" = "IfNotPresent"
    clusterAdmin: bool = True
    akuaAuthSecret: str = ""
    storage: str = "20Gi"
    cpuRequest: str = "500m"
    memoryRequest: str = "1Gi"
    cpuLimit: str = "4"
    memoryLimit: str = "8Gi"

input: Input = ctx.input()

labels = {
    "app.kubernetes.io/name" = "agent-os"
    "app.kubernetes.io/component" = "firstmate"
}

akuaAuthMounts = [{
    name = "akua-auth"
    mountPath = "/var/run/secrets/agent-os/akua"
    readOnly = True
}] if input.akuaAuthSecret else []

akuaAuthVolumes = [{
    name = "akua-auth"
    secret = {
        secretName = input.akuaAuthSecret
        defaultMode = 256
    }
}] if input.akuaAuthSecret else []

akuaAuthEnv = [{
    name = "AKUA_AUTH_HEADER_FILE"
    value = "/var/run/secrets/agent-os/akua/authorization"
}] if input.akuaAuthSecret else []

namespaceResources = [{
    apiVersion = "v1"
    kind = "Namespace"
    metadata = {
        name = input.namespace
        labels = { "app.kubernetes.io/part-of" = "agent-os" }
    }
}] if input.createNamespace else []

adminResources = [{
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind = "ClusterRoleBinding"
    metadata = {
        name = "agent-os-firstmate-${input.namespace}"
        labels = labels
    }
    roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind = "ClusterRole"
        name = "cluster-admin"
    }
    subjects = [{
        kind = "ServiceAccount"
        name = "agent-os-firstmate"
        namespace = input.namespace
    }]
}] if input.clusterAdmin else []

resources = namespaceResources + [
    {
        apiVersion = "v1"
        kind = "ServiceAccount"
        metadata = {
            name = "agent-os-firstmate"
            namespace = input.namespace
            labels = labels
        }
    },
    {
        apiVersion = "v1"
        kind = "PersistentVolumeClaim"
        metadata = {
            name = "agent-os-firstmate-home"
            namespace = input.namespace
            labels = labels
        }
        spec = {
            accessModes = ["ReadWriteOnce"]
            resources = { requests = { storage = input.storage } }
        }
    },
    {
        apiVersion = "v1"
        kind = "Service"
        metadata = {
            name = "agent-os-firstmate"
            namespace = input.namespace
            labels = labels
        }
        spec = {
            clusterIP = "None"
            selector = labels
        }
    },
] + adminResources + [
    {
        apiVersion = "apps/v1"
        kind = "StatefulSet"
        metadata = {
            name = "agent-os-firstmate"
            namespace = input.namespace
            labels = labels
        }
        spec = {
            serviceName = "agent-os-firstmate"
            replicas = 1
            selector = { matchLabels = labels }
            template = {
                metadata = {
                    labels = labels
                    annotations = {
                        "agent-os.akua.dev/address" = "/k8s/in-cluster/namespace/${input.namespace}/mate/firstmate/herdr"
                    }
                }
                spec = {
                    serviceAccountName = "agent-os-firstmate"
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
                        name = "firstmate"
                        image = input.image
                        imagePullPolicy = input.imagePullPolicy
                        env = [
                            { name = "FM_HOME", value = "/home/agent" },
                            { name = "HOME", value = "/home/agent" },
                            { name = "AKUA_API_URL", value = "https://api.akua.dev/v1" },
                        ] + akuaAuthEnv
                        readinessProbe = {
                            exec = { command = ["herdr", "status", "--json"] }
                            initialDelaySeconds = 2
                            periodSeconds = 5
                        }
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
                        ] + akuaAuthMounts
                    }]
                    volumes = [{
                        name = "home"
                        persistentVolumeClaim = { claimName = "agent-os-firstmate-home" }
                    }] + akuaAuthVolumes
                }
            }
        }
    },
]
