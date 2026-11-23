# Week 10 Runbook: CI/CD for PropertyLite with GitHub Actions and OIDC

**Goal:** a `git push` to `main` automatically builds the PropertyLite image, pushes it to ECR, and rolls it out to ECS Fargate. GitHub authenticates to AWS with short-lived OIDC credentials. No AWS access keys are stored anywhere in GitHub.

**Time:** about 2 hrs concepts, 4 to 6 hrs lab.
**Cost:** IAM and OIDC are free. The only meter is the Week 9 Fargate task. Tear it down when you finish.
**Environment:** Windows + WSL2 Ubuntu. Commands run in the WSL terminal unless noted.

**Sources:** I pulled the facts below from official AWS and GitHub pages, listed in the Sources section at the end. Where I'm relying on general knowledge instead, I say so.

---

## Read this first: where this runbook differs from the handbook

I checked the handbook's Week 10 against current docs. Five things matter, and the first one will probably bite you.

1. **Your trust policy `sub` may need numeric IDs.** GitHub changed the default OIDC `sub` claim. Repos created on or after **15 July 2026** emit an immutable format: `repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main`. The handbook's trust policy (`repo:<user>/aws-cloud-engineer-journey:*`) only matches the old name-only format. If your repo is newer than that date, the handbook version fails with the same `Not authorized to perform sts:AssumeRoleWithWebIdentity` error described in its Debug Lab 10.2. Step 1 below handles both formats.
2. **The handbook's Debug Lab 10.2 explanation is off.** It says `id-token: write` at the workflow level doesn't cascade to jobs. GitHub's docs say the permission can be set at workflow or job level. What does bite people: a job that declares its own `permissions:` block replaces the workflow-level one. The far more common cause of that error is the `sub` mismatch above.
3. **The workflow file must live at the repo root:** `.github/workflows/deploy.yml`. GitHub only runs workflows from there. The handbook's deliverable path `week-10/.github/workflows/deploy.yml` is a copy for submission, not the live file.
4. **Action versions are out of date.** The handbook uses `configure-aws-credentials@v4`. The README currently shows `v6.2.4` (floating tag `v6`), and GitHub's own docs sample uses `actions/checkout@v6`.
5. **The handbook's `docker tag` line has a PDF line-wrap typo** (`us-east1`). This runbook avoids it by using the `amazon-ecr-login` action, which hands you the registry URI.

---

## Part A. Concepts (read before touching anything)

### 1. CI vs CD, and what you're building
- **Continuous Integration (CI):** every change is automatically built (and tested) so breakage shows up in minutes.
- **Continuous Delivery:** every change is always in a deployable state, but a human clicks "go."
- **Continuous Deployment:** every change that passes goes to production automatically.

What you build this week is continuous deployment: push to `main`, production updates. Analogy: an assembly line where every part is inspected and placed on the truck without anyone carrying it by hand. The line only runs when the inspection (build) passes.

The handbook calls `main` "the only way code reaches production." That's the whole point: nobody runs `docker push` from a laptop anymore.

### 2. GitHub Actions vocabulary

| Term | What it is |
|---|---|
| **Workflow** | A YAML file in `.github/workflows/`. One automation. |
| **Event / trigger** | What starts it: `push`, `pull_request`, `workflow_dispatch` (manual button). |
| **Job** | A group of steps that run on one machine. Jobs run in parallel unless you chain them. |
| **Step** | One command (`run:`) or one reusable action (`uses:`). |
| **Runner** | The fresh VM GitHub spins up for a job (`ubuntu-latest`). It is thrown away afterward, so nothing persists between runs. |
| **Action** | A packaged, reusable step, like a library function. `uses: owner/name@version`. |
| **Context** | `${{ github.sha }}` style values GitHub fills in, like the commit hash. |

Because the runner is a blank VM every time, the workflow has to check out your code, log in to AWS, and log in to ECR from scratch on every run.

### 3. Why not just store AWS keys as GitHub secrets?
A long-lived access key stored in GitHub is a standing credential. If it leaks (a log, a compromised action, a forked repo), it works until someone notices and rotates it.

Analogy: a key hidden under the doormat vs a hotel key card. The card is issued after the front desk checks your ID, works for one room, and expires in an hour.

The AWS README for the credentials action puts it plainly: OIDC is the recommended method because it provides temporary credentials and is easy to set up.

