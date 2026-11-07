# Creating a basic GKE cluster with `gcloud`

A self-contained, copy-pasteable recipe for a **small single-node GKE Standard cluster** — the
kind you want for a side project, a staging environment, or a first production service that does
not yet need scale. Flag by flag, with the reasoning, so you can keep what fits and drop what
does not.

| | |
| --- | --- |
| **Scope** | GKE **Standard**, zonal, one Spot node. Not Autopilot, not regional, not private. |
| **Assumes** | `gcloud` ≥ 500 (written against 575.0.0), a project with billing enabled, and that you want to reach the cluster from a laptop. |
| **Produces** | A cluster that runs containers, serves HTTP(S) through an Ingress, and lets Pods authenticate to Google APIs without a key file — the three things almost every deployment needs. |
| **Does not produce** | A container registry, a database, a static IP, DNS, or TLS certificates. Those are separate resources, created once per project rather than per cluster. |

---

## 1. Before the first command

### Set your variables

Everything below uses these. Set them once per shell and the commands are copy-pasteable as-is.

```bash
PROJECT=my-project-id          # gcloud projects list
REGION=asia-southeast1         # pick one close to your users
ZONE=${REGION}-a
CLUSTER=my-cluster
```

### Enable the API and confirm your identity

A fresh project has the Kubernetes Engine API off, and cluster creation fails on that before it
fails on anything interesting.

```bash
gcloud config set project ${PROJECT}
gcloud services enable container.googleapis.com
gcloud auth list                  # the active account is the one that will own the cluster
```

If you keep several accounts in `gcloud`, activate the right configuration **first**:
`gcloud config configurations activate <name>`. Creating a cluster under the wrong identity is
tedious to unpick, because the kubectl context it writes is named after the cluster, not the
account.

### The roles you need

| Role | Why |
| --- | --- |
| `roles/container.admin` | create and manage clusters |
| `roles/iam.serviceAccountUser` | attach a service account to the nodes — needed even if you accept the default one |
| `roles/compute.networkAdmin` | only if you create or modify VPCs/subnets rather than using `default` |

Project Owner covers all three. On a shared project, ask for these rather than Owner.

---

## 2. The command

### Minimal — the shortest command that gives a working cluster

```bash
gcloud container clusters create ${CLUSTER} \
  --project ${PROJECT} \
  --zone ${ZONE} \
  --release-channel regular \
  --num-nodes 1 \
  --machine-type e2-medium \
  --workload-pool ${PROJECT}.svc.id.goog
```

Everything else is a default — and five of those defaults cost you money or options later, which
is what the next form fixes.

### Recommended — the same cluster, with the defaults you do not want left alone

```bash
gcloud container clusters create ${CLUSTER} \
  --project ${PROJECT} \
  --zone ${ZONE} \
  --release-channel regular \
  --num-nodes 1 \
  --machine-type e2-medium \
  --spot \
  --disk-type pd-standard \
  --disk-size 30 \
  --workload-pool ${PROJECT}.svc.id.goog \
  --enable-ip-alias \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing,NodeLocalDNS,GcePersistentDiskCsiDriver \
  --enable-master-authorized-networks \
  --master-authorized-networks "$(curl -s4 ifconfig.me)/32" \
  --monitoring=SYSTEM \
  --logging=SYSTEM,WORKLOAD \
  --enable-autoupgrade \
  --enable-autorepair \
  --max-surge-upgrade 1 \
  --max-unavailable-upgrade 0
```

| Flag it adds | Default you would have got instead |
| --- | --- |
| `--spot` | on-demand nodes, roughly 3× the price — a real tradeoff, see §3 |
| `--disk-type pd-standard --disk-size 30` | 100 GB `pd-balanced`, several times the disk bill |
| `NodeLocalDNS` in `--addons` | no DNS cache, and adding it later recreates every node |
| `--enable-master-authorized-networks` + a CIDR | a public control-plane endpoint reachable from **any** IP |
| `--monitoring=SYSTEM` | the maximal metric set, billed per sample — see §4 |

Creation takes 5–8 minutes, and leaves the new cluster as your current `kubectl` context (§6).

§4 documents every flag above **plus** the ones left at a default here, so reach for it when you
want to change something rather than copying a longer command from somewhere else.

---

## 3. What the node size decides

This is the one choice that constrains everything you deploy afterwards, so decide it on purpose.

