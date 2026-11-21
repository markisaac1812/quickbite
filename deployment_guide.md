# QuickBite â€” Full Deployment Guide (students)

Deploy QuickBite (core-service, order-service, analytics-service) to AWS from a
brand-new account, then load-test it. Follow **top to bottom** â€” every phase only
uses things made in an earlier phase.

> **About the code:** this guide deploys *infrastructure*. The **application code,
> Dockerfiles, task-definition JSONs, CI workflows, seed SQL, and the k6 load test**
> all live in the **zipped resources** that ship with this guide. Open those â€” I left
> **inline comments** in the Dockerfiles, `deploy.yml`, knex/cache config, and the seed
> scripts to explain what each piece does. When this guide says "use the file from the
> zip," it means literally copy that file; don't retype it.

> This supersedes the earlier high-level guide. The earlier one was correct in shape
> but skipped several things that *will* stop your deploy cold (interface-endpoint
> security groups, secret-ARN syntax, Redis cluster mode, SSL, migrations in the prod
> image, the WebSocket path, â€¦). Those are all spelled out here.

> **Region:** pick **one** region and stay in it (top-right of the console). This guide
> uses `eu-north-1`. Replace it everywhere if you choose another.

---

## Phase 0 â€” Accounts & tools

1. An **AWS account** (root email + a payment method).
2. Local tools: **AWS CLI v2**, **Docker**, **git**, and **k6** (for load testing).
3. A **GitHub account** with the three repos (`core-service`, `order-service`,
   `analytics-service`) pushed.
4. **Clock check:** make sure your machine's clock is **synced** (auto time on).
   A skewed clock makes every AWS CLI call fail with `InvalidSignatureException:
   Signature expired`. If you see that, sync your clock and retry.

---

## Phase 1 â€” IAM deploy user (do this once, get it right)

You'll run CLI commands and push images as an IAM user. Create one and give it the
permissions **up front** so you're not stopping to add them later.

1. IAM â†’ **Users â†’ Create user** â†’ name `quickbite-deploy`.
2. **Create access key** (CLI use) â†’ run `aws configure --profile quickbite` and paste
   the key, secret, region `eu-north-1`, output `json`.
3. Attach these managed policies (Add permissions â†’ Attach policies):
   - `AmazonEC2ContainerRegistryPowerUser` (push/pull images)
   - `AmazonECS_FullAccess` (clusters, services, task defs, Service Connect, autoscaling)
   - `ElasticLoadBalancingFullAccess` (ALB target groups + listener rules)
   - `AmazonVPCFullAccess` (subnets, security-group rules, NAT, endpoints)
   - `SecretsManagerReadWrite` (create + read secrets)
   - `CloudWatchLogsFullAccess` (read logs while debugging)
4. Verify: `aws sts get-caller-identity --profile quickbite` returns your account.

> **Gotcha we hit repeatedly:** if a command returns `AccessDenied â€¦ not authorized to
> perform <action>`, it's this user missing a permission â€” add it and retry. Front-loading
> the policies above avoids the whole loop.

---

## Phase 2 â€” Network (VPC)

1. **VPC â†’ Create VPC â†’ "VPC and more"**.
2. Name `quickbite`, **2 AZs**, **2 public subnets**, **2 private subnets**,
   **NAT gateway = In 1 AZ**, **VPC endpoints = S3 Gateway**.
3. Create and wait until done. Note the **VPC id** and which subnets are **public** vs
   **private** (look at the route tables â€” public = route to `igw-â€¦`, private = route to
   `nat-â€¦`). **Tasks run in the PRIVATE subnets; the ALB and bastion go in PUBLIC.**

### 2.1 Interface endpoints (this is the #1 thing the old guide under-explained)

Private-subnet tasks have **no public internet** unless they go through the NAT, and even
then it's cleaner to reach AWS services privately. Create **4 Interface endpoints**
(VPC â†’ Endpoints â†’ Create endpoint), each: your VPC, the **2 private subnets**,
**Enable DNS name = ON**:
- `com.amazonaws.eu-north-1.ecr.api`
- `com.amazonaws.eu-north-1.ecr.dkr`
- `com.amazonaws.eu-north-1.secretsmanager`
- `com.amazonaws.eu-north-1.logs`

