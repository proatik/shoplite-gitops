#!/usr/bin/env bash
# Installs what Argo CD cannot manage for itself, creates the secrets that never enter Git,
# then hands everything else to Argo CD through apps/root.yaml. Safe to run again.
#
#   KUBECONFIG          the k3s cluster (ansible fetches ~/.kube/shoplite.yaml)
#   KEYS_DIR            folder with argocd-shoplite-app and argocd-shoplite-gitops, the read-only deploy keys
#   SLACK_WEBHOOK_FILE  file holding the Slack incoming-webhook url for alerts
#   ALB_HOSTNAME        the ALB's dns name, which Traefik reports as every Ingress's address
set -euo pipefail

cd "$(dirname "$0")/.."
: "${KUBECONFIG:?point KUBECONFIG at the k3s cluster}"
: "${KEYS_DIR:?set KEYS_DIR to the folder holding the read-only deploy keys}"
: "${SLACK_WEBHOOK_FILE:?set SLACK_WEBHOOK_FILE to the file holding the Slack webhook url}"
: "${ALB_HOSTNAME:?set ALB_HOSTNAME to the ALB dns name, from terraform output url}"

TRAEFIK_VERSION=42.3.1
METRICS_SERVER_VERSION=3.14.0
ARGOCD_VERSION=10.17.1

helm repo add traefik https://traefik.github.io/charts --force-update > /dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update > /dev/null
helm repo add argo https://argoproj.github.io/argo-helm --force-update > /dev/null

helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_VERSION" \
  --namespace traefik --create-namespace --values bootstrap/traefik.yaml \
  --set providers.kubernetesIngress.ingressEndpoint.hostname="$ALB_HOSTNAME" --wait
helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_SERVER_VERSION" \
  --namespace kube-system --values bootstrap/metrics-server.yaml --wait

apply() { kubectl apply -f - > /dev/null; }
for namespace in shoplite shoplite-dev monitoring; do
  kubectl create namespace "$namespace" --dry-run=client -o yaml | apply
done

# a secret is created only when missing: a new database password would lock out the existing data.
create_once() {
  local namespace=$1 name=$2
  shift 2
  if ! kubectl -n "$namespace" get secret "$name" > /dev/null 2>&1; then
    kubectl -n "$namespace" create secret generic "$name" "$@" > /dev/null
    echo "created secret $namespace/$name"
  fi
}
for namespace in shoplite shoplite-dev; do
  create_once "$namespace" shoplite-db --from-literal=password="$(openssl rand -hex 24)"
done
create_once monitoring grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -hex 16)"
kubectl -n monitoring create secret generic alertmanager-slack --from-file=webhook-url="$SLACK_WEBHOOK_FILE" \
  --dry-run=client -o yaml | apply

helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_VERSION" \
  --namespace argocd --create-namespace --values bootstrap/argocd.yaml --wait

for repo in shoplite-app shoplite-gitops; do
  kubectl -n argocd create secret generic "repo-$repo" \
    --from-literal=type=git --from-literal=url="git@github.com:proatik/$repo.git" \
    --from-file=sshPrivateKey="$KEYS_DIR/argocd-$repo" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | apply
done

kubectl apply -f apps/root.yaml
echo 'argo cd now syncs everything else; grafana password: kubectl -n monitoring get secret grafana-admin -o jsonpath={.data.admin-password} | base64 -d'