A node does not give your workloads all of its CPU. GKE reserves a slice for the kubelet and the
OS, then system DaemonSets (logging agent, metrics agent, DNS cache, CSI driver, kube-proxy) take
a further cut before your first Pod schedules:

| | `e2-small` | `e2-medium` | `e2-standard-2` |
| --- | --- | --- | --- |
| vCPU / RAM | 2 shared / 2 GB | 2 shared / 4 GB | 2 dedicated / 8 GB |
| Schedulable capacity | 500m | 1000m | 2000m |
| GKE reservation | −30m | −60m | −70m |
| **Allocatable** | ~470m | **940m** | ~1930m |
| GKE system Pods | ~−701m | ~−701m | ~−701m |
| **Left for your workloads** | **none** | **~239m** | **~1229m** |
| Spot, 1 node, approximate | ~$4/mo | ~$8/mo | ~$16/mo |

The reservation follows a sliding scale — 6% of the first core, 1% of the second, less thereafter.
Shared-core types present their *baseline* vCPU to the scheduler, not their burst ceiling, which
is why `e2-medium` offers 1000m despite reporting 2 vCPU.

Three things fall out of this, all of them things people hit in their first week:

- **~239m on `e2-medium` runs two or three small services, and cannot run a second copy of one
  during a rolling update.** On a node that full, a Deployment with `maxSurge: 1` /
  `maxUnavailable: 0` **deadlocks**: the old Pod cannot terminate until the new one is Ready, and
  the new one cannot schedule until the old one releases its CPU. Use `maxUnavailable: 1` /
  `maxSurge: 0` and accept a brief gap, or get a bigger node.
- **`e2-small` is a trap for a general-purpose cluster** — and not mainly because of the ~470m.
  Its 2 GB of RAM has to cover the same system DaemonSets. It suits one tiny workload, nothing more.
- **One larger node usually beats two small ones** at similar cost, because the ~701m of system
  Pods is charged once instead of twice. The counter-argument is availability, not capacity: a
  single node cannot survive an upgrade, a repair, or a preemption without downtime.

### On `--spot`

Spot nodes are 60–70% cheaper and have **no availability guarantee**: Google can reclaim one with
30 seconds' notice. On a single-node cluster running `replicas: 1`, a preemption is a **full
outage** of a few minutes while the node is replaced and Pods restart.

That is a fine trade for staging, side projects, batch work, and anything with a human who can
wait. It is not a fine trade for something people depend on — there, drop `--spot` and run at
least two nodes and two replicas with a `PodDisruptionBudget` and a `topologySpreadConstraint`,
or the second node buys you nothing.

---

## 4. Flag by flag

Every flag in §2, plus the ones worth knowing about before you need them.

### Identity and version

| Flag | Effect | Notes |
| --- | --- | --- |
| `--project` / `--zone` | where the cluster lives | **Zonal**, not regional: one control plane, no HA. A regional cluster replicates the control plane across three zones and, because `--num-nodes` is *per zone*, triples your node count and bill by default |
| `--release-channel regular` | control plane and nodes auto-upgrade on Google's schedule | Recommended, and it keeps you new enough for current Kubernetes features — **native sidecars** (`initContainers` with `restartPolicy: Always`) need **1.29+**, and an old pinned cluster rejects such a manifest outright. `rapid` for newest, `stable` for most conservative |
| `--cluster-version` | pins the initial version | Leave it out when you use a channel. The channel will upgrade past your pin on its own schedule, so the pinned number is wrong within weeks and misleads whoever reads the command next |
| `--workload-pool` | enables **Workload Identity** (`PROJECT.svc.id.goog`) | **Set this at create time.** It is how a Pod authenticates to Google APIs without a JSON key file. Three things must all be true or it fails silently: the pool enabled here, an `iam.gke.io/gcp-service-account` annotation on the Kubernetes service account, and a `roles/iam.workloadIdentityUser` binding on the Google service account. Miss one and the Pod gets a token for the *node's* identity instead, which surfaces as a baffling permission error |
| `--no-enable-basic-auth` | no static username/password on the API server | Default and not negotiable; basic auth was removed from GKE |
| `--service-account` | the IAM service account the **nodes** run as | Omitted means the **Compute Engine default service account**, which is broadly privileged. Beyond a sandbox, create a minimal one (`roles/logging.logWriter`, `roles/monitoring.metricWriter`, `roles/artifactregistry.reader`) and pass it here |

### The node

Everything in this table except `--num-nodes` is **fixed for the node pool's lifetime** — changing
it means a new pool (§7).