> âš ï¸ **The trap:** with **Private DNS ON**, every task resolves `secretsmanagerâ€¦`,
> `ecrâ€¦`, `logsâ€¦` to these endpoints' **private IPs**. So the endpoints' **security group
> MUST allow inbound 443 from `ecs-sg`** (Phase 3). If it doesn't, tasks fail to start with
> `ResourceInitializationError: unable to pull secrets â€¦ connection issue` â€” and it looks
> like a secrets/IAM problem when it's actually a security-group problem. Come back and set
> the endpoints' SG to `ecs-sg` after Phase 3.

âœ… Done when: VPC has 2 public + 2 private subnets, 1 NAT, S3 gateway endpoint, and 4
interface endpoints.

---

## Phase 3 â€” Security groups

VPC â†’ **Security groups â†’ Create** (6Ã—, same VPC). Leave outbound default (all). Inbound:

1. `alb-sg` â†’ HTTP **80** + HTTPS **443** from `0.0.0.0/0`.
2. `ecs-sg` â†’ for **each service's container port (we use 3000 for all)** from `alb-sg`.
   Then **edit it again** and add: (a) **3000 from `ecs-sg` itself** (Service Connect),
   and (b) **TCP 443 from `ecs-sg` itself** (so tasks reach the interface endpoints).
3. `rds-sg` â†’ TCP **5432** from `ecs-sg`.
4. `docdb-sg` â†’ TCP **27017** from `ecs-sg`.
5. `redis-sg` â†’ TCP **6379** from `ecs-sg`.
6. `mq-sg` â†’ TCP **5671** from `ecs-sg`.

ðŸ”§ **Now go back to the 4 interface endpoints (Phase 2.1) and set their SG to `ecs-sg`**
(or add inbound 443 from `ecs-sg` to whatever SG they use). Skipping this is the
`CannotPullSecretsException` we kept hitting.

> Rule of thumb: every data store SG allows **only** `ecs-sg`. That's what keeps DBs private.

---

## Phase 4 â€” ECR (image repos)

ECR â†’ **Create repository** Ã—3: `core-service`, `order-service`, `analytics-service`.
Turn on **Scan on push**. Copy one repo URI (`<acct>.dkr.ecr.eu-north-1.amazonaws.com`).

---

## Phase 5 â€” Secrets (Secrets Manager)

Create one secret per item, type **Other**, **Key/value** JSON. The **key names inside
each secret must exactly match the env-var names** the app reads (see the task-def JSONs
in the zip).

- `core/db` â†’ `DB_HOST DB_PORT DB_USERNAME DB_PASSWORD DB_NAME`
- `order/db` â†’ all the shard hosts/ports/users/passwords/names (`DB_eg_*`, `DB_ksa_*`,
  `ARCHIVE_DB_eg_*`, `ARCHIVE_DB_ksa_*`)
- `core/auth` â†’ `ACCESS_SECRET`, `REFRESH_SECRET`
- `core/internal` â†’ `INTERNAL_API_KEY`
- `mq` â†’ `RABBITMQ_URL`
- `order/kashier` â†’ `KASHIER_MERCHANT_ID`, `KASHIER_API_KEY`, `KASHIER_SECRET_KEY`
- `analytics/mongo` â†’ `MONGO_URI`

(You don't know the DB/MQ/Mongo endpoints yet â€” create with placeholders now, **edit the
values after Phase 6**.) Copy each secret's **ARN** for the task definitions.

> âš ï¸ **Two syntax traps that cost us hours** (Phase 7 uses these):
> - To reference one JSON key of a secret in a task def, the ARN is
>   `arn:â€¦:secret:NAME-<suffix>:KEYNAME::` â€” **the two trailing colons are required**.
>   Missing them â†’ `unexpected ARN format with parameters`.
> - The `KEYNAME` must be the **exact** key in the secret. e.g. the env var is
>   `CORE_INTERNAL_API_KEY` but the secret's key is `INTERNAL_API_KEY`, so the `valueFrom`
>   uses `â€¦core/internal-xxxx:INTERNAL_API_KEY::`. Mismatch â†’ `secret did not contain json
>   key â€¦`.

