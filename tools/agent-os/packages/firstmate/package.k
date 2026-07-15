import akua.ctx
import regex

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
    operationId: str = ""
    serviceAccountName: str = "agent-os-firstmate"

    check:
        allowMutableImage or regex.match(image, r"^((([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*|(\[(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:(?:(?::[0-9A-Fa-f]{1,4}){1,6})|:(?:(?::[0-9A-Fa-f]{1,4}){1,7}|:))\]))(:[0-9]+)?)/)?[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(\/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[0-9a-f]{64}$") or regex.match(image, r"^\[(?:(?:[0-9A-Fa-f]{1,4}:){6}|::(?:[0-9A-Fa-f]{1,4}:){0,5}|[0-9A-Fa-f]{1,4}::(?:[0-9A-Fa-f]{1,4}:){0,4}|(?:[0-9A-Fa-f]{1,4}:){1}[0-9A-Fa-f]{1,4}::(?:[0-9A-Fa-f]{1,4}:){0,3}|(?:[0-9A-Fa-f]{1,4}:){2}[0-9A-Fa-f]{1,4}::(?:[0-9A-Fa-f]{1,4}:){0,2}|(?:[0-9A-Fa-f]{1,4}:){3}[0-9A-Fa-f]{1,4}::(?:[0-9A-Fa-f]{1,4}:){0,1}|(?:[0-9A-Fa-f]{1,4}:){4}[0-9A-Fa-f]{1,4}::)(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}\](:[0-9]+)?\/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*(\/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[0-9a-f]{64}$"), "image must use one complete OCI reference with an immutable @sha256 digest unless the local profile explicitly allows a mutable image"
        operationId == "" or regex.match(operationId, r"^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?$"), "operationId must be empty or a valid Kubernetes label value"
        regex.match(serviceAccountName, r"^agent-os-firstmate(-[a-z0-9]{12})?$"), "serviceAccountName must be the deterministic legacy name or a lifecycle-generated installation identity"

input: Input = ctx.input()

selectorLabels = {
    "app.kubernetes.io/name" = "agent-os"
    "app.kubernetes.io/component" = "firstmate"
    "app.kubernetes.io/managed-by" = "agent-os"
}
labels = selectorLabels | ({ "agent-os.dev/operation-id" = input.operationId } if input.operationId != "" else {})

installationId = "agent-os-firstmate:${input.namespace}"
ownershipAnnotations = { "agent-os.dev/installation-id" = installationId }

namespaceResources = [{
    apiVersion = "v1"
    kind = "Namespace"
    metadata = {
        name = input.namespace
        labels = labels | { "app.kubernetes.io/part-of" = "agent-os" }
        annotations = ownershipAnnotations
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
            annotations = ownershipAnnotations
        }
        rules = [
            {
                apiGroups = [""]
                resources = ["pods", "persistentvolumeclaims"]
                verbs = ["get", "list", "watch", "create", "delete", "patch"]
            },
            {
                apiGroups = [""]
                resources = ["pods/log", "pods/exec"]
                verbs = ["get", "list", "watch", "create", "delete"]
            },
            {
                apiGroups = ["apps"]
                resources = ["statefulsets"]
                verbs = ["get", "list", "watch"]
            },
            {
                apiGroups = ["coordination.k8s.io"]
                resources = ["leases"]
                verbs = ["get", "create", "update", "delete"]
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
            annotations = ownershipAnnotations
        }
        roleRef = {
            apiGroup = "rbac.authorization.k8s.io"
            kind = "Role"
            name = "agent-os-firstmate-runtime"
        }
        subjects = [{
            kind = "ServiceAccount"
            name = input.serviceAccountName
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
        annotations = ownershipAnnotations
    }
    roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind = "ClusterRole"
        name = "cluster-admin"
    }
    subjects = [{
        kind = "ServiceAccount"
        name = input.serviceAccountName
        namespace = input.namespace
    }]
}] if input.rbac == "cluster-admin" else []

resources = namespaceResources + [
    {
        apiVersion = "v1"
        kind = "ServiceAccount"
        metadata = {
            name = input.serviceAccountName
            namespace = input.namespace
            labels = labels
            annotations = ownershipAnnotations
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
            annotations = ownershipAnnotations
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
            annotations = ownershipAnnotations
        }
        spec = {
            clusterIP = "None"
            selector = selectorLabels
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
            annotations = ownershipAnnotations | {
                "agent-os.dev/rbac-mode" = input.rbac
            }
        }
        spec = {
            serviceName = "agent-os-firstmate"
            replicas = 1
            selector = { matchLabels = selectorLabels }
            template = {
                metadata = {
                    labels = labels
                    annotations = {
                        "agent-os.dev/address" = "/k8s/in-cluster/namespace/${input.namespace}/mate/firstmate/herdr"
                    }
                }
                spec = {
                    serviceAccountName = input.serviceAccountName
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
