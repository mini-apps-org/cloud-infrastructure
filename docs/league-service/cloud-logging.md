# league-service — querying logs in Cloud Logging

How to find league's logs in Cloud Logging: what a log line contains, the three places to query
from, the filter language, and ready-made queries. Every query here was run against
`league-cluster` and returns results.

```
league pod ──stdout JSON──▶ GKE logging agent ──▶ Cloud Logging (_Default bucket, 30 days)
                                                       ▲
                     Logs Explorer · Grafana Explore · gcloud logging read
```

Reading needs `roles/logging.viewer` on `vincent-mini-apps-project` (or Owner/Editor).

---

## 1. What league logs

league-be writes one JSON object per line to stdout (`log/slog`, `internal/platform/logger`).
The GKE agent parses it into `jsonPayload` and maps `level` to the entry's `severity`:

| `jsonPayload.level` | `severity` |
| --- | --- |
| `DEBUG` | `DEBUG` |
| `INFO` | `INFO` |
| `WARN` | `WARNING` |
| `ERROR` | `ERROR` |

A failed request, as stored:

```json
{
  "jsonPayload": {
    "level": "WARN",
    "msg": "request failed",
    "method": "GET",
    "path": "/api/v1/me",
    "status": 401,
    "code": "40101",
    "reason": "SESSION_COOKIE_ABSENT",
    "err": "no session cookie",
    "request_id": "bdd02c26-7da4-41c5-aefa-65bdce8f4126",
    "time": "2026-11-23T13:37:35.3654222Z"
  },
  "resource": {
    "type": "k8s_container",
    "labels": { "namespace_name": "league", "container_name": "league-service", "pod_name": "league-service-6dc9c6dcb5-vjlvp", "...": "..." }
  },
  "severity": "WARNING"
}
```

| Field | When it is there |
| --- | --- |
| `msg` | Always. The message: `request failed`, `server: listening`, `database: connected`, … |
| `request_id` | Any line logged with a request context — join a request's lines with it |
| `method`, `path`, `status`, `code`, `reason`, `err` | `request failed` lines only |
| `component` | Lines from a service or repository logger, e.g. `teams.service`, `auth.repository` |
| `image`, `env`, `addr` | The `server: listening` startup line — which release a pod runs |

Things to know before searching:

- **Only failed requests are logged.** There is no access log: a `200` leaves no line. For
  request counts and latency use the metrics in [grafana.md §8](grafana.md#8-build-the-dashboard).
- **4xx is `WARNING`, 5xx is `ERROR`** (`handler/error.go`). So `severity>=ERROR` means *our* bugs;
  `severity>=WARNING` also includes callers' mistakes such as a missing cookie.
- **The message is `msg`, not `message`.** Cloud Logging only uses `message` for the summary line,
  so in Logs Explorer each entry shows as raw JSON until you add `msg` as a summary field (§2).

---

## 2. Three places to query

All three take the same filter (§3). Start every query from this base, which selects league's
container and nothing else:

```text
resource.type="k8s_container"
resource.labels.namespace_name="league"
resource.labels.container_name="league-service"
```

### Logs Explorer (console)

<https://console.cloud.google.com/logs/query?project=vincent-mini-apps-project>

1. Paste the base filter into the query box, add lines from §4, **Run query**.
2. Set the range with the time picker (top), not in the filter.
3. Expand an entry, click `jsonPayload.msg` → **Add field to summary line**. Do the same for
   `path` and `status`. The summary fields stick for the session.
4. **Save** (next to Run query) keeps a query under *Saved queries* for the project.
5. **Stream logs** follows new entries live — useful while a deploy rolls out.

### Grafana

**Explore → data source Cloud Logging**, project `vincent-mini-apps-project`, paste the filter into
the query box. Grafana's time picker sets the range. Same results as the console; use it to put
logs next to the metrics on the dashboard (Logs panel, [grafana.md §8](grafana.md#8-build-the-dashboard)).

### gcloud

```bash
BASE='resource.type="k8s_container"
resource.labels.namespace_name="league"
resource.labels.container_name="league-service"'

gcloud logging read "$BASE
severity>=WARNING" \
  --project vincent-mini-apps-project --freshness 1h --limit 50 \
  --format='table(timestamp, severity, jsonPayload.msg, jsonPayload.path, jsonPayload.status, jsonPayload.request_id)'
```

| Flag | Does |
| --- | --- |
| `--freshness 1h` | How far back. Default `1d`; anything past 30d finds nothing (retention) |
| `--limit 50` | Newest first; without it `read` keeps paging |
| `--format=json` | Whole entries, for when a table hides the field you need |
| `--order asc` | Oldest first — reading one request's lines in order |

---

## 3. Filter language in five rules

1. **One condition per line, lines are `AND`.** `OR` and `NOT` need writing out, with parentheses:
   `jsonPayload.status=(401 OR 403)`, `NOT jsonPayload.path="/api/v1/health"`.
2. **Comparisons:** `=` `!=` `>` `<` `>=` `<=` on numbers, strings, `severity` and `timestamp`.
3. **`:` means "has"** — substring on a field (`jsonPayload.msg:"listening"`) or, with `*`,
   "field exists" (`jsonPayload.request_id:*`).
4. **`=~` is a regex** (RE2): `jsonPayload.path=~"^/api/v1/teams/"`. `!~` negates.
5. **A bare quoted string searches every field:** `"no session cookie"`. Slowest form — narrow
   with the base filter first.

Time in the filter, when the picker isn't enough:

```text
timestamp>="2026-11-23T13:30:00Z"
timestamp<"2026-11-23T14:00:00Z"
```

---

## 4. Ready-made queries

Add to the base filter.

| Looking for | Add |
| --- | --- |
| Our errors (5xx, startup failures) | `severity>=ERROR` |
| Everything that went wrong, callers' mistakes included | `severity>=WARNING` |
| Failed requests | `jsonPayload.msg="request failed"` |
| Server errors only | `jsonPayload.status>=500` |
| Auth failures | `jsonPayload.status=(401 OR 403)` |
| One endpoint | `jsonPayload.path="/api/v1/me"` |
| A group of endpoints | `jsonPayload.path=~"^/api/v1/teams"` |
| One error code | `jsonPayload.code="40101"` |
| One error reason | `jsonPayload.reason="SESSION_COOKIE_ABSENT"` |
| One component | `jsonPayload.component="teams.service"` |
| Text anywhere | `"no session cookie"` |
| Which release each pod started with | `jsonPayload.msg="server: listening"` → read `jsonPayload.image` |
| Startups and shutdowns | `jsonPayload.msg=("server: listening" OR "server: shutting down")` |
| Database connection problems | `jsonPayload.msg:"database"` + `severity>=WARNING` |
| One pod | `resource.labels.pod_name="league-service-6dc9c6dcb5-vjlvp"` |

---

## 5. Follow one request

A client reports an error. Its `request_id` (from the failed line, or a response the client kept)
pulls up every line logged during that request — handler, service and repository:

```bash
gcloud logging read "$BASE
jsonPayload.request_id=\"bdd02c26-7da4-41c5-aefa-65bdce8f4126\"" \
  --project vincent-mini-apps-project --freshness 7d --order asc \
  --format='table(timestamp, severity, jsonPayload.component, jsonPayload.msg, jsonPayload.err)'
```

In Logs Explorer: expand any entry with a `request_id`, click the value → **Show matching entries**.

---

## 6. After a deploy

Did the new pods come up on the right image, and are they failing?

```text
resource.type="k8s_container"
resource.labels.namespace_name="league"
resource.labels.container_name="league-service"
jsonPayload.msg=("server: listening" OR "database: connected" OR "server: shutting down")
```

Expect, per new pod: `database: connected` → `metrics server: listening` → `server: listening`
with `image` = the tag in `helm/values/league.yaml`, and one `server: shutting down` per old pod.
Then switch the filter to `severity>=ERROR` and **Stream logs** for a few minutes.

A pod that crashes before it logs anything leaves nothing here — check `kubectl -n league
describe pod` and [troubleshooting.md](../troubleshooting.md).