### 4. How OIDC works, step by step
OIDC (OpenID Connect) lets GitHub vouch for a workflow run, and lets AWS decide whether to believe it.

```
1. Workflow starts. GitHub's OIDC provider mints a signed JWT (ID token) for THIS run.
2. The token carries claims: who issued it (iss), who it's for (aud), and the subject (sub),
   which says which repo/branch/environment is running.
3. configure-aws-credentials sends that token to AWS STS:
   AssumeRoleWithWebIdentity, naming the role it wants.
4. AWS checks: is the token signed by a provider I trust? Do the aud and sub match the
   role's trust policy conditions?
5. If yes, STS returns temporary credentials (default 1 hour per the action README).
6. Every later aws CLI call in the job uses those credentials. They expire on their own.
```
No secret is ever stored. The "secret" is minted per run and dies with it.

### 5. The three IAM pieces (don't mix them up)
| Piece | Question it answers | You create it in |
|---|---|---|
| **OIDC identity provider** | "Do I trust tokens from `token.actions.githubusercontent.com`?" | Step 2 |
| **Role trust policy** | "WHO may assume this role?" (matches `aud` and `sub`) | Step 3 |
| **Role permissions policy** | "WHAT can they do once they're in?" | Step 3 |

This is the same trust-vs-permissions split from Week 9. There, the trust policy's principal was `ecs-tasks.amazonaws.com` (a service). Here the principal is `Federated`, pointing at the GitHub OIDC provider, and the action is `sts:AssumeRoleWithWebIdentity`.

AWS docs note that for the provider, the URL is `https://token.actions.githubusercontent.com` and the audience is `sts.amazonaws.com`. AWS secures communication with OIDC providers using its library of trusted root CAs, and the credentials action README says the old thumbprint instructions are no longer necessary (a specified thumbprint is ignored).

### 6. The trust policy conditions (the actual security boundary)
Without a condition, **any GitHub repo on the internet** could assume your role. GitHub says you must define at least one condition so untrusted repositories can't request tokens.

Two claims matter:
- **`aud`** (audience): must be `sts.amazonaws.com`.
- **`sub`** (subject): pins the repo and branch/environment.

`sub` formats you will see:
```
Legacy:     repo:octo-org/octo-repo:ref:refs/heads/main
Immutable:  repo:octo-org@123456/octo-repo@789012:ref:refs/heads/main
PR:         repo:octo-org/octo-repo:pull_request
Environment repo:octo-org/octo-repo:environment:prod
```
Why the immutable format exists: if someone deletes a GitHub account or repo and another person grabs the same name, name-only trust policies would match the new owner. Numeric IDs can't be recycled. Per the credentials action README, a legacy-format policy plus an immutable-format repo fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

Use `StringEquals` for an exact match. Use `StringLike` only when you deliberately want wildcards. The README also warns to avoid `ForAllValues:` in `Allow` statements.

### 6b. The `permissions:` block in a workflow
`id-token: write` lets the job request the OIDC token. It does **not** give write access to your repo or AWS; GitHub's docs say it only allows requesting and using the token. `contents: read` is needed for `actions/checkout`.

Set it at workflow level or inside the job. If a job defines its own `permissions:`, treat that as replacing the workflow-level one and repeat both lines there.

### 7. ECR auth and why we use an action
`aws ecr get-login-password` gives a Docker login token (you used it in Week 9; it lasts 12 hours, which I know from general AWS knowledge). The `aws-actions/amazon-ecr-login@v2` action does the same thing inside the runner and returns the registry URI as an output. It needs the `ecr:GetAuthorizationToken` permission.

### 8. Image tags: `latest` vs the commit SHA
- `latest` is mutable. It points at whatever was pushed last, so you can't tell which commit a running task is built from.
- A tag like `${{ github.sha }}` is unique per commit. It gives you traceability and a clean rollback target.

The pipeline pushes **both**: the SHA for traceability, `latest` because your Week 9 task definition points at `latest`.

### 9. How ECS actually deploys the new image
Your task definition says `...property-api:latest`. Pushing a new image with that tag does nothing by itself, because the running task already pulled the old one.

`aws ecs update-service --force-new-deployment` tells ECS to start new tasks without changing the service definition. AWS docs describe exactly this use: pick up a newer image under the same tag. New tasks pull the current image/tag combination when they start.

