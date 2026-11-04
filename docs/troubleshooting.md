# Troubleshooting

All three services. Every failure mode in the order a deploy can hit them — walk the phase that
matches where you are. Each box names the symptom, the cause, and the command that confirms it.

Substitute throughout: `SVC` is `auth`, `recommendations` or `league`; the namespace equals `SVC`
and the deployment, app container and KSA are all `SVC-service`. `make <target> SVC=<svc>` works
from the repo root.

Edge/HTTPS problems are in [edge-architecture.md](./edge-architecture.md#edge-symptoms).
Values are in [gke-parameters.md](./gke-parameters.md).

---

## Phase 0 — Read the failure before theorising

- [ ] `rollout status ... exceeded its progress deadline` names a **timer, not a cause** — the
      controller giving up after `progressDeadlineSeconds` because no pod became Ready. Raising it,
      or `--timeout`, fixes nothing. Always go to the pod.
- [ ] Pod status, not the Deployment's: `make ps SVC=<svc>`
- [ ] The `Events` block names the layer that failed: `make events SVC=<svc>`
- [ ] Confirm **which ReplicaSet generation** you are reading. `describe pod` on a pod from an old
      ReplicaSet shows a spec that no longer exists in the repo — pods are immutable, so editing a
      Deployment makes a new ReplicaSet and the old pod keeps its original spec forever:
      `kubectl -n <svc> get rs -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas'`
- [ ] Do not trust the Deployment's `Available` condition. With `replicas: 1` and
      `maxUnavailable: 1`, zero running pods still satisfies the minimum, so `Available: True`
      coexists with nothing running. Only `Progressing` reports the failure.
- [ ] Follow both containers at once:
      `kubectl -n <svc> logs -f deploy/<svc>-service --all-containers --prefix`
- [ ] Reach the app without involving the load balancer:
      `kubectl -n <svc> port-forward deploy/<svc>-service 8080:<port>` then
      `curl -s localhost:8080/api/v1/health`

---

## Phase 1 — Access and identity

- [ ] `kubectl` returns `Forbidden` naming an unexpected account → the **identity** is wrong, not
      the context. The kubeconfig holds no credential, only an `exec` hook that mints a token for
      whichever gcloud configuration is active right now, so switching configurations silently
      changes who `kubectl` is.
      `gcloud config get account` · `gcloud config configurations list` · `kubectl config current-context`
- [ ] The error reads like a missing IAM role → it usually is not. Fix the active gcloud
      configuration before editing bindings for an account that should not have had access.
- [ ] `gcloud` succeeds against the wrong project: `gcloud config get project`

---

## Phase 2 — Rendering and applying the manifests

- [ ] `kubectl apply --dry-run=server` fails with `namespaces "<svc>" not found` → not a bug.
      Server-side dry-run never persists the Namespace, so every namespaced object in the bundle
      validates against a namespace that does not exist. Render client-side instead:
      `kubectl kustomize k8s/<svc>-service`
- [ ] Kustomize labels leak into the selector → `includeSelectors` must stay `false`;
      `selector.matchLabels` is immutable after creation.
- [ ] A selector change is rejected → the Deployment must be deleted and recreated, not patched.

---

## Phase 3 — Pod `Pending`, never schedules

- [ ] `Insufficient cpu` → the sum of **requests** on the node exceeds allocatable. Requests, not
      usage, decide scheduling: the node can be almost idle and still refuse the pod.
      `kubectl describe node | sed -n '/Allocated resources/,/^Events/p'`
- [ ] `Insufficient memory` → same ledger, different column. Check both rows.
- [ ] A **crashlooping pod still holds its CPU request.** A pod that never becomes Ready is still a
      scheduled pod, so a broken old revision can be what blocks the new one.
- [ ] `NotTriggerScaleUp`, repeating or with an empty reason → the autoscaler has already declined.
      Not transient; nothing will rescue a `Pending` pod. Add capacity or lower requests —
      [cpu-capacity-options.md](./recommendations-service/cpu-capacity-options.md).
- [ ] Rollout deadlocks with `maxUnavailable: 0` → two copies must fit on one node for a surge
      strategy to work. If they do not, the old pod cannot leave until the new one is Ready and the
      new one cannot schedule until the old one leaves. `maxUnavailable: 1` / `maxSurge: 0` inverts
      the order (down to 0, then up to 1) and is **required** while the node is tight. The cost is a
      brief full outage per rollout — honest rather than regressive, since one replica never had a
      zero-downtime path.
- [ ] The node is near-fully reserved after a successful deploy → nothing further will schedule,
      including a second copy of this pod.

---

## Phase 4 — Pod scheduled, container will not start

- [ ] `CreateContainerConfigError` → the Secret is missing, or a key it names is absent.
      `envFrom.secretRef` is not optional, so the container config cannot be built and nothing
      runs — there will be no app logs at all.
      `kubectl -n <svc> get secret <svc>-service-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'`
      Want all four: `DB_PASSWORD`, `ENCRYPTION_KEY`, `GOOGLE_OAUTH_CLIENT_ID`,
      `GOOGLE_OAUTH_CLIENT_SECRET`.
- [ ] The Secret "does not exist" but you remember creating it → check whether it landed in
      **another namespace**. A `create secret` without `-n <svc>` silently targets the current
      context's namespace: `kubectl get secret -A | grep <svc>-service-secrets`
- [ ] Creating the Secret does not immediately fix the pod → the container is in a backoff timer.
      Force it: `make restart SVC=<svc>`
- [ ] `ImagePullBackOff` with `manifest unknown` / `name unknown` → the repo, tag or digest in
      `deployment.yaml` does not exist.
      `gcloud artifacts docker images list …/<svc>-repository --include-tags`
- [ ] `ImagePullBackOff` with `denied` / `unauthorized` / `downloadArtifacts` → confirm the repo is
      in the cluster's region and the image path has no typo **before** touching IAM. Then grant
      `roles/artifactregistry.reader` on the repository to the node service account if needed.
- [ ] `exec format error`, or `CrashLoopBackOff` with no app logs → wrong architecture. An arm64
      build pushes and pulls without complaint, then fails on amd64 nodes, which is why it does not
      look like an architecture problem.
      `kubectl -n <svc> describe pod -l app=<svc>-service | grep -A3 'Last State'` ·
      `docker buildx imagetools inspect <image> | grep -i platform` — want `linux/amd64`.
      Rebuild via the service repo's `image-push` target, which carries the platform flag.
- [ ] The pod runs old bytes after a redeploy → a moved tag plus `imagePullPolicy: IfNotPresent`.
      Pin the digest, and never move a tag that is already deployed.

---

## Phase 5 — App starts, then exits on config

- [ ] `config: <NAME> is required` → that variable is missing or empty. `config.Load()`
      hard-requires `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `ENCRYPTION_KEY` and a
      non-empty redirect URL — **on all three services**, including the two that register no auth
      routes. Any one aborts startup; there is no degraded mode.
- [ ] `secret: key must decode to 32 bytes, got N` → `ENCRYPTION_KEY` is not a 32-byte base64
      value. An AES-256 length requirement, not a preference: `openssl rand -base64 32`.
- [ ] You used `openssl rand -hex 32` → 64 characters, wrong decoded length. Usual cause of the
      box above.
- [ ] **Changing `ENCRYPTION_KEY` invalidates every live session.** A migration, not a config
      tweak. Store it outside the cluster.
- [ ] A missing Secret and an empty value fail **differently**: missing →
      `CreateContainerConfigError` (Phase 4); empty → `CrashLoopBackOff` naming the variable here.
- [ ] `CrashLoopBackOff` mentioning a read-only filesystem or a log file path → the config names a
      log file while the container runs `readOnlyRootFilesystem: true`. Fix with a writable
      `emptyDir` scratch mount, not by dropping the security setting.
- [ ] **league only** — the app connects somewhere unexpected, or nowhere → check `DATABASE_URL` is
      not set. `config.go` assigns it unconditionally and `ConnectDatabaseString()` *prefers* it
      over every `DB_*` value, so any value bypasses the Cloud SQL proxy DSN.

---

## Phase 6 — Workload Identity and the Cloud SQL proxy

- [ ] Proxy logs `Unable to generate access token; IAM returned 403 Forbidden: Permission
      'iam.serviceAccounts.getAccessToken' denied` → the **KSA→GSA** binding is missing. This is
      the half that is easy to skip, because the two bindings point in opposite directions.
- [ ] Proxy logs `failed to get instance: ... PermissionDenied` → the **GSA** lacks
      `roles/cloudsql.client`. Different binding, different direction.
- [ ] Cloud SQL rejects an account you never configured, named
      `…-compute@developer.gserviceaccount.com` → the pod fell back to the **node's** identity
      because the KSA→GSA binding is absent. The node SA cannot work here even with broad project
      roles: its OAuth *scopes* exclude `sqladmin`, and scopes cap a token regardless of IAM.
- [ ] `metadata: GCE metadata "instance/service-accounts/default/token" not defined` → Workload
      Identity is not active on the node pool. Changing node-pool metadata mode **recreates nodes**.
- [ ] `Cloud SQL Admin API has not been used` → `sqladmin.googleapis.com` is disabled. The proxy
      resolves the instance connection name through that API, not DNS.
- [ ] The KSA annotation is absent or misspelled →
      `kubectl -n <svc> get sa <svc>-service -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'`
- [ ] The `workloadIdentityUser` member string embeds **namespace and KSA name**
      (`PROJECT.svc.id.goog[<svc>/<svc>-service]`). A typo in either is silent — no error, just the
      node identity.
- [ ] The proxy logs `started successfully` and you conclude Workload Identity works → it does not
      prove that. The proxy binds its listener before authenticating and dials Cloud SQL lazily, on
      the first client connection. With the app blocked, that connection never happens, so a
      missing GSA has not surfaced yet.
- [ ] Settle the two most confusable causes above with one command — the identity the pod
      **actually** got:
      ```bash
      kubectl -n <svc> run wi-test --rm -it --restart=Never \
        --image=google/cloud-sdk:slim \
        --overrides='{"spec":{"serviceAccountName":"<svc>-service"}}' \
        -- gcloud auth list
      ```
      It must print the service's own GSA, not `…-compute@developer`.
- [ ] A new IAM binding does not take effect immediately → propagation takes a minute or two. One
      further crash cycle after a restart is not necessarily failure.

---

## Phase 7 — The proxy sidecar itself

- [ ] Proxy restarts on a fixed cycle, exit code **143**, logs otherwise clean → 143 is 128 + 15,
      SIGTERM: the kubelet killed it. The proxy is healthy and its **startup probe** is failing. A
      container reporting `CrashLoopBackOff` while logging success is almost always a probe, not
      the process. The interval gives it away — `failureThreshold × periodSeconds` exactly.
- [ ] The startup probe needs all four to agree: `--health-check` (turns the health server on at
      all), `--http-address=0.0.0.0`, `--http-port=9090`, and
      `httpGet: { path: /startup, port: 9090 }`.
- [ ] A `tcpSocket` probe on 5432 can **never** pass → the kubelet dials the pod IP from outside
      the pod's network namespace, while the DB tunnel binds `127.0.0.1` only, by design. The fix
      is not `--address=0.0.0.0` on the database port — that would expose an IAM-authenticated
      database tunnel on the pod IP.
- [ ] `Startup probe failed: connection refused` once or twice at container start → expected noise.
      The probe fires before the proxy has bound its port.
- [ ] Proxy logs `SIGTERM signal received` straight after `ready for new connections` → same
      startup-probe cause, not a shutdown bug.
- [ ] The app wins the startup race and dies before the proxy is ready → the proxy must be a
      **native sidecar** (`initContainers` + `restartPolicy: Always`), not an ordinary container.
      Requires Kubernetes 1.29+. Because it is an initContainer, a failing proxy means the app
      container never starts — which is why there are no app logs to read.

---

## Phase 8 — Database connection and schema

- [ ] `db: ping ...: context deadline exceeded` → the app reached the sidecar's port but the sidecar
      cannot reach Cloud SQL. The app's error is downstream of the real one; read the proxy's logs:
      `make logs-proxy SVC=<svc>`
- [ ] `connection refused` on `127.0.0.1:5432` → the proxy is not listening at all. Phase 7, and
      check `DB_PORT` matches the proxy's `--port`. Three places must agree and nothing enforces it:
      the proxy's `--port`, the sidecar probe, and `DB_PORT`.
- [ ] `connection reset by peer` → the proxy is listening but cannot reach Cloud SQL. Phase 6.
- [ ] `password authentication failed for user "postgres"` → `DB_PASSWORD` does not match the
      instance. The proxy authenticates the *connection* via IAM; the *database user* still uses a
      password, and both have to be right.
      `gcloud sql users set-password postgres --instance=recommendations-app-instance --prompt-for-password`
      Then update the Secret and restart.
- [ ] `database "…" does not exist` → `DB_NAME` names a database not on the instance.
      `gcloud sql databases list --instance=recommendations-app-instance`
- [ ] Rotating the instance's `postgres` password affects **every service sharing that instance**,
      since it is the same superuser. A per-service database user avoids this.
- [ ] **A green `/api/v1/health` does not mean the database works.** The handler never touches the
      pool on any of the three services. It says nothing about whether the schema exists — only a
      real data route does.

---

## Phase 9 — Reaching the service

- [ ] `curl` hangs or 502s → check the EndpointSlice is non-empty:
      `kubectl -n <svc> get endpointslice -l kubernetes.io/service-name=<svc>-service -o jsonpath='{.items[*].endpoints[*].addresses}{"\n"}'`
- [ ] Empty EndpointSlice → the Service matches no **ready** pod. Either the pod is not Ready (go
      back up this page), or `service.selector` does not equal the pod labels, or
      `service.targetPort` does not match the container port's **name**.
- [ ] Endpoint present and still 502 → the port the process bound does not match `containerPort`.
      `containerPort` is informational; the process binds whatever `PORT` says.
- [ ] Anything involving TLS, Cloudflare status codes, the Ingress address or backend health →
      [edge-architecture.md](./edge-architecture.md#edge-symptoms).

---

## Phase 10 — OAuth and CORS

- [ ] `redirect_uri_mismatch` → the URI the app sends must match the GCP console's **Authorized
      redirect URIs** byte for byte. Google compares the literal string and will not hint which
      character differs. Check `http` vs `https`, a trailing slash, `www.`, and the path prefix.
- [ ] The redirect URL in the running pod is localhost → it comes from the `//go:embed`-ed
      `production.yaml`, **not** the ConfigMap. `auth-be` now ships the correct production value;
      `league-be` still ships localhost and has no env override at all, so changing it needs a code
      change and a rebuild. See [gke-parameters.md §8](./gke-parameters.md).
- [ ] A browser gets a CORS error while `curl` works → expected. `FRONTEND_URL` is both the single
      allowed CORS origin and the post-login redirect target, and neither `curl` nor the kubelet
      probes send an `Origin` header. It must be the SPA's exact origin — scheme, host and port, no
      path, no trailing slash. **Still `localhost:5173` on all three services.**
      `kubectl -n <svc> get cm <svc>-service-config -o jsonpath='{.data.FRONTEND_URL}'`
- [ ] Login redirects fine, then the callback fails with no `oauth_tx` cookie → the `__Host-`
      prefix requires `Path=/` exactly, and `auth-be` sets that cookie with
      `Path=/api/v1/auth/google`. The browser discards it without any signal the server can see.
      **Open blocker in `auth-be`** — see [auth-service/prerequisites.md](./auth-service/prerequisites.md#open-issues).

---

## Phase 11 — Changes that appear to do nothing

- [ ] A `configmap.yaml` edit has no effect → there is no `configMapGenerator`, so the ConfigMap
      has no name hash, so the pod template does not change, so no rollout triggers and the running
      pod keeps its old environment. Env vars never hot-reload; a pod replacement is required
      **every time**: `make apply-config SVC=<svc>`
- [ ] A Secret edit has no effect → same mechanism. Replace the Secret, then
      `make restart SVC=<svc>`.
- [ ] Check what actually reached the container:
      `kubectl -n <svc> exec deploy/<svc>-service -c <svc>-service -- env | sort`
      These images are distroless, so this will fail (no shell, no `env`) — compare the ConfigMap
      against the pod's start time instead.
- [ ] `rollout undo` appears to change nothing → it is only meaningful because images are
      digest-pinned. With a floating tag, undo re-pulls whatever that tag points at today.
- [ ] The pod vanished and came back on its own → the node pool is **spot**, so preemption is normal
      and expected, and with `replicas: 1` it is a short full outage. Not a bug to fix — a tradeoff
      to accept, or to remove with a non-spot pool.
      `kubectl get events -A --field-selector reason=Preempted`
