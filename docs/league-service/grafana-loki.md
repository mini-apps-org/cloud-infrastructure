# league-service — Loki in Grafana

Ships league's logs to **Grafana Cloud Loki** and adds it as a data source in the Grafana from
[grafana.md](grafana.md), so you can query logs with LogQL and browse them in **Logs Drilldown**.

```
league pod ──stdout──▶ Alloy ──push (write token)──▶ Grafana Cloud Loki ◀──query (read token)── Grafana
                   (monitoring ns, league-cluster)
```

- **Loki runs on Grafana Cloud**, free tier. Only Alloy, a small collector (64Mi), runs on
  `league-cluster` — the node is short on memory.
- **Cloud Logging keeps working.** Loki is an addition, not a replacement; for Cloud Logging see
  [cloud-logging.md](cloud-logging.md). Why Alloy and not Promtail: [alloy-vs-promtail.md](alloy-vs-promtail.md).

**Before you start:** Grafana is installed ([grafana.md](grafana.md)), `kubectl` points at
`league-cluster`, and you run commands from the repo root.

---

## The four values you need

Every step below uses one of these. Collect them first (steps 1–2), and keep this table open.

| Value | Looks like | Where to find it | Used in |
| --- | --- | --- | --- |
| **Loki URL** | `https://logs-prod-020.grafana.net` | Cloud portal → your stack → **Loki → Details** → URL | Step 3 (+ `/loki/api/v1/push`), step 5 (as is) |
| **Loki User** | `1234567` | Same page → **User** | Step 3 and step 5 |
| **Write token** | `glc_…` | Step 2, policy `league-logs-write` | Step 3 only (Alloy) |
| **Read token** | `glc_…` | Step 2, policy `league-logs-read` | Step 5 only (Grafana) |

Mistakes that cost time:

- **User is the Loki User only.** The stack page also shows a Prometheus user, a Tempo user, an
  org ID and a stack ID — all different numbers, all rejected here.
- **Tokens are not interchangeable.** The read token can't push; the write token can't query.
- **Not your login.** Your Grafana email and password don't work against the API.

---

## 1. Create the Grafana Cloud stack

1. Sign up at <https://grafana.com> and create a stack. The free tier covers league's volume;
   check the current limits on the pricing page.
2. Open the stack → **Loki → Details** (or **Send Logs**). Note the **URL** and **User**.

---

## 2. Create two access tokens

Cloud portal → **Security → Access Policies → Create access policy**. Set **realm** to the stack
from step 1 — a token from another stack is rejected as `invalid token`.

| Policy | Scope | Used by |
| --- | --- | --- |
| `league-logs-write` | `logs:write` | Alloy, to push |
| `league-logs-read` | `logs:read` | Grafana, to query |

On each policy, **Add token** and copy it right away — it's shown once. Two tokens keep each
side to the one permission it needs.

---

## 3. Store the write token for Alloy

Read the values into variables so the token stays out of your shell history:

```bash
read -r LOKI_USER                 # paste the Loki User
read -rs LOKI_TOKEN               # paste the WRITE token (input hidden)
LOKI_URL=https://logs-prod-020.grafana.net/loki/api/v1/push   # your URL + /loki/api/v1/push

kubectl -n monitoring create secret generic alloy-loki \
  --from-literal=LOKI_URL="$LOKI_URL" \
  --from-literal=LOKI_USERNAME="$LOKI_USER" \
  --from-literal=LOKI_PASSWORD="$LOKI_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Check — push one test line** with the same values:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -u "$LOKI_USER:$LOKI_TOKEN" \
  -H 'Content-Type: application/json' -X POST "$LOKI_URL" \
  -d "{\"streams\":[{\"stream\":{\"job\":\"alloy-secret-test\"},\"values\":[[\"$(date +%s)000000000\",\"hello\"]]}]}"
```

| Result | Means |
| --- | --- |
| `204` | Credentials work — continue |
| `401` | Wrong User/token pair, a token from another stack, or a bad paste. Redo step 3 |
| `403` | The token lacks `logs:write` — you used the read token |