| Flag | Effect | Notes |
| --- | --- | --- |
| `--num-nodes 1` | one node in the initial pool | The pool is always named `default-pool`; `gcloud` has no flag to name it. Worth knowing for `-l cloud.google.com/gke-nodepool=` selectors |
| `--machine-type e2-medium` | 2 shared vCPU / 4 GB → **940m allocatable** | The most consequential single flag; see §3 |
| `--spot` | Spot pricing, no availability guarantee | See §3 |
| `--disk-type pd-standard --disk-size 30` | 30 GB HDD boot disk | Well below the 100 GB `pd-balanced` default. Fine for small container images; slow if you pull large layers often |
| `--image-type COS_CONTAINERD` | Container-Optimized OS | Default and the right choice. Read-only root filesystem, no package manager — do not plan on SSHing in to install things |
| `--node-locations` | which zones hold nodes | Keep it equal to `--zone` on a zonal cluster. Listing more zones multiplies `--num-nodes` by the number of zones |
| `--default-max-pods-per-node 110` | Pod slots per node | Default. It sizes the Pod IP range, so lowering it shrinks the CIDR, not the cost |

### Networking

| Flag | Effect | Notes |
| --- | --- | --- |
| `--enable-ip-alias` | **VPC-native** cluster (alias IPs) | Default for new clusters, and worth stating explicitly because things depend on it silently: container-native load balancing (the `cloud.google.com/neg` annotation) requires it, and a legacy routes-based cluster cannot be converted, only replaced |
| `--network` / `--subnetwork` | which VPC and subnet | The `default` VPC is fine to start. Several clusters can share a VPC, which is exactly why Pod ranges must not collide — see the next row |
| `--cluster-ipv4-cidr /17` | **a mask, not a block**: GKE picks the range | Passing a mask instead of a literal CIDR is what makes a second cluster in the same VPC safe — GKE allocates a fresh non-overlapping range rather than colliding with an existing one. `/17` gives ~32k Pod IPs; `/21` is plenty for a small cluster. Service IPs come from a separate GKE-managed range, not from this flag |
| `--no-enable-intra-node-visibility` | same-node Pod-to-Pod traffic stays off the VPC | Default. Enabling it only adds VPC flow-log visibility of that traffic |

### Reaching the control plane

| Flag | Effect | Notes |
| --- | --- | --- |
| `--enable-ip-access` | keeps the **public** control-plane endpoint | Default. Without it the API server is private-only, and `kubectl` from a laptop needs a bastion host, VPN, or Cloud Shell |
| `--enable-master-authorized-networks` + `--master-authorized-networks` | allowlists source IPs for that endpoint | Strongly preferable to an open endpoint, with one catch: **enabling it with an empty list locks everyone out**, and a consumer-ISP address rotates. Either way `kubectl` *hangs and times out* rather than returning an auth error, so it does not look like an access problem and you will debug the wrong thing |
| `--enable-dns-access` | a second, **DNS-based** control-plane endpoint, authorized by **IAM identity** instead of source IP | The durable answer to the rotating-IP problem: the source-IP allowlist does not apply to it at all. GKE provisions the DNS name for every cluster; this flag turns external access to it on |
| `--no-enable-google-cloud-access` | Google Cloud's own IP ranges are *not* implicitly allowed | Tightens the allowlist further. Leave it this way only while nothing inside Google Cloud needs to call your API server — some CI runners and Cloud Build configurations do |

```bash
# kubectl hanging rather than failing auth usually means your IP moved.
# NOTE: this REPLACES the whole list, it does not append -- pass every CIDR you want to keep.
gcloud container clusters update ${CLUSTER} --zone ${ZONE} \
  --enable-master-authorized-networks \
  --master-authorized-networks "$(curl -s4 ifconfig.me)/32"
```

```bash
# Better: stop authorizing by IP. IAM-gated, so it survives ISP rotation, tethering and VPNs.
gcloud container clusters update ${CLUSTER} --zone ${ZONE} --enable-dns-access
gcloud container clusters get-credentials ${CLUSTER} --zone ${ZONE} --dns-endpoint
```

`curl -s4` is deliberate. `ifconfig.me` answers over whichever address family curl connects on, so
on any host with working IPv6 a bare `curl ifconfig.me` returns an IPv6 address — and
`"<v6-addr>/32"` is both the wrong family for an IPv4-stack cluster and a meaningless prefix
length. You get an allowlist without the address you actually arrive from, which is the lockout
above by another route. `-4` forces the family; `-s` keeps curl's progress meter out of your
terminal.

