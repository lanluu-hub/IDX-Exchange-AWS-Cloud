# AWS Cloud Engineer Journey

## Week 1 — Cloud Fundamentals & Account Setup

### Root Vs IAM

- IAM: a.k.a Identity and Access Management, a powerful tool for securely managing access to AWS resources. It grant shared access to AWS account. Allows granular permissions, help with assigns what actions different user can perform on different resources. IAM also provide several securities feature, such as MFA. IAM also intergrated AWS CloudTrail, providing detailed logging and identity information to support auditing and compliance requirements.

- Root: First acount being created when we first create AWS. A single sign-in Identity with complete access to all AWS services and resources in the account. The email and password used to create AWS account is root user credentials. Best practice is to setup MFA, delegate each responsibility/access to resources to suitable IAM role.

### Shared Responsibility Model

- Shared Responsibility Model help shared the Security and Compliance responsibility between AWS and Customer.
- AWS is responsible for protecting the infrastructure that runs all of the services offered in the AWS Cloud. Which include hardware, software, networking, and facilities that run AWS Cloud Services.
- Customer are responsible for "security inside the cloud." This determines the amount of configuration work the customer must perform as part of their security responsibilities.

> Lesson: env vars > --profile flag > config file, in that precedence order — always check env vars first when credentials “should” work but don't.

### Resources

- https://aws.amazon.com/types-of-cloud-computing/
- https://docs.aws.amazon.com/global-infrastructure/latest/regions/az-ids.html
- https://aws.amazon.com/compliance/shared-responsibility-model/
- https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_identity-management.html

---

## Week 2 — IAM & Security Foundations

### Concept

- **IAM Users**: A long‑lived identity in your AWS account, representing a person or application. Permissions is granted directly via policies or through group membership.

- **IAM Groups**: is a container for one or more IAM users, apply the same permissions to multiple users by attaching a policy to the group.

- **IAM Roles**: An AWS IAM role is a temporary login that gives permissions to AWS services, apps, or external users without using long-term passwords or keys. Controlled by rules for who can use it and what they can do, these roles last anywhere from 15 minutes to 12 hours. They keep your cloud environment secure by eliminating permanent credentials for everyday tasks like running EC2 instances, executing Lambda functions, or accessing other accounts.

- **Identity-based policy**: attaches directly to users, groups, or roles, following them around to define what actions they are allowed to perform across AWS.

- **Resource-based policy**: attaches directly to a specific resource (like an S3 bucket), defining who is allowed to access that specific item.

- **Managed Policies**: Reusable templates with standalone ARNs that can be attached to multiple identities.
  - **AWS Managed**: Created and maintained by AWS (read-only for you).

  - **Customer Managed**: Created by you, fully customizable, and support version control/rollback.

- **Inline Policies**: Written specifically for a single identity (one-to-one relationship). They cannot be shared and are automatically deleted if the parent user or role is deleted.

### Policy Explanation

#### S3UploaderOnly-lanluu

- **What it allow**: upload (PutObject) and download (GetObject) of objects in my-training-bucket-lanluu only. /\* means objects inside the bucket, not the bucket itself. Which mean Listing the bucket, listing all buckets, deleting objects, access to any other bucket, or any other AWS service are not allow.

- **Why it is scoped this way**: I scoped it this way to support Least privilege. If there is a credentials leak, the damage is limited to reading and writing objects in one training bucket.

### Resource:

- https://docs.aws.amazon.com/IAM/latest/UserGuide/id.html
- https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html
- https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started-reduce-permissions.html
- https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html

---

## Week 3 — Compute: EC2

### Concept

- AMIs: An Amazon Machine Image (AMI) is a special type of virtual appliance used to create a virtual machine within Amazon EC2. It serves as the basic unit of deployment for services delivered using EC2. An AMI provides the necessary information to launch an instance, including the operating system, application server, and applications. It also contains a block device mapping that specifies the volumes to attach to the instance when it’s launched.

- Instance types: T3.micro is designed for general‑purpose workloads with moderate CPU usage, such as:
  - Web applications and microservices

  - Development and test environments

  - Code repositories

  - Small databases

- Security groups: Managing access and ensuring security for resources in various environments, They act as virtual firewalls, controlling inbound and outbound traffic based on defined rules.

- NACLs: subnet-level security controls in AWS that allow or deny inbound and outbound traffic to manage network access. Unlike security groups, which operate at the instance level, NACLs apply rules to all resources within a subnet, providing an additional layer of security

- EBS volumes: provides persistent block storage for EC2 instances. Volumes behave like virtual hard drives and persist independently of instance lifecycle. They must be in the same Availability Zone as the instance to attach.

- User Data Bootstrapping: the process of passing a script or cloud‑init directives to a new EC2 instance at launch so it can automatically configure itself on first boot. Can be use to:
  - Install software (e.g., nginx, docker, nodejs)

  - Download and set up application code

  - Configure services, firewall rules, and environment variables
  - Register the instance with load balancers or monitoring tools

### Resource

- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIs.html
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/secondary-networks.html
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/storage_ebs.html
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html