---

## Phase 6 â€” Data stores (all private, no public access)

Each one: **VPC = quickbite**, **subnet group = the 2 PRIVATE subnets**, **Public access =
No**, and the matching SG. After each is up, paste its endpoint into the matching secret
(Phase 5).

1. **RDS PostgreSQL Ã—5** (1 `core`, 4 order shards: `eg`, `ksa`, `archive-eg`, `archive-ksa`).
   - Create â†’ Postgres â†’ subnet group + `rds-sg` â†’ **Public access No**.
   - âš ï¸ **RDS forces SSL.** The app connects with SSL (already handled in the final code â€”
     see the knex config in the zip). If you ever see `no pg_hba.conf entry â€¦ no encryption`,
     that's an app connecting without SSL.
   - Size note: pick at least `db.m7g.large` for the hot shards if you'll load-test.
2. **Amazon DocumentDB Ã—1** (analytics).
   - âš ï¸ DocumentDB **requires TLS**. The `MONGO_URI` includes `tls=true&tlsCAFile=global-bundle.pem`,
     and the analytics image **bundles that CA file** (see the analytics Dockerfile in the zip,
     it `ADD`s `global-bundle.pem` and `chmod`s it readable). Use `retryWrites=false`.
3. **ElastiCache for Valkey/Redis** â€” **READ THIS, it bit us hardest.**
   - Create with **"Design your own cache"** (NOT Serverless), **Cluster mode = DISABLED**,
     and **Encryption in transit = OFF**, **No access control (no AUTH)**, subnet group +
     `redis-sg`.
   - **Why:** the app uses a plain single-node, non-TLS Redis client. A **cluster-mode**
     endpoint (`clustercfg.â€¦`) or **TLS-required** cache makes every Redis call **silently
     hang** (the client can't shard keys / can't do the TLS handshake) â†’ requests time out at
     the ALB's 15s â†’ **504**, while the **health check stays green** (health only pings the DB).
     Serverless is always cluster-mode, so don't use it. Use the **primary endpoint**
     (`â€¦ng.0001.â€¦`, not `clustercfg.â€¦`) for `REDIS_HOST`.
4. **Amazon MQ â€” RabbitMQ** â†’ single-instance â†’ private subnets + `mq-sg`. Use the
   **`amqps://â€¦:5671`** endpoint (not 5672). Save to the `mq` secret.

âœ… Done when: every endpoint is filled into Secrets Manager.

---

## Phase 7 â€” Build & push the images

From each repo root (Dockerfiles are in the zip / repos):
```bash
aws ecr get-login-password --region eu-north-1 --profile quickbite \
 | docker login --username AWS --password-stdin <acct>.dkr.ecr.eu-north-1.amazonaws.com

docker build --platform linux/amd64 -t <acct>.dkr.ecr.eu-north-1.amazonaws.com/<repo>:latest .
docker push <acct>.dkr.ecr.eu-north-1.amazonaws.com/<repo>:latest
```
> âš ï¸ **Always build `--platform linux/amd64`.** Fargate runs x86_64; if you build on an
> Apple-Silicon Mac without that flag you get an **arm64** image and the task fails with
> `image Manifest does not contain descriptor matching platform 'linux/amd64'`. (Your CI
> on GitHub runners already builds amd64.)

---

## Phase 8 â€” ECS cluster, task definitions, roles

### 8.1 Cluster
ECS â†’ **Create cluster** â†’ name `quickbite-1` â†’ **Fargate**.
> Note the name you actually pick â€” everything (CI, run-task) references it. We used
> `quickbite-1`.