For a rolling deployment, ECS starts the new task, waits for it to be running, then stops the old one. Practical consequences:
- For a moment you have **two tasks**, so there are two public IPs.
- The IP **changes** after every deploy (no ALB yet; Week 12 fixes this).
- If the new task fails to start, the old one keeps running. A broken deploy doesn't take the site down.

### 10. Blue/green, for the exam and Week 12
- **Rolling** (this week): replace tasks gradually in the same environment.
- **Blue/green:** stand up a full second copy ("green"), test it, flip traffic from "blue" to green, keep blue around for instant rollback.
- **Canary:** send a small slice of traffic to the new version first.

You don't build blue/green this week; it's one of the Week 12 depth options. Know the definitions for SAA-C03.

### 11. Two good habits you'll use here
- **`concurrency:`** ensures two pushes in quick succession don't run two deploys at once.
- **Pin your actions.** `@v6` is a floating tag that moves. GitHub's own docs sample pins the AWS action to a full commit SHA. For this lab `@v6` is fine; know the trade-off.

### Self-check (answer out loud before Step 1)
1. What three things does AWS verify before handing a workflow temporary credentials?
2. Why is a role trust policy with no `sub` condition dangerous?
3. If your repo was created last month, what will the `sub` look like, and what happens if your trust policy uses the old format?
4. Why does `docker push` of a new `latest` not change what's running on ECS?
5. During a rolling deploy where the new task crashes, what is still serving traffic?

---

## Part B. Preflight

### 1. Is Week 9 still up?
Week 9's cleanup destroyed it. The pipeline needs these to exist: ECR repo `property-api`, ECS cluster `training-cluster`, service `property-api-service`. If you tore them down, rebuild:

```bash
cd ~/aws-cloud-engineer-journey/propertylite
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

aws ecr create-repository --repository-name property-api --region $AWS_REGION
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URI
docker build -t property-api .
docker tag property-api:latest $ECR_URI/property-api:latest
docker push $ECR_URI/property-api:latest

cd ~/aws-cloud-engineer-journey/week-09
terraform init && terraform apply
```
Then follow the Week 9 runbook, Step 6, to confirm `/health` returns `{"status":"ok"}`. This is your "before" snapshot.

**You'll know it worked when:** `curl http://<task-ip>:8080/health` returns `{"status":"ok"}` with no `version` field yet.

### 2. Repo layout check
```
aws-cloud-engineer-journey/
  .github/workflows/        <- live workflows go here (repo ROOT)
  propertylite/
  week-09/
  week-10/                  <- notes and a COPY of the workflow for the deliverable
```
```bash
cd ~/aws-cloud-engineer-journey
mkdir -p .github/workflows week-10
git status        # should be clean before you start
git branch        # confirm you are on main
```

### 3. Tools
```bash
sudo apt-get update && sudo apt-get install -y jq
jq --version
```

---

## Part C. The lab

### Step 1. Collect the identifiers you need
```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GH_USER=<your-github-username>
export GH_REPO=aws-cloud-engineer-journey
echo $ACCOUNT_ID $GH_USER $GH_REPO
```
Now fetch the numeric IDs GitHub uses in the immutable `sub` format (works for a public repo; for a private repo add `-H "Authorization: Bearer <token>"` or read the IDs from the repo settings page):
```bash
curl -s https://api.github.com/repos/$GH_USER/$GH_REPO | jq '{repo_id: .id, owner_id: .owner.id}'
```
```bash
export OWNER_ID=<owner_id from output>
export REPO_ID=<repo_id from output>
```
**You'll know it worked when:** you have two numbers set. If `jq` prints `null`, the repo name or username is wrong (or the repo is private; see above).

**Common mistakes:** a typo in `GH_USER` (GitHub usernames are case-insensitive but the `sub` claim uses the real casing, so copy it exactly from your profile URL). These variables die when you close the terminal.

---

