# Week 8: Infrastructure as Code

Rebuilt a Week 5-style VPC in Terraform (`training-vpc-tf`, `10.1.0.0/16`, 2 public and 2 private subnets across `us-east-1a` and `us-east-1b`, one NAT gateway) using the `terraform-aws-modules/vpc/aws` module pinned to 5.8.1. The AWS provider is pinned to `~> 5.0` so the module and provider versions stay compatible.

## What plan, apply, and destroy do

- **`terraform plan`** compares three things: my `.tf` config (desired state), the state file (what Terraform thinks exists), and real AWS (via API reads). It prints the diff and changes nothing. It is the safety check, so I read every line and confirmed the summary said `0 to destroy` before going further.
- **`terraform apply`** runs that diff against AWS in dependency order (VPC, then subnets and gateways, then route tables and routes), then records the resulting resource IDs in state. My apply created `<N>` resources in about `<X>` minutes, most of that waiting on the NAT gateway.
- **`terraform destroy`** deletes everything tracked in state, in reverse dependency order. After it finished I checked with the CLI that no VPC, NAT gateway, or Elastic IP was left, since an unattached Elastic IP still bills.

## Why state matters

State is the mapping from my config (`module.vpc.aws_vpc.this[0]`) to the real resource (`vpc-0abc...`). Without it, Terraform can't tell whether a resource is new, changed, or should be deleted, so it would try to create duplicates or lose track of what it owns. It also caches attribute values so plans are fast.

Because state can hold secrets and real IDs, `*.tfstate` and `.terraform/` are in `.gitignore`. `.terraform.lock.hcl` is committed because it pins the provider version for reproducible runs. For a team, state would live in a remote backend (for example S3 with locking) so people don't overwrite each other.