### 8.2 Execution role & task role
- **Task execution role** (`ecsTaskExecutionRole`): attach `AmazonECSTaskExecutionRolePolicy`
  **plus** an inline policy granting **`secretsmanager:GetSecretValue`** on every secret ARN,
  **and `logs:CreateLogGroup`** on `arn:aws:logs:eu-north-1:<acct>:log-group:/ecs/*`.
  > âš ï¸ The default exec policy has `CreateLogStream`/`PutLogEvents` but **not**
  > `CreateLogGroup`. If your task defs set `awslogs-create-group: true` (ours do), you
  > **must** add `logs:CreateLogGroup` or every task dies with `AccessDenied â€¦ CreateLogGroup`.
  > (Alternative: pre-create the `/ecs/<name>` log groups and don't auto-create.)
- **Task role** (app's own AWS perms): start empty / minimal.

### 8.3 Task definitions
Use the **task-def JSONs in the zip** (one per service + the workers). They already encode
the lessons below â€” read them, don't reinvent. Register each: ECS â†’ Task definitions â†’
Create â†’ switch to **JSON** â†’ paste â†’ Create. Key things baked in (so you understand them):
- **Image = `<repo>:latest`** (a **tag**, never a pinned `@sha256:â€¦` digest). If you pin a
  digest, CI's new `:latest` never reaches the service.
- **`runtimePlatform: X86_64 / LINUX`** â€” must match the amd64 image (Phase 7).
- **Secrets** in the `secrets[]` block with `valueFrom` ARNs (the `:KEY::` syntax, Phase 5),
  **not** as plain `environment` values (ECS doesn't resolve ARNs put in `environment`).
- **Migrations env for prod:** `DB_MIGRATION_DIRECTORY=dist/migrations`,
  `DB_MIGRATION_EXTENSION=js` (the prod image is compiled JS â€” no `tsx`/`ts-node`).
- **`CORE_SERVICE_BASE_URL=http://core-service:3000`** (resolved by Service Connect, Phase 10).
- **`DB_POOL_MAX`** â€” keep it **sane** (~10â€“20). It's **per task per shard**; the DB's
  `max_connections` (â‰ˆ900 on `db.m7g.large`) must cover `pool Ã— tasks`. **Do not** set 1000.
- **No `aws-otel-collector` sidecar** unless you've set up NAT or mirrored its public image â€”
  it pulls from `public.ecr.aws` and times out in private subnets otherwise.
- **Workers** (`core-worker`, `order-worker`): same image, **command override**
  `["node","dist/worker.js"]`, **no port mapping**.
- **Migrate task defs** (`core-migrate`, `order-migrate`): same image + secrets, container
  named `app`, **no port** â€” used by CI's one-off migrate step.

---

## Phase 9 â€” Services (one API service per repo + workers)

For **core / order / analytics** (from the task def â†’ **Deploy â†’ Create service**, cluster
`quickbite-1`):
- Launch type **Fargate**, **Desired 2**.
- **Networking:** VPC `quickbite`, **2 PRIVATE subnets**, SG `ecs-sg`, **Public IP** per your
  choice (we used the private subnets; if those have no NAT/IGW route a public IP is a no-op).
- **Health-check grace period:** ~120s (lets the app boot before health checks judge it).
- **Autoscaling:** min 2 / max 6, target tracking **ECSServiceAverageCPUUtilization = 60**.

For **core-worker / order-worker**: Create service, **Desired 1**, same networking,
**no load balancer**, **no Service Connect server** (client-only), optional autoscaling.

> analytics has **no worker** (its consumer runs inside the Go binary).
> So: each Node service = **2 ECS services** (api + worker); analytics = **1**.

---

## Phase 10 â€” Load balancer (one ALB, path-routed)

We use **one** internet-facing ALB; **core is the default backend**, order & analytics own
specific paths.

1. **Target groups** (EC2 â†’ Target groups â†’ Create), **type = IP**, port 3000, your VPC:
   - `core-tg` â€” **health check path `/api/health`**
   - `order-tg` â€” **health check path `/api/health`**
   - `analytics-tg` â€” **health check path `/health`**
   > âš ï¸ The health path **must** return **200**. The default `/` returns 404 on these apps â†’
   > targets show **unhealthy** and the ALB 503s even though the containers are fine.
2. **ALB:** EC2 â†’ Load balancers â†’ Create **Application Load Balancer**, internet-facing,
   **PUBLIC subnets**, SG `alb-sg`. Add an **HTTP:80 listener**, default action **forward â†’
   `core-tg`**.
3. **Listener rules** (HTTP:80), in priority order:
   - `/api/v1*` â†’ `analytics-tg`
   - order paths â†’ `order-tg`: `/api/orders*`, `/api/customer/orders*`, `/api/agents/*`,
     `/api/payments/*`, `/api/admin/orders/*`, `/api/restaurants/*/{orders*,balance,payouts*,payments/*,branches/*/orders*}`,
     and **`/ws*`** (the WebSocket â€” the path is **`/ws`**, not `/socket.io`).
   - everything else â†’ **default â†’ `core-tg`** (core).
   > âš ï¸ Rule limits: **max 5 path values per rule** and **max 6 wildcards per rule** â€” split
   > into multiple rules if you exceed them.
4. **Attach the services to their target groups.** When you created the services you can pick
   the target group; for an existing service without one, `update-service --load-balancers â€¦`.

> **Reading failures:** a **504 "upstream request timeout"** means the ALB routed fine but
> the **backend hung** (e.g. the Redis trap) â€” *not* a routing problem. Routing problems are
> **404** (no rule) or **503** (no healthy target).
>
> **HTTPS:** this is **HTTP-only**. With `NODE_ENV=production` the auth cookie is `Secure`, so
> it won't ride plain HTTP in a browser. For real HTTPS you need a **domain** + an **ACM cert**
> + a **443 listener** (+ 80â†’443 redirect). Server-to-server callers (e.g. Kashier webhooks)
> work fine over HTTP.

---

## Phase 11 â€” Service Connect (internal service-to-service)

So `http://core-service:3000` resolves **inside the VPC** (no public ALB hop):

1. Create a **Cloud Map namespace** type **API calls (HTTP)** named `quickbite`
   (ECS â†’ cluster â†’ Update cluster â†’ Service Connect namespace).
2. Give each receiving task def a **named port** on 3000 (Port mappings â†’ Port name).
3. On each service â†’ **Update â†’ Service Connect â†’ Turn on**, namespace `quickbite`:
   - core / order / analytics: mode **Client and server**, advertise **DNS alias =
     `core-service` / `order-service` / `analytics-service`**, port **3000**.
   - workers: mode **Client side only**.
4. Force new deployment. Now `CORE_SERVICE_BASE_URL=http://core-service:3000` resolves â€” no
   env change needed. (Without this, internal calls hang/404.)

---

## Phase 12 â€” Migrations

Run migrations as a **one-off Fargate task** in the **private subnets** (so it reaches the
private DBs), using the `core-migrate` / `order-migrate` task defs:
- core: `npm run migrate` (one DB)
- order: `npm run migrate:all` (loops every shard)

> âš ï¸ The prod image has **no `tsx`/`ts-node`** (devDeps are stripped). The migrate scripts in
> the final code run the **compiled** knexfile (`dist/â€¦`) â€” that's why the task defs set
> `DB_MIGRATION_*` to the `dist` paths. analytics needs **no migrations** (DocumentDB builds
> its indexes on boot).
>
> âš ï¸ In CI's migrate step you **cannot** override the container `image` in
> `aws ecs run-task --overrides` (only name/command/env/cpu/memory). The migrate task def must
> already point at `:latest`; the build pushes `:latest` first, then run-task picks it up.

---

## Phase 13 â€” Seed data (via a bastion EC2)

The RDS/DocumentDB are private, so seed from a small EC2 **inside the VPC**. The **seed SQL +
the Mongo seed are in the zip**.

1. **Launch EC2** (Amazon Linux 2023, `t3.micro` ok for seeding), **PUBLIC subnet**,
   **auto-assign public IP ON**, security groups = **`ecs-sg`** (so it reaches the DBs) **+ a
   new SG allowing SSH 22**.
   > âš ï¸ EC2 Instance Connect (browser SSH) needs **port 22 open** on a SG attached to the
   > instance, and the instance needs a **public IP**. If "Failed to connect," it's almost
   > always a missing 22 inbound rule.
2. Connect (EC2 Instance Connect), then install clients:
   ```bash
   sudo dnf install -y postgresql15
   printf '[mongodb-org-7.0]\nname=MongoDB\nbaseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/7.0/x86_64/\ngpgcheck=0\nenabled=1\n' | sudo tee /etc/yum.repos.d/mongodb-org-7.0.repo
   sudo dnf install -y mongodb-mongosh
   curl -sO https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem   # DocumentDB CA
   ```
3. Get the seed files onto the box (upload to S3 then `aws s3 cp`, or paste with `nano`).
4. Run (use `sslmode=require` for Postgres; the connection details come from your secrets):
   ```bash
   # core
   psql "host=<core-rds> ... dbname=<core db> sslmode=require" -v ON_ERROR_STOP=1 -f seed-core.sql
   # order â€” once per shard with the region vars (see the file header)
   psql "host=<eg shard> ... dbname=<order db> sslmode=require" -v region=eg ... -f seed-order.sql
   psql "host=<ksa shard> ... dbname=<order db> sslmode=require" -v region=ksa ... -f seed-order.sql
   # analytics (DocumentDB) â€” global-bundle.pem must be in the cwd
   mongosh "mongodb://<user>:<pw>@<docdb>:27017/analytics?tls=true&tlsCAFile=global-bundle.pem&replicaSet=rs0&retryWrites=false&authMechanism=SCRAM-SHA-1" seed-analytics.js
   ```
   > âš ï¸ DocumentDB rejects mongosh's default auth â†’ add **`authMechanism=SCRAM-SHA-1`**
   > (otherwise `Unsupported mechanism`).

> ðŸ› ï¸ **A bug we fixed (FYI):** the `nearby` (geo) query had a **units bug** â€” branch
> `delivery_radius` is stored in **meters**, but the query multiplied it by 1000, so the
> search radius became ~5,000 km and matched every branch. The **final code in the zip fixes
> this** (no `Ã—1000`). Nothing for you to do â€” just know the seeded `delivery_radius` is in
> meters.

> ðŸ§¹ **Cost:** **terminate the bastion** when seeding is done, and remove the SSH-22 rule.

---

## Phase 14 â€” CI/CD (GitHub Actions, per repo)

The **`.github/workflows/deploy.yml`** for each repo is in the zip (commented). It does
**test â†’ build â†’ push â†’ migrate â†’ deploy**, gated so a failed test blocks the deploy.

1. **One-time OIDC role:** IAM â†’ Identity providers â†’ add
   `token.actions.githubusercontent.com` (audience `sts.amazonaws.com`). Create role
   **`github_deploy`** (Web identity), **scope the trust policy to your repo's `sub`**, and
   grant ECR push (with `ecr:GetAuthorizationToken` on `*`), `ecs:UpdateService`/`RunTask`/
   `DescribeTasks`, and `iam:PassRole` for the exec + task roles
   (`iam:PassedToService = ecs-tasks.amazonaws.com`).
2. In each `deploy.yml`, set the `env:` block to **your real values**: region, account,
   **cluster = `quickbite-1`** (not `quickbite`), the **2 private subnet ids**, `ecs-sg` id,
   and `role-to-assume: â€¦role/github_deploy`. The test job runs your
   `docker-compose.test.yml`; the deploy job has `needs: test`.
3. Push to the deploy branch (core = `master`, order/analytics = `main`) â†’ watch the
   **Actions** tab. The deploy is a **rolling update**: ECS starts new tasks, waits for them
   to pass the ALB health check, shifts traffic, then drains the old ones â€” **zero downtime**;
   a failing new task stalls the rollout instead of taking you down.

---

## Phase 15 â€” Logs & observability

`awslogs` ships every container's stdout to **CloudWatch â†’ `/ecs/<service>`**.
- One task's logs: ECS â†’ service â†’ Tasks â†’ a task â†’ **Logs** tab.
- Across tasks: **CloudWatch â†’ Logs Insights**, pick `/ecs/*`, filter for `ERROR`, a
  `correlationId`, or `Redis`.
- Terminal: `aws logs tail /ecs/order-service --follow`.
- Set **retention** on each `/ecs/*` group (e.g. 30 days) so logs don't bill forever.

> Debugging method when something hangs and logs are quiet: a **504 = a hang, not a crash**;
> find a **passing endpoint** to rule out the ALB/service; **run the slow query in psql** to
> rule out the DB; **read the health handler** (ours is DB-only, which is why Redis outages
> don't reboot tasks); then read which middleware the failing route uses (cache/idempotency =
> Redis). That black-box method found the Redis issue without any error logs.

---

## Phase 16 â€” Load testing (k6)

The **k6 script is in the zip** (`loadtest.js`). It drives the hot path (browse + nearby +
orders + history) at a configurable rate.

**Two ways to run:**
- **Grafana Cloud k6** (easiest dashboard): `k6 cloud run loadtest.js`. The **free/trial tier
  caps concurrent VUs and VUh**, so the full target may not fit â€” scale down with
  `-e RATE_SCALE=â€¦`. (VUs â‰ˆ req/s Ã— latency; the script pre-allocates accordingly.)
- **k6 OSS on an EC2** (no VU cap, full control): launch a `c5.2xlarge` in a public subnet,
  `curl` the k6 binary, and `k6 run`. Best for the real 625 req/s+.

**Knobs (all `-e`):**
- `ALB_URL` (defaults to your ALB), `ACCESS_SECRET` (the **real** one from `core/auth`, so the
  order/history scenarios authenticate â€” browse scenarios are public and need nothing),
  `RATE_SCALE` (global multiplier; 1 â‰ˆ 625 req/s), `DURATION` (e.g. `2m`),
  `ORDER_PAYMENT_METHOD` (`cod` keeps it self-contained â€” online payments need NAT to reach
  Kashier).

**Reading the result:**
- `http_reqs â€¦ <rate>/s` â†’ the **rate** is the load k6 actually generated.
- `dropped_iterations` â‰ˆ 0 â†’ k6 kept up (if high: your load box is too small, or the plan
  capped VUs).
- `http_req_failed < 1%` and `http_req_duration p95` within target â†’ the platform **absorbed**
  it. Rising p95 + 503s + dropped iterations = you found the ceiling (scale services / DB).

> **Stress mode:** bump `RATE_SCALE` (e.g. 5â€“10Ã—). Watch that **`DB_POOL_MAX Ã— tasks` stays
> under the DB's `max_connections`** as autoscaling climbs, or you'll trade latency for
> Postgres "too many connections." For real headroom, put **RDS Proxy** in front and keep app
> pools small.

---

## Final checklist (the things that actually bite)

- [ ] 4 interface endpoints: **Private DNS ON**, SG = `ecs-sg` (else `CannotPullSecrets`).
- [ ] Exec role has **`secretsmanager:GetSecretValue`** + **`logs:CreateLogGroup`** (+ `kms:Decrypt` if CMK).
- [ ] Secret `valueFrom` ARNs end in **`:KEY::`** and the **KEY matches the secret's JSON key**.
- [ ] Task def **image is a `:latest` tag**, not a digest; **`runtimePlatform = X86_64`**; images built `--platform linux/amd64`.
- [ ] **No otel sidecar** unless you have NAT / a mirror.
- [ ] **ElastiCache: cluster-mode DISABLED + TLS OFF**; `REDIS_HOST` = primary endpoint (not `clustercfg.â€¦`).
- [ ] **RDS connections use SSL**; **DocumentDB has the CA bundle in the image**; **MQ is `amqps://â€¦:5671`**.
- [ ] Target-group health path returns **200** (`/api/health`, `/health`) â€” not `/`.
- [ ] WebSocket routes on **`/ws*`**; order vs core path rules don't shadow each other.
- [ ] **Service Connect** on all services (shared `quickbite` namespace, DNS alias = service name, port 3000).
- [ ] Migrations run in **private subnets**, on the **compiled** code; `DB_POOL_MAX` sane (not 1000).
- [ ] CI: cluster name = **`quickbite-1`**, real subnets/SG, `github_deploy` role, test gates deploy.
- [ ] Terminate the **bastion** + release its EIP, and **delete the NAT** when you stop testing (cost).

> Everything code-shaped â€” Dockerfiles, task-def JSONs, `deploy.yml`, knex/cache config, seed
> SQL, `loadtest.js` â€” is in the **zipped resources**, with my comments inline. This guide is
> the *operational* path; the zip is the *source of truth* for code.