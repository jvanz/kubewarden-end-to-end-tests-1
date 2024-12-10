#!/usr/bin/env bats

# UI access:
# kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-operated 9090
# kubectl port-forward -n jaeger svc/my-open-telemetry-query 16686:16686

setup() {
    load ../helpers/helpers.sh
    wait_pods -n kube-system
}

teardown_file() {
    load ../helpers/helpers.sh
    kubectl delete admissionpolicies,clusteradmissionpolicies --all -A
    kubectl delete pod nginx-privileged nginx-unprivileged --ignore-not-found

    # Remove installed apps
    helm uninstall --wait -n jaeger jaeger-operator
    helm uninstall --wait -n prometheus prometheus
    helm uninstall --wait -n open-telemetry my-opentelemetry-operator
    helm uninstall --wait -n cert-manager cert-manager

    helmer reset controller
}

# get_metrics policy-server-default
function get_metrics {
    pod=$1
    ns=${2:-$NAMESPACE}

    kubectl delete pod curlpod --ignore-not-found
    kubectl run curlpod -t -i --rm --image curlimages/curl:8.10.1 --restart=Never -- \
        --silent $pod.$ns.svc.cluster.local:8080/metrics
}
export -f get_metrics # required by retry command

@test "[OpenTelemetry] Install OpenTelemetry, Prometheus, Jaeger" {
    # Required by OpenTelemetry
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm upgrade -i --wait cert-manager jetstack/cert-manager \
        -n cert-manager --create-namespace \
        --set crds.enabled=true

    # OpemTelementry
    helm repo add --force-update open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm upgrade -i --wait my-opentelemetry-operator open-telemetry/opentelemetry-operator \
        --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
        -n open-telemetry --create-namespace

    # Prometheus
    helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts
    helm upgrade -i --wait prometheus prometheus-community/kube-prometheus-stack \
        -n prometheus --create-namespace \
        --values $RESOURCES_DIR/opentelemetry-prometheus.yaml

    # Jaeger
    helm repo add --force-update jaegertracing https://jaegertracing.github.io/helm-charts
    helm upgrade -i --wait jaeger-operator jaegertracing/jaeger-operator \
        -n jaeger --create-namespace \
        --set rbac.clusterRole=true

    kubectl apply -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    wait_pods -n jaeger

    # Setup Kubewarden
    helmer set kubewarden-controller --values $RESOURCES_DIR/opentelemetry-telemetry.yaml
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=True
}

@test "[OpenTelemetry] Kubewarden containers have sidecars & metrics" {
    # Controller is restarted to get sidecar
    wait_pods -n $NAMESPACE

    # Check all pods have sidecar (otc-container) - might take a minute to start
    retry "kubectl get pods -n kubewarden --field-selector=status.phase==Running -o json | jq -e '[.items[].spec.containers[1].name == \"otc-container\"] | all'"
    # Policy server service has the metrics ports
    kubectl get services -n $NAMESPACE  policy-server-default -o json | jq -e '[.spec.ports[].name == "metrics"] | any'
    # Controller service has the metrics ports
    kubectl get services -n $NAMESPACE kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name == "metrics"] | any'

    # Generate metric data
    kubectl run pod-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod pod-privileged
    kubectl delete --wait pod pod-privileged

    # Policy server & controller metrics should be available
    retry 'test $(get_metrics policy-server-default | wc -l) -gt 10'
    retry 'test $(get_metrics kubewarden-controller-metrics-service | wc -l) -gt 1'
}

@test "[OpenTelemetry] Audit scanner runs should generate metrics" {
    kubectl get cronjob -n $NAMESPACE audit-scanner

    # Launch unprivileged & privileged pods
    kubectl run nginx-unprivileged --image=nginx:alpine
    kubectl wait --for=condition=Ready pod nginx-unprivileged
    kubectl run nginx-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod nginx-privileged

    # Deploy some policy
    apply_policy --no-wait privileged-pod-policy.yaml
    apply_policy namespace-label-propagator-policy.yaml

    trigger_audit_scan
    retry 'test $(get_metrics policy-server-default | grep protect | grep -oE "policy_name=\"[^\"]+" | sort -u | wc -l) -eq 2'
}

@test "[OpenTelemetry] Disabling telemetry should remove sidecars & metrics" {
    helmer set kubewarden-controller \
        --set telemetry.metrics=False \
        --set telemetry.tracing=False
    helmer set kubewarden-defaults --set recommendedPolicies.enabled=False
    wait_pods -n $NAMESPACE

    # Check sidecars (otc-container) - have been removed
    retry "kubectl get pods -n kubewarden -o json | jq -e '[.items[].spec.containers[1].name != \"otc-container\"] | all'"
    # Policy server service has no metrics ports
    kubectl get services -n $NAMESPACE policy-server-default -o json | jq -e '[.spec.ports[].name != "metrics"] | all'
    # Controller service has no metrics ports
    kubectl get services -n $NAMESPACE kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name != "metrics"] | all'
}