### Step 2. Create the OIDC identity provider (once per AWS account)
Check whether one already exists:
```bash
aws iam list-open-id-connect-providers
```
If you do not see `token.actions.githubusercontent.com` in the output, create it:
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```
Console equivalent: IAM, Identity providers, Add provider, OpenID Connect, URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.

**You'll know it worked when:** the CLI returns an ARN ending in `oidc-provider/token.actions.githubusercontent.com`, and the provider appears in IAM, Identity providers.

**Common mistakes:** `EntityAlreadyExists` just means it's already there, which is fine. A typo in the URL creates a useless provider.

---

### Step 3. Create the role (trust policy + permissions)

**3a. Trust policy.** This accepts exactly your `main` branch, in whichever `sub` format your repo emits. Two exact values, no wildcards:
```bash
cd ~/aws-cloud-engineer-journey/week-10
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": [
            "repo:${GH_USER}@${OWNER_ID}/${GH_REPO}@${REPO_ID}:ref:refs/heads/main",
            "repo:${GH_USER}/${GH_REPO}:ref:refs/heads/main"
          ]
        }
      }
    }
  ]
}
EOF
cat trust-policy.json
```
Read it. Confirm the variables expanded (no `${...}` left, no blank values). Once your pipeline works and you know which format your repo uses, delete the line you don't need.

**3b. Permissions policy.** Two options.

*Option A (handbook, fast, broad):* attach the managed policies `AmazonECS_FullAccess` and `AmazonEC2ContainerRegistryPowerUser`. Works, but far more access than a pipeline needs.

*Option B (recommended, least privilege, same habit as Weeks 2 and 7):*
```bash
cat > deploy-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrLogin",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushToOneRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/property-api"
    },
    {
      "Sid": "EcsRedeployOneService",
      "Effect": "Allow",
      "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
      "Resource": "arn:aws:ecs:${AWS_REGION}:${ACCOUNT_ID}:service/training-cluster/property-api-service"
    }
  ]
}
EOF
```
**Confidence note:** I built Option B from the ECR login action's documented minimum (`ecr:GetAuthorizationToken`) plus the standard ECR push actions and ECS service actions, but I did not run it against a live account. If the pipeline fails with `AccessDeniedException`, the error message names the exact missing action. Add it, or fall back to Option A to get unstuck.

**3c. Create the role and attach the policy:**
```bash
aws iam create-role \
  --role-name github-actions-deploy-role \
  --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
  --role-name github-actions-deploy-role \
  --policy-name deploy-property-api \
  --policy-document file://deploy-policy.json

aws iam get-role --role-name github-actions-deploy-role --query Role.Arn --output text
```
Copy the printed role ARN. You need it in the workflow.

**You'll know it worked when:** `get-role` prints `arn:aws:iam::<account-id>:role/github-actions-deploy-role`.

**Common mistakes:**
- Naming the role exactly `GitHubActions`. The credentials action README notes this name has been reported not to work. The name used here is fine.
- Forgetting the trust policy and permissions policy are separate things. Trust controls who gets in; the permissions policy controls what they can do.
- Committing `trust-policy.json`/`deploy-policy.json` is OK (no secrets, account IDs are not secret per the action README), but don't paste access keys anywhere. You created none.

---

### Step 4. Smoke test: prove the OIDC login works before building the pipeline
Don't stack a Docker pipeline on an authentication problem. First test authentication alone.

Create `.github/workflows/oidc-smoke-test.yml` at the **repo root**:
```yaml
name: OIDC smoke test

on:
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  whoami:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-deploy-role
          aws-region: us-east-1

      - name: Who am I?
        run: aws sts get-caller-identity
```
Replace `<ACCOUNT_ID>` with your 12-digit account ID.

```bash
cd ~/aws-cloud-engineer-journey
git add .github week-10
git commit -m "ci: add OIDC smoke test workflow and role policies"
git push
```
Then on GitHub: **Actions** tab, **OIDC smoke test**, **Run workflow**, branch `main`.

**You'll know it worked when:** the run is green and the "Who am I?" step prints an ARN like `arn:aws:sts::<account-id>:assumed-role/github-actions-deploy-role/GitHubActions`. That ARN is an `assumed-role` session, not a user. That's the proof no stored keys were used.

**If it fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`:** go to Part D, first row. 90% of the time it's the `sub` condition.

---

