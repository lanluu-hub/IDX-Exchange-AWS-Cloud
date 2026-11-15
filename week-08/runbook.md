# Week 8 Runbook: Infrastructure as Code (Terraform VPC)

Goal: rebuild a Week 5-style VPC from code instead of clicking, then destroy it, then understand state and drift.

Assumes Windows with WSL2 + Ubuntu (run every command in the Ubuntu terminal, not PowerShell). Region: `us-east-1`.

## Mental model (read first)

Console clicking is like cooking from memory: you can't hand someone the exact meal. Terraform is the written recipe plus a notebook of what's currently on the table.

- **Config (`.tf` files):** the recipe, what you want.
- **State (`terraform.tfstate`):** the notebook, what Terraform believes exists, mapped to real AWS IDs.
- **`plan`:** compare recipe vs notebook vs reality, print the diff. Changes nothing.
- **`apply`:** execute that diff, then update the notebook.
- **`destroy`:** remove everything the notebook says Terraform created.
- **Drift:** reality no longer matches the notebook because someone changed it outside Terraform (usually you, in the console).

Cost warning: the NAT Gateway is not free (handbook figure: about $0.045/hr, plus the Elastic IP). Do the lab in one sitting and destroy it the same day.

---

## Step 0: Pre-flight checks

### 0a. Delete the Week 5 VPC if it still exists

AWS defaults to 5 VPCs per region. Check:

```bash
aws ec2 describe-vpcs --query "Vpcs[].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" --output table
```

You'll know it's fine when: you see only the default VPC (172.31.0.0/16), or at least fewer than 5 VPCs. Delete leftovers from Week 5 (NAT Gateway first, see Week 5 cleanup).

### 0b. Credentials work inside WSL

WSL has its own `~/.aws`; Windows credentials don't carry over.

```bash
aws --version
aws sts get-caller-identity
```

You'll know it worked when: you get your account JSON. If `aws` isn't found or credentials are missing, install the CLI in WSL and run `aws configure` again (Week 1, Lab 1.4). If it still fails, run `env | grep AWS` first (Debug Lab 1.5).

### 0c. Install Terraform

Don't use `apt install terraform` from Ubuntu's default repos (not available or very old). Use HashiCorp's repo:

```bash
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common curl
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
terraform -version
```

You'll know it worked when: `terraform -version` prints `Terraform v1.x.x`.

Mac note, since the handbook says `brew install terraform`: as far as I know, the default Homebrew formula is frozen on an old version after HashiCorp's license change. Use `brew tap hashicorp/tap && brew install hashicorp/tap/terraform`. I'm fairly sure of this but didn't verify it today.

---

## Step 1: Project folder and `.gitignore` (before anything else)

```bash
cd ~/aws-cloud-engineer-journey
mkdir week-08 && cd week-08
```

Create `.gitignore` **first**, so state never gets staged by accident:

```bash
cat > .gitignore <<'EOF'
.terraform/
*.tfstate
*.tfstate.*
crash.log
*.tfvars
EOF
```

Why: state files can contain secrets and real resource IDs. `.terraform/` is a huge provider download. You **do** commit `.terraform.lock.hcl` (created in Step 3), it pins provider versions.

---

## Step 2: Write the config

Three small files. Splitting them is a habit, not a requirement.

### `versions.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

The handbook doesn't include this file. I pinned the AWS provider to 5.x because the VPC module version used in the handbook (5.8.1) is from 2024, and an unpinned provider can pull a newer major version than the module was tested with. I haven't confirmed a specific breakage, so treat this as a safety measure, not a known bug fix.

### `main.tf`

```hcl
provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "training-vpc-tf"
  cidr = "10.1.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.1.1.0/24", "10.1.2.0/24"]
  private_subnets = ["10.1.101.0/24", "10.1.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Project = "aws-cloud-engineer-journey"
    Week    = "08"
  }
}
```

What each piece means:

| Line | Meaning |
|---|---|
| `module "vpc"` | Reusable package of ~20 resources written by the community, so you don't hand-write each route table |
| `cidr = 10.1.0.0/16` | The VPC's private IP range (65,536 addresses). Deliberately not `10.0.0.0/16` so it can't collide with your Week 5 VPC |
| `azs` + subnet lists | Subnets pair with AZs by position: first public subnet goes to `us-east-1a`, second to `us-east-1b` |
| `single_nat_gateway = true` | One NAT for the whole VPC (cheap). Production uses one per AZ for resilience |
| `tags` | Lets you find and cost-track everything from this lab |

### `outputs.tf`

```hcl
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}
```

Outputs are what Week 9 will reference (`module.vpc.public_subnets`) and give you quick IDs to check against the console.

---

## Step 3: `init`, `fmt`, `validate`

```bash
terraform init
terraform fmt
terraform validate
```

- `init` downloads the AWS provider and the VPC module into `.terraform/` and creates `.terraform.lock.hcl`.
- `fmt` rewrites files to standard formatting.
- `validate` checks syntax and references without touching AWS.

You'll know it worked when: `init` ends with "Terraform has been successfully initialized!" and `validate` prints "Success! The configuration is valid."

Common mistakes: running these in a folder with no `.tf` files · typo in the module `source` · no network (init needs the internet).

---

## Step 4: `plan` (the safety check)

```bash
terraform plan
```

Read the output. Don't skim it.

What to look for:

- Lines starting with `+` are creates. Expect roughly 20 resources: VPC, internet gateway, 2 public + 2 private subnets, route tables and associations, an Elastic IP, a NAT gateway, routes, and some default resources the module adopts. The exact count varies by module version.
- The summary line should read `Plan: N to add, 0 to change, 0 to destroy.`
- **Anything with `-` (destroy) or `-/+` (replace) on a first run is a red flag.** Stop and figure out why.
- Confirm the CIDR (`10.1.0.0/16`), the name tag, and `us-east-1a`/`us-east-1b`.

