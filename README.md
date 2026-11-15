# ShopLite GitOps

The desired state of every ShopLite environment. Argo CD watches this repository and makes the
cluster match it; nothing is deployed by hand or by CI. The app, its Helm chart and the monitoring
configuration live in [shoplite-app](https://github.com/proatik/shoplite-app).
The checkpoint screenshots are published at <https://shoplite-evidence.netlify.app/>.

## Layout

```text
shoplite-gitops/
├── apps/
│   ├── root.yaml                 the one Application bootstrap applies; it creates all the others
│   └── argocd-applications/      one Application per environment and per platform component
├── envs/
│   ├── dev/values.yaml           Helm values for shoplite-dev
│   └── prod/values.yaml          Helm values for shoplite (prod)
├── bootstrap/                    what Argo CD cannot install for itself
└── scripts/chaos.sh              plants one hidden fault in prod when no peer is available
```

## Environments

| Environment | Namespace      | URL                        | Argo CD sync         | Image tag                     |
| ----------- | -------------- | -------------------------- | -------------------- | ----------------------------- |
| dev         | `shoplite-dev` | `http://<alb>:8080/`       | automatic, self-heal | written by CI on each release |
| prod        | `shoplite`     | `http://<alb>/` and `/api` | manual               | promoted from dev by a commit |

Argo CD offers self-heal only together with automatic sync, so dev reverts manual changes on its
own; prod changes only when someone presses **Sync**, after reviewing the diff.

## Platform

| Application                     | Installs                                       | Sync wave |
| ------------------------------- | ---------------------------------------------- | --------- |
| `kube-prometheus-stack`         | Prometheus, Alertmanager, Grafana              | 0         |
| `loki`, `tempo`, `alloy`        | logs, traces and log shipping                  | 0         |
| `dashboards`                    | the Golden Signals dashboard from shoplite-app | 1         |
| `alert-rules`                   | the five alerts from shoplite-app              | 1         |
| `shoplite-dev`, `shoplite-prod` | the app chart with each environment's values   | 2         |

The monitoring Applications take their values from `shoplite-app/monitoring/values`, so the stack
and the app change together.

## Bootstrap a cluster

Run once per cluster, after Ansible has built it and fetched the kubeconfig:

```bash
export KUBECONFIG=~/.kube/shoplite.yaml
export KEYS_DIR=<folder with argocd-shoplite-app and argocd-shoplite-gitops>
export SLACK_WEBHOOK_FILE=<file holding the Slack webhook url>
export ALB_HOSTNAME=<the ALB dns name, from terraform output url>
./bootstrap/bootstrap.sh
```

It installs Traefik (prod on NodePort 30080, dev on 30081, reporting the ALB as every Ingress's
address so Argo CD can mark it Healthy), metrics-server for the worker's autoscaler and Argo CD,
then applies `apps/root.yaml`. It also creates the secrets that never enter Git: a random database
password per environment, the Grafana admin login and the Slack webhook. A secret that already
exists is kept, so running it again is safe.

Argo CD reads both repositories with read-only deploy keys; CI writes the image tag here
with its own write key.

## How a release reaches the browser

1. A change merges into `shoplite-app` `main`.
2. CI tests it, builds the images tagged with the short commit SHA, scans them and pushes them to
   ECR.
3. CI commits the new tag to `envs/dev/values.yaml` in this repository.
4. Argo CD sees the commit and rolls dev out; the change is live on `http://<alb>:8080/` without
   any manual command.
5. To promote, copy the `image` block into `envs/prod/values.yaml`, commit it, and sync
   `shoplite-prod` in Argo CD.

## Self-healing

Edit any resource of dev by hand, for example
`kubectl -n shoplite-dev scale deploy/web --replicas=1`: Argo CD sees the drift and restores the
state in Git within seconds.

## Chaos exercise

1. A peer gets write access to this repository for one hour. Without a peer,
   `scripts/chaos.sh` plays that part and does not say which flag it chose. Run it on a
   machine that can push to this repository: the cluster's deploy keys are read-only.
2. The peer turns on one flag under `catalogApi.chaos` or `orderWorker.chaos` in
   `envs/prod/values.yaml` and commits it with an innocuous message.
3. The operator syncs `shoplite-prod` as a routine release without opening the diff, then
   investigates with Grafana alone, following the runbooks in
   `shoplite-app/monitoring/runbooks`.
4. Recovery: `git revert` the peer's commit, push, and sync `shoplite-prod`.
