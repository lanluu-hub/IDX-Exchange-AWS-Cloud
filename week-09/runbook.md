# Week 9 Runbook: Containerize PropertyLite and Deploy to ECS Fargate

**Goal:** package the exact same `propertylite/app.py` into a Docker image, push it to ECR, and run it on ECS Fargate using Terraform. No console clicking for the infrastructure.

**Time:** about 2 hrs concepts, 4 to 6 hrs lab.
**Cost:** near zero if you tear down the same day. This runbook turns the NAT Gateway off (see Concept 9), so the only meter running is one small Fargate task.
**Environment:** Windows + WSL2 Ubuntu. Every command below runs inside the WSL terminal unless it says otherwise.

---

## Part A. Concepts (read before touching anything)

### 1. Container vs VM
A VM is a whole rented apartment: its own kitchen, plumbing, and front door (a full OS). A container is a hotel room: you share the building's plumbing (the host kernel), but your room is sealed off from the other rooms. Containers start in seconds and are tiny because they don't ship an OS kernel.

### 2. Image vs container
- **Image:** the frozen recipe plus ingredients. Read-only. Think of a class definition, or a zip file of "everything this app needs to run."
- **Container:** a running instance of an image. Think of an object instantiated from the class. You can run 10 containers from one image.

### 3. Layers
An image is a stack of layers, one per Dockerfile instruction (`FROM`, `COPY`, `RUN`...). Docker caches each layer. If a layer's input hasn't changed, Docker reuses it.

This is why the Dockerfile copies `requirements.txt` and runs `pip install` **before** copying `app.py`. Your code changes often, your dependencies rarely. Changing `app.py` only invalidates the layers after it, so rebuilds take seconds.

### 4. Dockerfile line by line
```dockerfile
FROM python:3.12-slim                  # start from a small official Python image
WORKDIR /app                           # cd into /app (created if missing); later paths are relative to it
COPY requirements.txt .                # copy one file from your machine into /app
RUN pip install --no-cache-dir -r requirements.txt   # runs at BUILD time, result is baked into a layer
COPY app.py rets_property_sample.csv . # copy the app and its data into /app
EXPOSE 8080                            # documentation only, does NOT open a port
CMD ["python3", "app.py"]              # what runs at CONTAINER START time
```
`RUN` happens once while building. `CMD` happens every time a container starts. `EXPOSE` is a note to humans; the real port opening happens with `-p` (locally) or the security group (on AWS).

### 5. Registry and ECR
A registry is a package store for images, like GitHub is for code. Docker Hub is the public one. **ECR (Elastic Container Registry)** is AWS's private one. ECS pulls your image from ECR.

An image reference looks like this:
```
<account-id>.dkr.ecr.us-east-1.amazonaws.com/property-api:latest
 \_______________ registry ______________/ \_ repo _/ \_tag_/
```
**Tags** are just labels. `latest` is a convention, not magic. It points at whatever you pushed last.

### 6. ECS: the four nouns
Get these four straight and the rest of the week is easy.

| Noun | What it is | Analogy |
|---|---|---|
| **Cluster** | A logical group that your tasks live in. Costs nothing by itself. | The restaurant building |
| **Task definition** | A versioned blueprint: which image, how much CPU/RAM, which ports, which role, where logs go. | The recipe card |
| **Task** | One running copy of a task definition (one or more containers). | One plate being cooked right now |
| **Service** | A manager that keeps N tasks running and replaces dead ones. | The head chef who says "always keep 1 plate on the pass" |

The service is the same self-healing idea as the Week 6 Auto Scaling Group, but for containers.

### 7. Fargate vs EC2 launch type
- **EC2 launch type:** ECS places containers on EC2 instances that you own, patch, and scale.
- **Fargate:** you hand AWS the container, AWS finds the compute. No servers to SSH into or patch. You pay per vCPU-second and GB-second while the task runs.

This week uses Fargate. Trade-off: you lose host-level control (no SSH) and pay a premium per unit of compute.

### 8. Two IAM roles that look alike
This trips up everyone, and it shows up on SAA-C03.

