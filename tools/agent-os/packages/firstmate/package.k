import akua.ctx

schema Input:
    """Inputs for one persistent Firstmate on a conformant Kubernetes cluster."""

    namespace: str = "agent-os"
    createNamespace: bool = True
    image: str
    imagePullPolicy: "Always" | "IfNotPresent" | "Never" = "IfNotPresent"
    allowMutableImage: bool = False
    rbac: "namespace" | "cluster-admin" | "none" = "namespace"
    storage: str = "20Gi"
    cpuRequest: str = "500m"
    memoryRequest: str = "1Gi"
    cpuLimit: str = "4"
    memoryLimit: str = "8Gi"

    check:
        allowMutableImage or "@sha256:" in image, "image must use an immutable @sha256 digest unless the local profile explicitly allows a mutable image"

input: Input = ctx.input()

labels = {
    "app.kubernetes.io/name" = "agent-os"
    "app.kubernetes.io/component" = "firstmate"
}

namespaceResources = [{
    apiVersion = "v1"
    kind = "Namespace"
    metadata = {
        name = input.namespace
        labels = { "app.kubernetes.io/part-of" = "agent-os" }
    }
}] if input.createNamespace else []

namespaceRbacResources = [
    {
        apiVersion = "rbac.authorization.k8s.io/v1"
        kind = "Role"
        metadata = {
            name = "agent-os-firstmate-runtime"
            namespace = input.namespace
            labels = labels
        }
        rules = [
            {
                apiGroups = [""]
                resources = ["pods", "pods/log", "pods/exec", "persistentvolumeclaims"]
                verbs = ["get", "list", "watch", "create", "delete"]
            },
            {
                apiGroups = ["apps"]
                resources = ["statefulsets"]
                verbs = ["get", "list", "watch"]
            },
        ]
    },
    {
        apiVersion = "rbac.authorization.k8s.io/v1"
        kind = "RoleBinding"
        metadata = {
            name = "agent-os-firstmate-runtime"
            namespace = input.namespace
            labels = labels
        }
        roleRef = {
            apiGroup = "rbac.authorization.k8s.io"
            kind = "Role"
            name = "agent-os-firstmate-runtime"
        }
        subjects = [{
            kind = "ServiceAccount"
            name = "agent-os-firstmate"
            namespace = input.namespace
        }]
    },
] if input.rbac == "namespace" else []

clusterAdminResources = [{
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
}] if input.rbac == "cluster-admin" else []

resources = namespaceResources + [
    {
        apiVersion = "v1"
        kind = "ServiceAccount"
        metadata = {
            name = "agent-os-firstmate"
            namespace = input.namespace
            labels = labels
        }
        automountServiceAccountToken = True
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
] + namespaceRbacResources + clusterAdminResources + [
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
                        "agent-os.dev/address" = "/k8s/in-cluster/namespace/${input.namespace}/mate/firstmate/herdr"
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
                            { name = "AGENT_OS_NAMESPACE", value = input.namespace },
                            { name = "AGENT_OS_IMAGE", value = input.image },
                            { name = "AGENT_OS_IMAGE_PULL_POLICY", value = input.imagePullPolicy },
                        ]
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
                        ]
                    }]
                    volumes = [{
                        name = "home"
                        persistentVolumeClaim = { claimName = "agent-os-firstmate-home" }
                    }]
                }
            }
        }
    },
]
