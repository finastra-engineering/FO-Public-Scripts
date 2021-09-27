#!/bin/bash

# This script moves ARO apps into intrastructure nodes.
# It follows RHEL guide: https://access.redhat.com/solutions/5034771
#
# Infra nodes are:
#  label: node-role.kubernetes.io/infra: ""
#  taints:
#  - key: infra
#    value: reserved
#    effect: NoSchedule
#  - key: infra
#    value: reserved
#    effect: NoExecute


# Check if pods are running
checkStatus()
{
  LABEL="$1"
  NAMESPACE="$2"
  EXPECTED_PODS="$3"

  echo "...checking pod labels ${LABEL} at namespace ${NAMESPACE}..."
  ATTEMPTS=0
  until [[ $ATTEMPTS -ge 10 ]]
  do
    PODS_READY=$(oc get pod  -l "${1}" --field-selector=status.phase==Running -o jsonpath="{.items[*].metadata.name}" -n"${NAMESPACE}" | wc -w)
    if [[ $PODS_READY -eq $EXPECTED_PODS ]]; then
      echo "...found expected pods running"
      break
    fi
    ATTEMPTS=$((ATTEMPTS+1))
    echo "Sleep 10s and check again."
    sleep 10
  done
  if [[ $PODS_READY -ne $EXPECTED_PODS ]]; then
    echo "...not found expected pods. exit"
    exit 1
  fi
}

# create config map to move
monitoringConfigMap()
{
  cat <<EOT > cluster-monitoring-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    alertmanagerMain:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
    grafana:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
    k8sPrometheusAdapter:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
    kubeStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: infra
        value: reserved
        effect: NoSchedule
      - key: infra
        value: reserved
        effect: NoExecute
EOT
}

# exit in case of any errors
set -e

echo "Moving apps into infra nodes..."

# Check if infra nodes are available
INFRA_NODES=$(oc get nodes -l node-role.kubernetes.io/infra -o jsonpath='{.items[*].metadata.name}' | wc -w)

if [[ $INFRA_NODES -lt 3 ]]; then
  echo "Required at least 3 infra nodes to be available. Exit"
  exit 1
else
  echo "...available infra nodes: ${INFRA_NODES}"
fi

# Default router
echo "...moving default Router"
oc patch ingresscontroller/default -n  openshift-ingress-operator  --type=merge -p '{"spec":{"nodePlacement": {"nodeSelector": {"matchLabels": {"node-role.kubernetes.io/infra": ""}},"tolerations": [{"effect":"NoSchedule","key": "infra","value": "reserved"},{"effect":"NoExecute","key": "infra","value": "reserved"}]}}}'
# scale up to 3 replicas
oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge -p '{"spec":{"replicas": 3}}'

checkStatus "ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default" "openshift-ingress" "3"
echo "...default Router moved"

# Registry
echo "...moving Registry"
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"nodeSelector": {"node-role.kubernetes.io/infra": ""},"tolerations": [{"effect":"NoSchedule","key": "infra","value": "reserved"},{"effect":"NoExecute","key": "infra","value": "reserved"}]}}'

checkStatus "docker-registry=default" "openshift-image-registry" "2"
echo "...default Registry moved"

# Monitoring
echo "...moving Monitoring stack"
monitoringConfigMap
oc apply -f cluster-monitoring-configmap.yaml
checkStatus "app=alertmanager" "openshift-monitoring" "3"
checkStatus "app=grafana" "openshift-monitoring" "1"
checkStatus "app.kubernetes.io/name=kube-state-metrics" "openshift-monitoring" "1"
checkStatus "k8s-app=openshift-state-metrics" "openshift-monitoring" "1"
checkStatus "name=prometheus-adapter" "openshift-monitoring" "2"
checkStatus "app=prometheus" "openshift-monitoring" "2"
echo "...Monitoring stack moved"
echo "done"