- **Task execution role:** used by **ECS itself** to set up your task: pull the image from ECR, write logs to CloudWatch. This week's Terraform creates it.
- **Task role:** used by **your application code** inside the container to call AWS (for example, reading DynamoDB in the Week 12 capstone). Not needed this week because PropertyLite only reads a CSV.

Rule of thumb: execution role = "the stagehand that sets up the stage," task role = "what the actor is allowed to touch."

### 9. Networking: `awsvpc` mode, public IPs, and the NAT Gateway
- In Fargate, every task gets its **own network interface (ENI)** inside your subnet, with its own private IP. That is `network_mode = "awsvpc"`. It means a task behaves like a tiny EC2 instance for networking purposes, so **security groups apply directly to the task**.
- The task has to reach ECR to pull its image. Two ways: a private subnet with a NAT Gateway (about $0.045/hr, plus data), or a public subnet with `assign_public_ip = true`.
- This week we use the cheap way: public subnets and a public IP. **No NAT Gateway.** The capstone (Week 12) goes back to private subnets plus ALB, where NAT matters again.

### 10. The security group trap (this will bite you)
If you don't attach a security group, ECS uses the VPC's **default** security group. That group only allows inbound traffic from other members of itself. Your `curl` from your laptop will hang forever even though the task is healthy. The runbook creates an explicit security group allowing port 8080. This is the same lesson as Debug Lab 6.3: a network peer needs an explicit inbound rule.

### 11. Logs
A container's stdout/stderr disappears unless you ship it somewhere. The `awslogs` log driver sends it to a **CloudWatch log group**. When a task crashes, the logs plus the "stopped reason" are how you find out why.

### 12. Terraform ordering for this lab
Terraform builds ECS, but the image has to already exist in ECR, otherwise the task starts, can't find the image, fails, and loops. So the order is always:

1. Create ECR repo (CLI)
2. Build and push image
3. `terraform apply`

### Self-check (answer these out loud before Step 1)
1. If you change one line in `app.py`, which Dockerfile layers get rebuilt and why?
2. What is the difference between the task execution role and the task role?
3. Why would `curl http://<task-ip>:8080/health` time out even though the task is `RUNNING`?
4. What does an ECS service do that a bare task doesn't?

---

## Part B. Before you start

### Prerequisite checklist
- [ ] Week 0 done: `propertylite/` folder with `app.py`, `requirements.txt`, `rets_property_sample.csv`, committed.
- [ ] `aws sts get-caller-identity` returns your IAM admin user (not root).
- [ ] `terraform -version` works in WSL.
- [ ] **Docker installed.** The handbook never installs it. Do this now:
  1. Install **Docker Desktop for Windows** from docker.com.
  2. Open Docker Desktop, Settings, General, make sure **Use the WSL 2 based engine** is checked.
  3. Settings, Resources, WSL Integration, enable your Ubuntu distro, Apply & Restart.
  4. In the WSL terminal: `docker --version` and `docker run --rm hello-world`.

**You'll know it worked when:** `hello-world` prints "Hello from Docker!"

**Common mistakes:**
- Docker Desktop installed but not running (whale icon must be steady, not animating).
- WSL integration not enabled, so `docker: command not found` inside Ubuntu.
- Keeping your repo under `/mnt/c/...`. It works but builds are slow. Keep it in your Linux home (`~/aws-cloud-engineer-journey`).

### Set variables you'll reuse (run once per terminal session)
```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_URI=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
echo $ECR_URI
```
**You'll know it worked when:** `echo` prints something like `123456789012.dkr.ecr.us-east-1.amazonaws.com`. If the account ID part is blank, your CLI credentials are broken (see Debug Lab 1.5 in the handbook).

Env vars die when you close the terminal. If a later command says the URI is empty, re-run this block.

---

## Part C. The lab