### Step 5. Write the real deploy workflow
Create `.github/workflows/deploy.yml` at the repo root:
```yaml
name: Deploy PropertyLite to ECS

on:
  push:
    branches: [main]
    paths:
      - "propertylite/**"
      - ".github/workflows/deploy.yml"
  workflow_dispatch:

# One deploy at a time. A newer push waits instead of racing the older one.
concurrency:
  group: deploy-property-api
  cancel-in-progress: false

env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: property-api
  ECS_CLUSTER: training-cluster
  ECS_SERVICE: property-api-service

jobs:
  deploy:
    runs-on: ubuntu-latest
    # Repeat both lines here. A job-level permissions block replaces the workflow-level one.
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Check out code
        uses: actions/checkout@v6

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-deploy-role
          role-session-name: gha-${{ github.run_id }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Log in to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push image
        env:
          REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          cd propertylite
          docker build \
            -t $REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -t $REGISTRY/$ECR_REPOSITORY:latest .
          docker push $REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $REGISTRY/$ECR_REPOSITORY:latest

      - name: Roll out to ECS
        run: |
          aws ecs update-service \
            --cluster $ECS_CLUSTER \
            --service $ECS_SERVICE \
            --force-new-deployment > /dev/null

      - name: Wait for the service to stabilize
        run: |
          aws ecs wait services-stable \
            --cluster $ECS_CLUSTER \
            --services $ECS_SERVICE
```
Replace `<ACCOUNT_ID>`.

What each part does:
- `paths:` skips the pipeline when you only edit a Terraform file or a README. Edit `propertylite/**` or this workflow to trigger it.
- `role-session-name: gha-<run id>` makes CloudTrail show which run assumed the role.
- Build then push **both** tags (Concept 8).
- `update-service --force-new-deployment` is Concept 9.
- `wait services-stable` makes the job go red if the new task never becomes healthy. Without it, the pipeline would show green the moment ECS *accepts* the request, even if the deploy is broken. This is the handbook's "you've automated the wrong thing" trap.

**Common mistakes:**
- Putting the file under `week-10/.github/workflows/`. GitHub will never run it.
- YAML indentation. Use spaces, never tabs. If the Actions tab shows "Invalid workflow file," the error names the line.
- `aws ecs wait` polls on a fixed schedule and gives up after a limited number of attempts (about 10 minutes, from general knowledge). If a deploy is slow, it can time out even though ECS eventually succeeds.

---

### Step 6. Prove the pipeline ships code, not just a redeploy
The handbook's check, done properly. Edit `propertylite/app.py`:
```python
@app.route("/health")
def health():
    return jsonify(status="ok", version="1.1")
```
Test locally first (Week 9 habit):
```bash
cd ~/aws-cloud-engineer-journey/propertylite
docker build -t property-api . && docker run --rm -p 8080:8080 property-api
# second terminal:
curl http://localhost:8080/health      # expect version 1.1
```
Then ship it only through git:
```bash
cd ~/aws-cloud-engineer-journey
git add propertylite/app.py .github/workflows/deploy.yml
git commit -m "feat: add version marker to /health"
git push
```
Watch **Actions**, the new run. Expect roughly 1 minute for build and push, then 2 to 4 minutes waiting for ECS.

**You'll know it worked when:** the run is green and the next section's curl returns `"version":"1.1"`.

---