Don't install Alloy until this returns `204`: Alloy drops what it can't push.

---

## 4. Install Alloy

```bash
helm repo add grafana https://grafana.github.io/helm-charts   # once
helm repo update grafana
helm upgrade --install alloy grafana/alloy --version 1.15.0 \
  -n monitoring -f helm/monitoring/alloy-values.yaml
kubectl -n monitoring rollout status deploy/alloy
```

`helm/monitoring/alloy-values.yaml` runs **one pod** (a Deployment, not a DaemonSet) that reads
logs through the Kubernetes API, allowed to read pods in `league` only. Its config is a pipeline,
read top to bottom:

| Component | Does |
| --- | --- |
| `discovery.kubernetes "pods"` | Finds the pods in `league` |
| `discovery.relabel "pods"` | Turns pod metadata into labels (table in step 6) |
| `loki.source.kubernetes "pods"` | Reads every container's logs — `league-service` and `cloud-sql-proxy` |
| `loki.process "app_logs"` | Parses each JSON line and adds `level` as a label |
| `loki.write "grafana_cloud"` | Pushes with the step 3 secret and adds `cluster="league-cluster"` |

**Check:**

```bash
kubectl -n monitoring logs deploy/alloy | grep -E 'tailer running'         # one line per container
kubectl -n monitoring logs deploy/alloy | grep -E 'level=(error|warn)'     # expect nothing
```

A quiet error log alone proves little — league logs only at startup and on failed requests, so
Alloy may have pushed nothing yet. Step 6's first query is the real check.

For a visual check: `kubectl -n monitoring port-forward deploy/alloy 12345:12345`, open
<http://localhost:12345>. All five components should be **Healthy**; click
`discovery.relabel.pods` to see each container's labels.

---

## 5. Add the Loki data source in Grafana

**Connections → Data sources → Add new data source → Loki**:

| Field | Value |
| --- | --- |
| Name | `league-loki` |
| URL | Loki URL, **no path**: `https://logs-prod-020.grafana.net` |
| Authentication | **Basic authentication**: User = Loki User, Password = **read token** |

**Save & test** → *Data source successfully connected*.

- Create **one** Loki data source. A second one left with an empty URL fails every query with
  `unsupported protocol scheme ""` — delete it.
- It's saved on Grafana's disk: it survives restarts, not a reinstall. Re-add it after one.

---

## 6. Query

**Explore → `league-loki`**, or **Drilldown → Logs** to browse by clicking.

Start every query from league's own container. `job` alone also matches the `cloud-sql-proxy`
sidecar in the same pod, whose connection lines would mix into every result:

```logql
{job="league/league-service", container="league-service"}
```

Then add to it (`{…}` below is the selector above):

| Looking for | LogQL |
| --- | --- |
| Warnings and errors | `{…, level=~"WARN\|ERROR"}` |
| Server errors | `{…} \| json \| status >= 500` |
| One request | `{…} \| json \| request_id="<id>"` |
| One endpoint | `{…} \| json \| path="/api/v1/me"` |
| Text anywhere | `{…} \|= "no session cookie"` |
| One pod | `{…, pod="<pod name>"}` |
| Errors per minute | `sum(count_over_time({…, level="ERROR"}[1m]))` |
| Errors per minute, by pod | `sum by (pod) (count_over_time({…, level="ERROR"}[1m]))` |
| Database proxy logs | `{job="league/league-service", container="cloud-sql-proxy"}` |