### Step 1. Write the Dockerfile
```bash
cd ~/aws-cloud-engineer-journey/propertylite
```
Create `Dockerfile` (no extension) with the content from Concept 4, without my comments if you prefer:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py rets_property_sample.csv .
EXPOSE 8080
CMD ["python3", "app.py"]
```
Also create `.dockerignore` so junk doesn't get sent to the build:
```
__pycache__/
*.pyc
.git
.venv
.env
```

**Common mistakes:** naming it `Dockerfile.txt` (Windows editors love this), or a typo in the CSV filename in the `COPY` line.

---

### Step 2. Build and test locally (never push untested images)
```bash
docker build -t property-api .
docker images property-api
docker run --rm -p 8080:8080 property-api
```
In a **second terminal**:
```bash
curl http://localhost:8080/health
curl http://localhost:8080/properties/R100234
```
Stop the container with `Ctrl+C` in the first terminal.

What `-p 8080:8080` means: `host-port:container-port`. Traffic to port 8080 on your laptop is forwarded into port 8080 in the container.

**You'll know it worked when:** `/health` returns `{"status":"ok"}` and the property lookup returns the Sacramento listing, the same output as Week 0 but now from inside a container.

**Common mistakes:**
- Forgetting `-p`, so the app runs but your laptop can't reach it.
- Flask bound to `127.0.0.1` inside the container (unreachable from outside). The handbook's `app.py` already uses `host="0.0.0.0"`, so leave it alone.
- `port is already allocated`: something else (your Week 0 `python3 app.py`) is still using 8080. Stop it.

If this step fails, **stop and fix it here**. Debugging a broken image on AWS is 10x slower.

---

### Step 3. Create the ECR repository and push the image
```bash
aws ecr create-repository --repository-name property-api --region $AWS_REGION
```
Log Docker in to ECR (this token lasts 12 hours):
```bash
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URI
```
Tag and push:
```bash
docker tag property-api:latest $ECR_URI/property-api:latest
docker push $ECR_URI/property-api:latest
```
Verify:
```bash
aws ecr describe-images --repository-name property-api --region $AWS_REGION
```
**You'll know it worked when:** `docker login` prints `Login Succeeded` and `describe-images` lists one image tagged `latest`.

**Common mistakes:**
- The handbook's `docker tag` line wraps across two lines in the PDF and shows `propertyapi` (no hyphen). The repo is **`property-api`**. Use the commands above.
- Pushing before `docker login`, or after the 12-hour token expired: `no basic auth credentials`. Re-run the login.
- `tag` and `push` URIs that don't match exactly. If push says `repository does not exist`, compare the repo name character by character.
- Pasting `<account-id>` literally. The `$ECR_URI` variable avoids this.

---

### Step 4. Write the Terraform
```bash
mkdir -p ~/aws-cloud-engineer-journey/week-09 && cd ~/aws-cloud-engineer-journey/week-09
```
First, `.gitignore` (do this before your first `terraform init`):
```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
```

Create `main.tf`. This is the handbook's code with four fixes, explained under the file.

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Looks up the ECR repo you created in Step 3, so you never paste an account ID.
data "aws_ecr_repository" "property_api" {
  name = "property-api"
}

# ---------- Network (public subnets only, no NAT, see Concept 9) ----------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name            = "training-vpc-w9"
  cidr            = "10.2.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.2.1.0/24", "10.2.2.0/24"]
  enable_nat_gateway = false
}

# ---------- Security group (see Concept 10) ----------
resource "aws_security_group" "property_api" {
  name        = "property-api-sg"
  description = "Allow PropertyLite traffic on 8080"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "PropertyLite from anywhere (training only)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound (needed to pull the image from ECR)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- Logs (see Concept 11) ----------
resource "aws_cloudwatch_log_group" "property_api" {
  name              = "/ecs/property-api"
  retention_in_days = 7
}

# ---------- ECS ----------
resource "aws_ecs_cluster" "training" {
  name = "training-cluster"
}

resource "aws_iam_role" "ecs_execution" {
  name = "ecs-task-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "property_api" {
  family                   = "property-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([{
    name      = "property-api"
    image     = "${data.aws_ecr_repository.property_api.repository_url}:latest"
    essential = true
    portMappings = [{ containerPort = 8080, hostPort = 8080 }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.property_api.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "property_api" {
  name            = "property-api-service"
  cluster         = aws_ecs_cluster.training.id
  task_definition = aws_ecs_task_definition.property_api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.public_subnets
    security_groups  = [aws_security_group.property_api.id]
    assign_public_ip = true
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_execution]
}
```