### Observability — where the surprise bill comes from

| Flag | Effect | Notes |
| --- | --- | --- |
| `--logging=SYSTEM,WORKLOAD` | system logs plus your containers' stdout/stderr to Cloud Logging | Keep `WORKLOAD`. It is what gives you logs from a Pod that has already crashed and been replaced, which is exactly when you need them |
| `--monitoring=SYSTEM` | control-plane and node metrics | The honest setting for a small cluster, and the recommendation here |
| `--monitoring=SYSTEM,…,CADVISOR,KUBELET,DCGM` | the maximal set GKE offers | Every component is billed per sample ingested. `CADVISOR` and `KUBELET` are high-volume per-container series; `DCGM` is **GPU** metrics on a cluster that may never have a GPU. On a small cluster this can cost more than the node |
| `--enable-managed-prometheus` | Google-managed Prometheus collection | Also billed per sample. Leave it off until something actually scrapes metrics |

```bash
# Trimming after the fact, no disruption:
gcloud container clusters update ${CLUSTER} --zone ${ZONE} \
  --monitoring=SYSTEM --logging=SYSTEM,WORKLOAD
```

### Security posture

| Flag | Effect | Notes |
| --- | --- | --- |
| `--security-posture=standard` | basic workload misconfiguration scanning | Reports findings into Security Command Center. No admission enforcement, so it cannot block a deployment — informational only |
| `--workload-vulnerability-scanning=disabled` | no image CVE scanning | Switch to `=standard` if you deploy images you did not build today |
| `--binauthz-evaluation-mode=DISABLED` | no deploy-time image attestation | Reasonable while you pin image digests by hand. A real supply-chain control once you have a signing pipeline |
| `--shielded-integrity-monitoring` | boot-integrity measurement on nodes | Keep on; no downside |
| `--no-shielded-secure-boot` | secure boot **off** | Turning it on requires node recreation and breaks unsigned kernel modules. If nothing you run loads any, it is a cheap hardening win |

### Addons and lifecycle

| Flag | Effect | Notes |
| --- | --- | --- |
| `HttpLoadBalancing` | the GCE Ingress controller | Needed for `Ingress` resources. Without it an Ingress is picked up by no controller and never gets an IP, with no error to tell you why |
| `HorizontalPodAutoscaling` | the HPA controller | Default. Harmless when unused, and needed the moment you want autoscaling |
| `NodeLocalDNS` | per-node DNS cache DaemonSet | Cuts DNS latency and kube-dns load. **Enabling it later recreates every node**, so set it now |
| `GcePersistentDiskCsiDriver` | Persistent Disk CSI driver | Needed by any `PersistentVolumeClaim`. Cheap to include before you need it |
| `--enable-autoupgrade` / `--enable-autorepair` | node-pool self-management | Required by a release channel. Note that on a **single-node** pool, an autorepair or upgrade *is* an outage |
| `--max-surge-upgrade 1` / `--max-unavailable-upgrade 0` | node-pool upgrade strategy | Adds a temporary extra **node** during an upgrade instead of draining your only one. **Not** the same as a Deployment's `maxSurge`/`maxUnavailable` — different layer, unrelated setting, confusingly identical names |

**`--addons` replaces the default set, it does not add to it** — gcloud's own words: "addons
specified by this flag will be enabled, the others will be disabled". So `--addons NodeLocalDNS`
on its own silently *disables* `HttpLoadBalancing`, and every Ingress you create afterwards sits
there without a controller. Pass the full list or none of it.

---

## 5. Verify what you actually got

Defaults drift between gcloud releases, so check the two settings that fail silently rather than
assuming they took.

```bash
gcloud container clusters list    # STATUS: RUNNING

# Workload Identity -- EMPTY OUTPUT MEANS IT IS OFF, which is the silent failure
gcloud container clusters describe ${CLUSTER} --zone ${ZONE} \
  --format='value(workloadIdentityConfig.workloadPool)'
# want: ${PROJECT}.svc.id.goog

# Control-plane access -- "enabled: true" with no cidrBlocks is the lockout
gcloud container clusters describe ${CLUSTER} --zone ${ZONE} \
  --format='yaml(masterAuthorizedNetworksConfig)'

# VPC-native, and which Pod range GKE chose (check it against other clusters in the VPC)
gcloud container clusters describe ${CLUSTER} --zone ${ZONE} \
  --format='value(ipAllocationPolicy.useIpAliases,clusterIpv4Cidr)'

# Kubernetes version actually running
gcloud container clusters describe ${CLUSTER} --zone ${ZONE} \
  --format='value(currentMasterVersion)'
```

