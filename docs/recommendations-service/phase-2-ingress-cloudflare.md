# Phase 2 — `recommendations.vincentn.dev` on HTTPS through Cloudflare

The same shape as `auth-service`, which is already live. This is a **delta document**: the
reasoning, the diagrams, the propagation timings and the troubleshooting table live in
[auth-service/phase-2-ingress-cloudflare.md](../auth-service/phase-2-ingress-cloudflare.md) and
are not repeated. Read that first if you have not; what follows is only what differs.

| | |
| --- | --- |
| **Goal** | `https://recommendations.vincentn.dev/api/v1/health` → `200` |
| **Time** | ~20 min, of which ~10 is waiting on the load balancer |
| **Image** | the deployed `0.1.2` — **no rebuild, no code change** |
| **Destructive** | yes, narrowly: step 3 releases `35.247.189.174` permanently |
| **Finishes the job** | yes, unlike auth — see [No OAuth blocker here](#no-oauth-blocker-here) |

---

## What differs from auth-service

| | `auth-service` | `recommendations-service` |
| --- | --- | --- |
| Namespace | `auth` | `recommendations` |
| Host | `auth.vincentn.dev` | `recommendations.vincentn.dev` |
| Static IP | `auth-service-ip` → `34.8.170.48` | `recommendations-service-ip` → `8.232.192.135` |
| Old LB IP released | `34.87.12.86` | `35.247.189.174` |
| Container port | `9999` | `9998` |
| TLS secret | `auth-service-origin-tls` | `recommendations-service-origin-tls` (a **copy**) |
| Certificate | — | the *same* `*.vincentn.dev` cert, no new issuance |
| Remaining code blockers | two (step 9 there) | **none** |

### Why a second load balancer, and not a shared one

`k8s/recommendations-service/service.yaml` used to say the Phase 2 shape was *"NodePort behind
one shared GKE Ingress."* That is not achievable: **an Ingress can only reference Services in its
own namespace**, and these two services live in `auth` and `recommendations`. One Ingress cannot
front both, so this is a second, independent Ingress with its own global address — a global
address backs exactly one forwarding rule, so `auth-service-ip` cannot be reused either.

Genuinely sharing one load balancer across namespaces requires the **Gateway API** (one
`Gateway`, plus an `HTTPRoute` per namespace). That is the right end state if a third service
appears, but the API is not enabled on this cluster (`kubectl get gatewayclass` →
`the server doesn't have a resource type`), and enabling it would mean migrating `auth-service`
off its working Ingress too. The cost of the second Ingress is roughly one extra forwarding rule
per month; revisit at service number three.

### No OAuth blocker here

`recommendations-be` has no active Google login flow — `google_oauth_redirect_url` exists in its
embedded `production.yaml` and is checked for non-emptiness by `config.Load()`, but nothing reads
it at runtime. So the `0.1.2` image needs **no change and no rebuild**, and this phase actually
completes. `FRONTEND_URL` is the only host value that matters, and it does one job here, not two:
the single allowed CORS origin (`internal/platform/middleware/cors.go`, `AllowCredentials: true`).

---

## Step 1 — Preflight

```bash
kubectl -n recommendations get pods              # 2/2 Running
kubectl -n recommendations get secret recommendations-service-origin-tls   # exists
gcloud compute addresses describe recommendations-service-ip --global \
  --format='value(address,status)'               # 8.232.192.135  RESERVED
```

All three are **already done**. The address is reserved and the certificate Secret has been
copied from the `auth` namespace. If you ever need to recreate that copy:

```bash
kubectl -n auth get secret auth-service-origin-tls -o json \
  | jq '.metadata = {name: "recommendations-service-origin-tls", namespace: "recommendations"}' \
  | kubectl apply -f -
```

Verify it covers the host — `-checkhost` answers this directly rather than making you read SANs:

```bash
kubectl -n recommendations get secret recommendations-service-origin-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -checkhost recommendations.vincentn.dev
# => Hostname recommendations.vincentn.dev does match certificate
```

> A wildcard `*.vincentn.dev` covers exactly one label: `recommendations.vincentn.dev` matches,
> `a.b.vincentn.dev` does not, and the bare apex `vincentn.dev` does not either. Fine for every
> host this project uses.

---

## Step 2 — Create the Cloudflare DNS record

Cloudflare → **DNS → Records → Add record**:

| Field | Value |
| --- | --- |
| Type | `A` |
| Name | `recommendations` |
| IPv4 address | `8.232.192.135` |
| Proxy status | **Proxied** (orange cloud) |
| TTL | Auto |

```bash
dig +short recommendations.vincentn.dev    # Cloudflare edge IPs, NOT 8.232.192.135
```

Cloudflare edge IPs are the correct answer — the A record value is the private origin pointer.
Zone-level settings (**Full (strict)**, **Always Use HTTPS**) are already set from the
`auth-service` rollout and apply to every record in the zone, so there is nothing to change
there.

---

## Step 3 — Apply

```bash
kubectl apply -k k8s/recommendations-service --dry-run=server   # expect the ingress.class warning
make apply-config SVC=recommendations
```

Ignore `Warning: annotation "kubernetes.io/ingress.class" is deprecated` — acting on it breaks
the Ingress. Full explanation in the auth runbook's step 5.

**`35.247.189.174` is released here, permanently.** Dropping the Service to `ClusterIP` deletes
the regional load balancer, and the address was ephemeral, so it returns to the pool. Nothing
points at it once step 2 is done.

If `apply` rejects the type change over `nodePort`:

```bash
kubectl -n recommendations delete svc recommendations-service && make apply SVC=recommendations
```

---

## Step 4 — Wait, then verify

**Budget ~10 minutes and do not re-apply** — re-applying restarts propagation. The frontend comes
up in the same three stages measured on `auth-service` (`Connection reset` → `404` → `200`); the
staging table in the auth runbook's step 6 explains why `HEALTHY` backends are not the green
light.

```bash
kubectl -n recommendations get ingress recommendations-service -w     # ADDRESS => 8.232.192.135
kubectl -n recommendations describe ingress recommendations-service | grep backends
```

Then, origin first and Cloudflare second:

```bash
IP=8.232.192.135

# hop 2 -- origin, bypassing Cloudflare. --insecure is correct: the origin cert
# is Cloudflare Origin CA, which your trust store does not contain by design.
curl -sS --resolve "recommendations.vincentn.dev:443:$IP" --insecure \
  https://recommendations.vincentn.dev/api/v1/health

# hop 1 -- through Cloudflare, as a browser sees it
curl -sS https://recommendations.vincentn.dev/api/v1/health
curl -sI https://recommendations.vincentn.dev/api/v1/health | grep -iE 'cf-ray|server:'

# plaintext must not serve. 301 expected (Always Use HTTPS is on zone-wide).
curl -sI http://recommendations.vincentn.dev/api/v1/health | head -1
```

Finally, confirm you now have exactly two load balancers and no stray regional one:

```bash
gcloud compute forwarding-rules list --global --format='table(name,IPAddress,portRange)'
kubectl get svc -A --field-selector spec.type=LoadBalancer    # expect: no resources
```

---

## Exit checklist

- [ ] `dig +short recommendations.vincentn.dev` → Cloudflare IPs, not `8.232.192.135`
- [ ] Ingress `ADDRESS` is `8.232.192.135`; backend `HEALTHY`
- [ ] `https://recommendations.vincentn.dev/api/v1/health` → `200`
- [ ] `http://` → `301`, never `200`
- [ ] No `LoadBalancer` Service remains anywhere in the cluster
- [ ] `FRONTEND_URL` set to the real SPA origin (still a `TODO` in `configmap.yaml`)

## Rollback

```bash
kubectl -n recommendations delete ingress recommendations-service
# restore type: LoadBalancer in service.yaml, then
make apply SVC=recommendations
```

That yields a **new** ephemeral IP, so the DNS record needs repointing. Keep
`recommendations-service-ip` reserved either way — an address already published in DNS cannot be
re-reserved once released.