What league logs, and which fields `| json` gives you: [cloud-logging.md §1](cloud-logging.md#1-what-league-logs).
In short — only **failed** requests are logged, 4xx at `WARN`, 5xx at `ERROR`.

### Labels

Labels are indexed: select on them inside `{}`. Everything else is parsed at query time with
`| json`, which costs nothing to store.

| Label | Value for league |
| --- | --- |
| `cluster` | `league-cluster` |
| `namespace` | `league` |
| `app` | `league-service` (the pod's `app` label) |
| `job` | `league/league-service` |
| `container` | `league-service` or `cloud-sql-proxy` |
| `pod`, `node_name` | Per pod |
| `level` | From the JSON line: `DEBUG`, `INFO`, `WARN`, `ERROR`. Not set on `cloud-sql-proxy` lines, which log `severity` instead — filter those with `\| json \| severity="ERROR"` |
| `instance`, `component` | Not set: league's pods don't carry `app.kubernetes.io/instance` or `…/component` |

Logs shipped before the current config only have `namespace`, `pod`, `container` and `level`.
To search across both, use `{namespace="league", container="league-service"}`.

---

## 7. Troubleshooting

Work left to right along the pipeline: Alloy → Loki → Grafana.

| Symptom | Cause | Fix |
| --- | --- | --- |
| Alloy log: `status=401 … invalid token` | Write token or User wrong, or token from another stack | Run the step 3 push test; recreate the secret; `kubectl -n monitoring rollout restart deploy/alloy` |
| Alloy log: `status=403` | Read token stored as the write token | Step 3 with the write token, then restart |
| Alloy log: `pods is forbidden` | Namespace in discovery but not in `rbac.namespaces` | Add it to both lists (§8), upgrade, restart |
| No `tailer running` lines | Alloy can't see any pods | Check `namespaces.names` and that league pods are running |
| Grafana label browser empty, **Save & test** passes | Loki has no data yet — Alloy isn't pushing | Fix Alloy first (rows above); labels appear once logs arrive |
| Grafana: `unsupported protocol scheme ""` | Selected data source has no URL | Use `league-loki`; delete the empty one |
| Grafana: `401` on **Save & test** | Read token or User wrong | Re-enter them in step 5 |
| Proxy lines (`Accepted connection …`) in results | Selector matches the whole pod | Add `container="league-service"` to the selector |

Changed the secret? Alloy reads it only at startup: `kubectl -n monitoring rollout restart deploy/alloy`.

---

## 8. Changing the Alloy config

1. Edit `helm/monitoring/alloy-values.yaml`.
2. Optional — check the syntax. Copy the `configMap.content` block into `config.alloy` without
   its 6-space indent, then:
   ```bash
   docker run --rm -v "$PWD/config.alloy:/c.alloy:ro" grafana/alloy:latest fmt /c.alloy
   ```
3. Apply and restart. The config reloader is off to save 50Mi, so Alloy only reads new config on
   restart:
   ```bash
   helm upgrade alloy grafana/alloy --version 1.15.0 \
     -n monitoring -f helm/monitoring/alloy-values.yaml
   kubectl -n monitoring rollout restart deploy/alloy
   ```
4. Check as in step 4.

| To | Change |
| --- | --- |
| Collect another namespace | Add it to `rbac.namespaces` **and** `namespaces { names = [...] }` — both, or it fails (`403`) or is skipped |
| Collect from another cluster | A second Alloy install on that cluster, with its own values file and `cluster` label. One Alloy only sees its own cluster |
| Skip a container (e.g. `cloud-sql-proxy`) | Add to the end of `discovery.relabel`: `rule { source_labels = ["container"] regex = "cloud-sql-proxy" action = "drop" }` |
| Add a label from a pod label | Add a `rule` in `discovery.relabel` with `source_labels = ["__meta_kubernetes_pod_label_<name>"]` |
| Promote a JSON field to a label | Add it to `stage.json` and `stage.labels` in `loki.process` — only for fields with few values, never `request_id` or `path` |
| Drop noisy lines | Add `stage.drop { expression = "<regex>" }` to `loki.process` |

More namespaces mean more memory (limit `192Mi`) and more free-tier volume — check
`kubectl -n monitoring top pod` and the Cloud portal's usage page as you add them.

---

## 9. Removing it

```bash
helm -n monitoring uninstall alloy
kubectl -n monitoring delete secret alloy-loki
```

Then delete the `league-loki` data source in Grafana and revoke both access policies in the Cloud
portal.