**What changed from the handbook and why:**
1. **Security group added.** The handbook version has none, so the task falls back to the default SG and your curl would time out (Concept 10).
2. **Log group and `logConfiguration` added.** Without them there are no container logs, and the debug lab tells you to read them.
3. **ECR image URL comes from a data source** instead of a pasted `<account-id>`.
4. **NAT Gateway off, private subnets removed.** Saves money; not needed with public IPs. This is a deliberate difference from the Week 5/8 VPC.

**Common mistakes:**
- Forgetting `.gitignore` before `terraform init`, then committing `.terraform/` (hundreds of MB) to GitHub.
- Running this while the Week 8 VPC still exists. They use different CIDRs (`10.1` vs `10.2`), so it won't clash, but destroy Week 8 anyway.
- Indentation is not important in HCL, but a missing `}` is. If `terraform validate` complains, read the line number it gives.

---

### Step 5. Plan and apply
```bash
terraform init
terraform validate
terraform plan
```
Read the plan. You should see roughly 14 to 16 resources to add (VPC pieces, SG, log group, cluster, role, attachment, task definition, service). Nothing should say "destroy."

```bash
terraform apply
```
Type `yes` when prompted.

**You'll know it worked when:** you see `Apply complete! Resources: N added, 0 changed, 0 destroyed.`

---

### Step 6. Verify the service is running
Wait for the service to stabilize (usually 1 to 2 minutes):
```bash
aws ecs wait services-stable --cluster training-cluster --services property-api-service --region $AWS_REGION
aws ecs describe-services --cluster training-cluster --services property-api-service \
  --query "services[0].{running:runningCount,desired:desiredCount}" --region $AWS_REGION
```
Expect `running: 1, desired: 1`.

Now find the task's public IP. Fargate has no fixed address, so you trace it: task, to network interface, to public IP.
```bash
TASK_ARN=$(aws ecs list-tasks --cluster training-cluster --query "taskArns[0]" --output text --region $AWS_REGION)

ENI_ID=$(aws ecs describe-tasks --cluster training-cluster --tasks $TASK_ARN \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
  --output text --region $AWS_REGION)

PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID \
  --query "NetworkInterfaces[0].Association.PublicIp" --output text --region $AWS_REGION)

echo $PUBLIC_IP
curl http://$PUBLIC_IP:8080/health
curl http://$PUBLIC_IP:8080/properties/R100234
```
**You'll know it worked when:** `/health` returns `{"status":"ok"}` and the property lookup returns the Sacramento listing. Take your screenshot of the running task plus these curl outputs now (deliverable).

**Common mistakes:**
- `$PUBLIC_IP` prints `None`: the task isn't fully running yet, or `assign_public_ip` is false. Wait 30 seconds and re-run the three lookups.
- Curl hangs: security group problem. Check the task's SG in the console (ECS, cluster, service, Tasks, click task, Networking tab) and confirm port 8080 is allowed.
- The IP **changes every time the task restarts.** That is normal. An ALB (Week 12) gives you a stable address.

---

### Step 7. Read the logs (practice this now, you'll need it when things break)
```bash
aws logs tail /ecs/property-api --since 15m --region $AWS_REGION
```
You should see Flask's startup lines and a line for each of your curl requests.

Also look in the console: ECS, Clusters, training-cluster, property-api-service, Tasks, click the task, **Logs** tab.

**You'll know it worked when:** you can see your own `GET /health` requests in the output.

---

### Step 8. Capture the task definition JSON (deliverable)
```bash
cd ~/aws-cloud-engineer-journey/week-09
aws ecs describe-task-definition --task-definition property-api \
  --query taskDefinition --region $AWS_REGION > task-definition.json
cp ../propertylite/Dockerfile ./Dockerfile
```
Open `task-definition.json` and be able to point at: the image URI, `cpu`/`memory`, `networkMode`, `executionRoleArn`, and the `logConfiguration`.

---

## Part D. Debug lab: task won't stay running

**Symptom:** the service shows `0/1 running` and the task keeps starting and stopping.

**Diagnose in this order (always, never guess):**
1. **Stopped reason.** Console: ECS, Clusters, your cluster, **Tasks** tab, filter **Stopped**, click a task, read **Stopped reason**. Or CLI:
   ```bash
   aws ecs list-tasks --cluster training-cluster --desired-status STOPPED --region $AWS_REGION
   aws ecs describe-tasks --cluster training-cluster --tasks <task-arn> \
     --query "tasks[0].{reason:stoppedReason,containers:containers[0].reason}" --region $AWS_REGION
   ```