You'll know it worked when: you get a plan with only `+` and `0 to destroy`, and no errors.

Common mistakes: running `apply` without reading `plan` · `Error: No valid credential sources found` (fix credentials, Step 0b) · `Unsupported argument` after a typo in a module input name.

---

## Step 5: `apply`

```bash
terraform apply
```

Terraform reprints the plan and waits. Type `yes`. The NAT gateway makes this take a few minutes.

You'll know it worked when: you see `Apply complete! Resources: N added, 0 changed, 0 destroyed.` and your four outputs.

### Verify three ways

```bash
terraform output
terraform state list
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=training-vpc-tf" \
  --query "Vpcs[].[VpcId,CidrBlock]" --output table
```

Then open Console -> VPC -> **Your VPCs** and confirm `training-vpc-tf`. In the resource map you should see 2 public subnets, 2 private subnets and 1 NAT gateway.

Check: `terraform state list` shows entries like `module.vpc.aws_vpc.this[0]`. Those are the notebook entries, one per real resource.

Common mistakes: ctrl-C mid-apply (leaves partial resources, re-run `apply` to finish) · closing the terminal while the NAT is still creating.

---

## Step 6: Save progress before the drift lab

```bash
cd ~/aws-cloud-engineer-journey
git status
```

Confirm `terraform.tfstate` and `.terraform/` do **not** appear. If they do, stop and fix `.gitignore` before `git add`.

```bash
git add week-08
git commit -m "week 8: terraform vpc"
git push
```

---

## Step 7: Debug Lab 8.2, drift (safe version)

The handbook's example involves deleting resources, which is risky. This version teaches the same thing and is reversible.

1. In the console, open `training-vpc-tf` -> **Tags** -> add a manual tag `ManualEdit = true`.
2. Run:

```bash
terraform plan
```

3. Read it. Terraform sees a tag it didn't put there, and the plan wants to **remove it**: `~ update in-place`, `- "ManualEdit" = "true" -> null`. That's drift detected.
4. Choose how to resolve it:
   - **Let Terraform win:** `terraform apply` removes the manual tag.
   - **Make the console edit official:** add `ManualEdit = "true"` to `tags` in `main.tf`, then `plan` should show no changes.

Lesson: Terraform's notebook plus your recipe is the source of truth, not the console.

### What to do for the handbook's harder cases (read, don't run)

| Situation | Fix |
|---|---|
| Resource exists in AWS but Terraform lost track of it | `terraform import 'module.vpc.aws_vpc.this[0]' <vpc-id>` |
| Resource was deleted in AWS but state still lists it | `terraform state rm 'module.vpc.aws_vpc.this[0]'` (quote the address, the brackets confuse your shell) |
| `VpcLimitExceeded` | You have 5 VPCs in the region. Delete old ones (Step 0a) |
| Plan wants to recreate something that's fine | Compare `terraform state list` against the console, then import or `state rm` |

---

## Step 8: `destroy`

```bash
cd ~/aws-cloud-engineer-journey/week-08
terraform destroy
```

Read the plan (it should list only `-` lines, everything you created), type `yes`.

You'll know it worked when: you see `Destroy complete! Resources: N destroyed.`

Verify nothing is left costing money:

```bash
aws ec2 describe-nat-gateways --filter "Name=state,Values=available,pending" \
  --query "NatGateways[].NatGatewayId"
aws ec2 describe-addresses --query "Addresses[].[PublicIp,AllocationId]"
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=training-vpc-tf"
```

All three should come back empty (`[]`). A leftover Elastic IP that is allocated but not attached still bills.

Then take the Billing dashboard screenshot and save it as `week-08/billing-screenshot.png`.

Common mistakes: destroy hangs on a dependency (something you created by hand inside the VPC, such as an instance or ENI, blocks it, delete that and re-run) · forgetting you can rebuild any time with `terraform apply` (that's the point).

---

## Troubleshooting table

| Symptom | Likely cause | Fix |
|---|---|---|
| `terraform: command not found` | Not installed in WSL | Step 0c |
| `No valid credential sources found` | WSL has no AWS creds | `aws configure` in WSL, then `env | grep AWS` |
| `Module not installed` | Skipped init | `terraform init` |
| `Unsupported argument` | Typo in module input | Compare to the module docs for 5.8.1 |
| `VpcLimitExceeded` | 5 VPCs already | Step 0a |
| `AddressLimitExceeded` | Elastic IP quota (5 default) | Release unused EIPs |
| `Error acquiring the state lock` | A previous run crashed | Make sure nothing else is running, then `terraform force-unlock <ID>` |
| Plan wants to destroy things on a clean first run | Wrong folder or leftover state | Check `pwd`, check `terraform state list` |

---

## Deliverable: `week-08/README.md`

Write it in your own words, covering:

- What `plan`, `apply` and `destroy` each do (3 to 4 sentences)
- Why state matters: it maps config to real resource IDs, so Terraform knows what to create vs change vs delete. Lose it and Terraform can't manage existing resources. Commit it to git and it may leak secrets.
- What drift is, and what you saw in Step 7
- One sentence on why `.terraform.lock.hcl` is committed but `.terraform/` and `*.tfstate` are not

Checklist:

- [ ] `main.tf`, `versions.tf`, `outputs.tf`, `.gitignore`, `.terraform.lock.hcl`
- [ ] `README.md`
- [ ] Screenshot of `terraform apply` output and the VPC resource map
- [ ] Billing screenshot after destroy
- [ ] `git status` clean of state files, committed and pushed