---

## 6. Point `kubectl` at it — deliberately

`clusters create` leaves the new cluster as your **current context**. That is convenient exactly
once; afterwards it is a hazard, because `kubectl` follows whatever context is current and tells
you nothing about it. "The resource does not exist" and "I am talking to the wrong cluster" look
identical.

```bash
gcloud container clusters get-credentials ${CLUSTER} --zone ${ZONE}
kubectl config current-context    # read this before you trust any output below
kubectl get nodes                 # one Ready node

# Your real remaining capacity, now that a node exists
kubectl describe node -l cloud.google.com/gke-nodepool=default-pool \
  | sed -n '/Allocated resources/,/Events/p'
```

If you work with more than one cluster, make the context explicit rather than remembered — check
`kubectl config current-context` in any deploy script and refuse to run on a mismatch. It is a
three-line guard against a failure mode with no error message and a long debugging tail.

---

## 7. Changing it afterwards, and what cannot change

The asymmetry to internalize: **control-plane settings are mutable, node properties are not.**
Anything baked into a node pool means creating a new pool and deleting the old one.

| Change | How | Disruption |
| --- | --- | --- |
| Authorized networks | `clusters update --master-authorized-networks …` | none |
| DNS control-plane endpoint | `clusters update --enable-dns-access` | none |
| Monitoring / logging components | `clusters update --monitoring=… --logging=…` | none |
| Release channel | `clusters update --release-channel …` | none directly; changes *when* GKE upgrades you |
| Node count | `clusters resize ${CLUSTER} --num-nodes N --zone ${ZONE}` | none scaling up; scaling down drains nodes |
| Addons, e.g. `NodeLocalDNS` | `clusters update --update-addons=NodeLocalDNS=ENABLED` | **recreates every node** |
| Workload Identity pool | `clusters update --workload-pool=…` | restarts workloads |
| Machine type, boot disk, `--spot`, node service account | **new node pool**, then `node-pools delete default-pool` | Pods reschedule; at `replicas: 1`, a gap |
| VPC-native, zonal → regional, Pod CIDR | not changeable | recreate the cluster |

So the migration path for "I picked the wrong machine type" is `node-pools create` with the new
type, let Pods reschedule onto it, then `node-pools delete` the old one. On a multi-node cluster
with healthy PodDisruptionBudgets that is a zero-downtime operation — one more argument against
running a single node in production.

---

## 8. Cost, and deleting it

Three things cost money, and the one people forget is the first:

| | Approximate, verify against current pricing |
| --- | --- |
| **Cluster management fee** | **$0.10/hour (~$74/month) per cluster**, independent of size. GKE Standard includes a credit covering **one zonal cluster per billing account** — which is why your second cluster costs dramatically more than your first |
| Nodes | the Compute Engine bill; see the table in §3 |
| Everything attached | boot disks, load balancer forwarding rules, static IPs, egress, and log/metric ingestion |

The management fee is why "one bigger cluster with namespaces" usually beats "a cluster per
service", and why you should delete experiments rather than leave them idle — an empty cluster is
not a free cluster.

```bash
gcloud container clusters delete ${CLUSTER} --zone ${ZONE}
```

That removes the cluster, its node pool, and everything namespaced inside it, Secrets and
ConfigMaps included. It does **not** remove project-scoped resources you created alongside it —
Artifact Registry repositories, service accounts and their IAM bindings, reserved static IPs,
databases. Those outlive the cluster and keep billing, so clean them up separately.

---

## References

- [`gcloud container clusters create`](https://cloud.google.com/sdk/gcloud/reference/container/clusters/create)
- [GKE cluster architecture and comparison with Autopilot](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/choose-cluster-mode)
- [Workload Identity Federation for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/workload-identity)
- [Hardening: use a minimally privileged node service account](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster)
- [Control-plane network isolation and authorized networks](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation)
- [DNS-based control plane endpoint](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation#dns-based_endpoint)
- [Release channels](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/release-channels)
- [VPC-native clusters and IP address ranges](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/alias-ips)
- [Spot VMs in GKE](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/spot-vms)
- [Node machine types and allocatable resources](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/plan-node-sizes)
- [NodeLocal DNSCache](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nodelocal-dns-cache)
- [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing)
