# league-service — Grafana on the internet

Serves the Grafana from [grafana.md](grafana.md) at **https://monitoring.mvip-league.com** to named
people only.

```
browser ──▶ Cloudflare Access (email login) ──tunnel──▶ cloudflared pod ──▶ grafana.monitoring.svc:80
```

The `cloudflared` pod connects **out** to Cloudflare, so there's no load balancer or open port.
Do the steps in order: the hostname goes live in step 5, after Access and the password are in
place.

---

## 1. Cloudflare Access

1. **Zero Trust → Integrations → Identity providers → Add new identity provider → One-time PIN.**
2. **Zero Trust → Access controls → Policies → Add a policy**: name `grafana-admins`, action
   **Allow**, session 24 hours, **Include → Emails** with each person's email.
3. **Zero Trust → Access controls → Applications → Create new application → Self-hosted and
   private**: public hostname `monitoring` / `mvip-league.com`, policy `grafana-admins`, identity
   provider One-time PIN (turn on **Apply instant authentication**), session 24 hours. **Create**.

To add a person later: add their email to `grafana-admins` and create a Grafana user for them.

---

## 2. Change Grafana's admin password

See [grafana.md §4](grafana.md#4-log-in). It's the second gate behind Access.

---

## 3. Create the tunnel and store its token

**Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**, name `league-cluster-grafana`.
From the install command, copy the value after `--token`. It starts with `eyJ` and is 180+
characters. The 36-character UUID is the Tunnel ID and won't work.

```bash
kubectl -n monitoring create secret generic cloudflared-token --from-literal=token=<eyJ… token> \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 4. Deploy the connector

```bash
kubectl -n monitoring apply -f helm/monitoring/cloudflared.yaml
kubectl -n monitoring rollout status deploy/cloudflared
kubectl -n monitoring logs deploy/cloudflared | grep -i 'registered tunnel connection'
```

The tunnel shows **Healthy** in Cloudflare. After replacing the token, run
`kubectl -n monitoring rollout restart deploy/cloudflared`.

---

## 5. Publish the hostname

In the tunnel: **Published application routes → Add a published application route**. Private
hostname and private network routes create no DNS record.

| Field | Value |
| --- | --- |
| Subdomain / Domain | `monitoring` / `mvip-league.com` |
| Service type | `HTTP` |
| URL | `grafana.monitoring.svc:80` |

Check the connector received it, then the URL:

```bash
kubectl -n monitoring logs deploy/cloudflared | grep 'Updated to new configuration'
curl -sI https://monitoring.mvip-league.com | grep -i -E '^HTTP|^location'
```

The answer is a `302` to `<team-name>.cloudflareaccess.com`, never Grafana's login page.

---

## 6. Removing it

In Cloudflare, delete the published route, then the tunnel, the Access application and the
`grafana-admins` policy. Then:

```bash
kubectl -n monitoring delete -f helm/monitoring/cloudflared.yaml
kubectl -n monitoring delete secret cloudflared-token
```

Grafana stays reachable with `port-forward`.