### Step 7. Verify from the AWS side
Save this helper as `week-10/get-task-ip.sh` (it's the Week 9 lookup chain in one file):
```bash
#!/bin/bash
set -euo pipefail
REGION=us-east-1
CLUSTER=training-cluster
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --desired-status RUNNING \
  --query "taskArns[0]" --output text --region $REGION)
ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
  --output text --region $REGION)
aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID \
  --query "NetworkInterfaces[0].Association.PublicIp" --output text --region $REGION
```
```bash
chmod +x week-10/get-task-ip.sh
IP=$(./week-10/get-task-ip.sh)
curl http://$IP:8080/health
```
Expected: `{"status":"ok","version":"1.1"}`

Also check the deployment record and the image:
```bash
aws ecs describe-services --cluster training-cluster --services property-api-service \
  --query "services[0].deployments[].{status:status,running:runningCount,desired:desiredCount,created:createdAt}"

aws ecr describe-images --repository-name property-api \
  --query "sort_by(imageDetails,&imagePushedAt)[-3:].{tags:imageTags,pushed:imagePushedAt}"
```
You should see one deployment with status `PRIMARY` and an image tagged with your commit SHA plus `latest`. Compare that SHA to `git log -1 --format=%H`. Matching hashes are your end-to-end proof.

**Common mistakes:** curling the *old* task IP (it changed during the deploy; re-run the script). Curling port 80 (the app is on 8080).

---

### Step 8. Break it on purpose (this is how it sticks)
Do these on a scratch basis and restore after each.
1. **Wrong branch.** Create a branch `test-branch`, add a harmless change under `propertylite/`, and run the smoke test workflow from that branch via **Run workflow**. Expect `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Your trust policy only allows `main`, which is exactly the point. Delete the branch.
2. **Bad sub.** Temporarily edit the role's trust policy `sub` to a typo, re-run the smoke test, read the error, then fix it. This builds your muscle for Debug 10.2.
3. **Bad image.** Change `CMD` in the Dockerfile to something invalid on a scratch commit and push. Watch `aws ecs wait` fail while the old task keeps serving. (Revert and push after.) Concept 9 in action.

---

### Step 9 (optional stretch). Bake the commit SHA into the image
This gives a stronger proof than "1.1": the running app reports its own commit.

Dockerfile, before `CMD`:
```dockerfile
ARG GIT_SHA=dev
ENV GIT_SHA=$GIT_SHA
```
`app.py`:
```python
@app.route("/health")
def health():
    return jsonify(status="ok", version="1.1", commit=os.environ.get("GIT_SHA", "dev"))
```
Workflow build step: add `--build-arg GIT_SHA=$IMAGE_TAG` to `docker build`.

After a push, `/health` returns the commit hash that's in your git log.

### Step 10 (optional stretch). Audit the role in CloudTrail
The AWS Security Blog's walkthrough ends with auditing the role's use in CloudTrail. From general knowledge, event history keeps about 90 days of management events:
```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 --region us-east-1
```
Look for your `gha-<run id>` session name.

---

## Part D. Debug lab: GitHub Actions cannot assume the AWS role

**Symptom:** the run fails at `configure-aws-credentials` with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

**Diagnose in this order (token side first, then trust side):**

| # | Check | How | Fix |
|---|---|---|---|
| 1 | **`sub` format mismatch** (most likely) | Compare the trust policy `sub` values to your repo's real owner/repo IDs from Step 1. Repos created on or after 15 July 2026 emit the `@ID` form. | Use the immutable form in the trust policy (the runbook's policy already includes both). |
| 2 | **Branch or event mismatch** | The `sub` ends in `ref:refs/heads/main` for pushes to main, but `pull_request` for PR runs, and `environment:NAME` if the job uses an environment. | Match the trigger, or add the specific extra `sub` you intend to allow. |
| 3 | **Repo name or owner typo / casing** | Re-read `echo $GH_USER $GH_REPO` and the trust policy: `aws iam get-role --role-name github-actions-deploy-role --query Role.AssumeRolePolicyDocument` | Edit with `aws iam update-assume-role-policy`. |
| 4 | **Provider or audience wrong** | `aws iam list-open-id-connect-providers`; audience must be `sts.amazonaws.com`. | Recreate the provider (Step 2). |
| 5 | **Missing `id-token: write`** | Look at the `permissions:` in the workflow AND inside the job. A job-level block replaces the workflow-level one. | Add both `id-token: write` and `contents: read` where the job can see them. The error wording differs from the AssumeRole error; it usually complains about not getting an ID token. |
| 6 | **Role name** | The action README says naming a role exactly `GitHubActions` has been reported not to work. | Use `github-actions-deploy-role`. |

To see exactly what claims your run sends, the README points to `github/actions-oidc-debugger`, which prints the decoded token. Run it only in a private repo, because the claim values may be sensitive.

**Other failures you'll hit:**

| Error | Cause | Fix |
|---|---|---|
| `AccessDeniedException ... not authorized to perform: ecr:...` or `ecs:...` | Your Option B policy is missing an action | Add the action named in the error, or use Option A temporarily |
| `no basic auth credentials` on `docker push` | ECR login step missing or ran in a different job | Keep login and push in the same job (runners are fresh VMs) |
| `repository does not exist` | Wrong `ECR_REPOSITORY` name, or you tore down Week 9 | Recreate the repo (Preflight 1) |
| Workflow doesn't start | File isn't at `.github/workflows/` in the repo root; you pushed a branch other than `main`; the `paths:` filter excluded your change | Fix location/branch, or use **Run workflow** |
| `aws ecs wait`: "Max attempts exceeded" | New task is failing | `aws ecs describe-tasks` on the stopped task and read `stoppedReason`, then logs (Week 9 debug table). The old task is probably still serving. |
| Green run but `/health` unchanged | Curling the old IP, or Docker build cache/wrong dir | Re-run `get-task-ip.sh`; confirm `cd propertylite` in the build step; compare SHAs (Step 7) |
| `invalid workflow file` | YAML indentation | Spaces, not tabs; check the line number in the error |

**Lesson:** debug the token (GitHub) side before the trust-policy (AWS) side, and read the exact error. Don't guess.

---

## Part E. Cleanup

IAM and the OIDC provider are free and the Week 12 capstone reuses them, so **keep** the role and provider. What costs money is the Week 9 stack:
```bash
cd ~/aws-cloud-engineer-journey/week-09
terraform destroy
aws ecr delete-repository --repository-name property-api --force --region us-east-1
```
After this, pushes to `main` that touch `propertylite/` will fail at the push or deploy step, because the repo and service are gone. Either disable the workflow (GitHub, Actions, Deploy PropertyLite to ECS, three-dot menu, Disable workflow) or only push once you've rebuilt Week 9.

Verify nothing's left and check Billing for $0.00 to $1.00:
```bash
aws ecs list-clusters --region us-east-1
aws ecr describe-repositories --region us-east-1
```

---

## Part F. Deliverable checklist (`week-10/`)
- [ ] `.github/workflows/deploy.yml` (copy of the live root file; the live one stays at `.github/workflows/deploy.yml` in the repo root)
- [ ] Screenshot: green Actions run
- [ ] Screenshot: ECS deployment events (or the `describe-services` output)
- [ ] Screenshot/terminal capture: `curl` showing `"version":"1.1"`
- [ ] `trust-policy.json` and `deploy-policy.json`
- [ ] `billing-screenshot.png` after teardown
- [ ] `README.md` (5 to 8 sentences, your own words): why OIDC beats stored keys

README prompts to cover:
1. What OIDC is and what the JWT claims `aud` and `sub` do.
2. Why short-lived credentials limit the damage of a leak.
3. How the trust policy pins the role to one repo and branch, and why the immutable `sub` format exists.
4. How the role is auditable (CloudTrail session name) compared with a shared access key.

```bash
cd ~/aws-cloud-engineer-journey
cp .github/workflows/deploy.yml week-10/deploy.yml
git add week-10
git commit -m "docs: week 10 deliverables"
git push
```
Note: this push touches only `week-10/`, so the `paths:` filter won't trigger a deploy.

---

## TLDR
Create the GitHub OIDC provider in IAM. Create a role whose trust policy accepts only your repo's `main` branch (use the numeric-ID `sub` if the repo was created after 15 July 2026). Smoke-test the login with `sts get-caller-identity`. Then the real workflow: checkout, assume role, ECR login, build and push SHA + `latest`, `update-service --force-new-deployment`, `wait services-stable`. Prove it by changing `/health` and watching the new version appear. The things most likely to break: the `sub` format, the workflow path, and Week 9 not being up.

## Next step
Before Week 12, add an ECS **deployment circuit breaker** to the service in your Week 9 Terraform (`deployment_circuit_breaker` with `enable` and `rollback` set to true) and re-run Step 8's "bad image" drill. Compare "old task keeps serving" with "ECS automatically rolls back." That is a real step toward the blue/green and rollback work in the capstone. I haven't verified the exact Terraform arguments for the current AWS provider, so check the `aws_ecs_service` docs for the syntax.

---

## Sources (official docs I used)
- GitHub Docs, Configuring OpenID Connect in AWS: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
- GitHub Docs, OpenID Connect reference (claims, `sub` formats, immutable subject claims, workflow permissions): https://docs.github.com/en/actions/reference/security/oidc
- GitHub Changelog, immutable subject claims (linked from the credentials action README): https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
- `aws-actions/configure-aws-credentials` README (quick start, trust policy, versions, role-name note, immutable `sub`): https://github.com/aws-actions/configure-aws-credentials
- `aws-actions/amazon-ecr-login` README (v2, registry output, `ecr:GetAuthorizationToken`): https://github.com/aws-actions/amazon-ecr-login
- AWS IAM User Guide, Create an OIDC identity provider: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
- AWS IAM User Guide, Create a role for OIDC federation: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html
- AWS IAM User Guide, Obtain the thumbprint for an OIDC provider: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
- AWS Security Blog, Use IAM roles to connect GitHub Actions to actions in AWS: https://aws.amazon.com/blogs/security/use-iam-roles-to-connect-github-actions-to-actions-in-aws/
- AWS ECS, ForceNewDeployment (same image/tag redeploys): https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-ecs-service-forcenewdeployment.html
- AWS CLI reference, `ecs update-service`: https://docs.aws.amazon.com/cli/v1/reference/ecs/update-service.html