2. **Container logs** (Step 7).
3. Match the message:

| Message you see | Likely cause | Fix |
|---|---|---|
| `CannotPullContainerError ... not found` or `manifest unknown` | Image/tag isn't in ECR, or wrong repo name | `aws ecr describe-images`, re-push, check the image string in the task definition |
| `CannotPullContainerError ... i/o timeout` | Task has no route to the internet/ECR | Confirm `assign_public_ip = true`, public subnets, and the SG egress rule |
| `CannotPullContainerError ... AccessDenied` or `unable to retrieve ecr token` | Execution role missing ECR permissions | Confirm `AmazonECSTaskExecutionRolePolicy` is attached |
| `exec format error` in logs | Image built for the wrong CPU architecture (common if you build on an ARM machine like an Apple Silicon Mac) | Rebuild with `docker build --platform linux/amd64 -t property-api .` and re-push. Your Intel Acer should not hit this. |
| Task is `RUNNING` but curl times out | Security group missing port 8080 inbound | Add the ingress rule (Concept 10) |
| Container exits with `Error` / Python traceback in logs | App crashed (missing file, bad import) | Re-run `docker run` locally, fix, rebuild, push, redeploy |
| `ResourceInitializationError ... failed to validate logger args` | Log group doesn't exist | Make sure the log group resource is in Terraform and applied before the task |

**After you fix and re-push the image**, tell ECS to pull it:
```bash
aws ecs update-service --cluster training-cluster --service property-api-service \
  --force-new-deployment --region $AWS_REGION
```
(`:latest` doesn't auto-refresh. This is the same command your Week 10 pipeline will run.)

**Lesson:** "task failed" is never the answer. Stopped reason plus container logs always tell you which failure it is.

---

## Part E. Cleanup (non-negotiable)

```bash
cd ~/aws-cloud-engineer-journey/week-09
terraform destroy
```
Type `yes`. Then delete the ECR repo (Terraform doesn't own it because you created it by CLI):
```bash
aws ecr delete-repository --repository-name property-api --force --region $AWS_REGION
```
Verify nothing is left:
```bash
aws ecs list-clusters --region $AWS_REGION
aws ecr describe-repositories --region $AWS_REGION
```
Then check the Billing dashboard. **You'll know it worked when:** `Destroy complete!`, no clusters listed, ECR has no `property-api` repo, and Billing shows $0.00 to $1.00.

If you plan to start Week 10 right away, you can leave things up, but you must destroy before the week ends. Week 10's pipeline needs the cluster, service, and repo to exist, so rebuilding is just: create ECR repo, push image, `terraform apply`.

---

## Part F. Deliverable checklist (`week-09/`)
- [ ] `Dockerfile`
- [ ] `task-definition.json` (from Step 8)
- [ ] Screenshot: ECS task in `RUNNING` state
- [ ] Screenshot: live `curl` response from the task's public IP
- [ ] `main.tf` and `.gitignore` (no `.terraform/`, no state file)
- [ ] `billing-screenshot.png` after teardown
- [ ] Short README in your own words answering the four self-check questions

```bash
cd ~/aws-cloud-engineer-journey
git add week-09 propertylite/Dockerfile propertylite/.dockerignore
git status          # confirm .terraform/ and tfstate are NOT listed
git commit -m "week 9: containerize PropertyLite and deploy to ECS Fargate"
git push
```

---

## TLDR
Build image, test with `docker run`, push to ECR, `terraform apply` (cluster, task definition, service, security group, log group), find the task's public IP, curl `/health`, read logs, save task definition JSON, `terraform destroy`, delete ECR repo. The three things most likely to break: no security group on 8080, image not pushed before apply, and execution role missing its policy.

## Next step
Before Week 10, do this experiment: change the `/health` route in `app.py` to return a `version` field, rebuild, push, and run the `update-service --force-new-deployment` command by hand. Watch the old task drain and the new one start. Week 10 automates exactly that sequence with GitHub Actions.
