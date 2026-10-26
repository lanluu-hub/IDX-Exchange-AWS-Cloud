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

# Week 5 — Networking: VPC Deep Dive

## Overview

This lab explores Amazon Virtual Private Cloud (Amazon VPC) networking by building a custom VPC, configuring public and private subnets, and implementing secure access to a private EC2 instance through a bastion host.

The lab also investigates how route tables, an Internet Gateway (IGW), and a Network Address Translation (NAT) Gateway control network traffic within an AWS environment.

## Architecture

The environment uses the following configuration:

| Component          | Configuration                               |
| ------------------ | ------------------------------------------- |
| VPC                | `training-vpc`                              |
| IPv4 CIDR          | `10.0.0.0/16`                               |
| Availability Zones | 2                                           |
| Public subnets     | 2                                           |
| Private subnets    | 2                                           |
| Internet Gateway   | Attached to the VPC                         |
| NAT Gateway        | 1, deployed in a public subnet              |
| Bastion host       | `t3.micro` EC2 instance in a public subnet  |
| Private instance   | `t3.micro` EC2 instance in a private subnet |

The VPC uses public subnets for resources that require direct internet connectivity and private subnets for resources that should not accept direct inbound connections from the internet.

Refer to [`vpc-diagram.png`](./vpc-diagram.png) for the network architecture.

## Network Components

### VPC and CIDR Block

The VPC uses the IPv4 CIDR block `10.0.0.0/16`, providing a private address range for the lab environment.

The subnet CIDR blocks divide this address space into smaller networks across two Availability Zones. Each subnet must use a non-overlapping CIDR block contained within the VPC range.

### Public Subnets

Public subnets host resources that need direct internet connectivity, including the bastion host and the NAT Gateway.

Their route tables contain a default route:

- Destination: `0.0.0.0/0`
- Target: Internet Gateway

A subnet is not public merely because of its name. Its route table must provide a route to the Internet Gateway, and the resource must have the necessary public addressing and security configuration.

### Private Subnets

Private subnets host instances that should not be directly reachable from the public internet.

Their route tables contain a default route to the NAT Gateway for outbound IPv4 internet access. They do not have a default route directly to the Internet Gateway.

Private instances can initiate supported outbound connections through the NAT Gateway, but the NAT Gateway does not provide unsolicited inbound internet connectivity.

### Internet Gateway

The Internet Gateway connects the VPC to the internet. Public-subnet route tables use it as the target for the default internet route.

Internet connectivity also depends on the resource's public IP addressing, security group rules, network ACLs, and the remote endpoint.

### NAT Gateway

The NAT Gateway allows instances in private subnets to initiate outbound IPv4 connections without requiring public IPv4 addresses on those instances.

For this lab, one NAT Gateway is placed in a public subnet and associated with an Elastic IP address. The private-subnet route tables direct their default routes to this NAT Gateway.

Using one NAT Gateway reduces the number of NAT Gateways required for the exercise, but it introduces a single point of failure and can create cross-Availability-Zone traffic costs. NAT Gateways also incur charges, so they must be deleted during cleanup.

### Bastion Host

The bastion host is an EC2 instance deployed in a public subnet. It provides a controlled SSH entry point into the VPC.

Its security group allows inbound SSH (TCP port 22) only from my current public IP address. The private instance's security group allows SSH only from the bastion host's security group.

This arrangement avoids exposing the private instance directly to the internet.

## Traffic Flow: Laptop to Private Instance

The SSH connection follows these steps:

1. My laptop initiates an SSH connection to the bastion host's public IPv4 address.
2. The VPC's public-subnet route table directs internet-bound traffic through the Internet Gateway.
3. The bastion host's security group permits the connection because its source matches my public IP address.
4. After logging into the bastion host, I initiate a second SSH connection to the private instance's private IPv4 address.
5. Traffic between the bastion and the private instance remains within the VPC's private network.
6. The private instance's security group permits SSH because the traffic originates from the bastion host's security group.
7. After authentication, I receive a shell on the private instance without exposing it directly to the internet.

### SSH Agent Forwarding

Agent forwarding can be used to authenticate to the private instance without copying the private key onto the bastion host.

Example from my laptop:

```bash
ssh -A -i ~/.ssh/training-key.pem \
  ec2-user@<bastion-public-ip>
```

Then, from the bastion host:

```bash
ssh ec2-user@<private-instance-private-ip>
```

Agent forwarding should only be enabled when connecting to a trusted bastion host because a compromised host may be able to use the forwarded agent while the connection is active. The private key itself remains on my laptop.

## Private Instance Internet Access

The private instance uses the NAT Gateway for outbound internet access.

For example, when running:

```bash
sudo yum update -y
```

the instance initiates an outbound connection. Its private-subnet route table forwards traffic matching `0.0.0.0/0` to the NAT Gateway. The NAT Gateway translates the source address and sends the traffic through the Internet Gateway.

Return traffic is translated and routed back to the originating instance, provided the relevant routing and security rules allow it.

The NAT Gateway does not replace the bastion host. The bastion provides administrative SSH access, while the NAT Gateway provides outbound connectivity.

## Troubleshooting

### Private Instance Cannot Access the Internet

**Symptom:** Running `sudo yum update -y` hangs or eventually times out.

Check the following:

1. Confirm that the NAT Gateway is available and deployed in a public subnet.
2. Confirm that the NAT Gateway has an Elastic IP address.
3. Verify that the public-subnet route table contains `0.0.0.0/0` pointing to the Internet Gateway.
4. Verify that the private-subnet route table contains `0.0.0.0/0` pointing to the NAT Gateway.
5. Confirm that the private subnet is explicitly associated with the route table containing the NAT route.
6. Check the instance's security group, network ACLs, DNS configuration, and package repository connectivity if routing appears correct.

A common cause is a missing subnet association. Creating a route in a route table does not automatically apply that route to every subnet. Each subnet uses its explicitly associated route table or the VPC's main route table if no explicit association exists.

### SSH to the Private Instance Fails

Check that:

- The bastion host is reachable over SSH from my current public IP address.
- The private instance is running and has a valid private IPv4 address.
- The private instance's security group allows inbound TCP port 22 from the bastion host's security group.
- Both instances use compatible SSH usernames, keys, and authentication settings.
- The private instance's subnet routing and network ACLs permit the connection.

## Security Considerations

- Restrict bastion SSH access to my current public IP address instead of allowing `0.0.0.0/0`.
- Allow SSH to the private instance only from the bastion host's security group.
- Do not copy private SSH keys onto the bastion host.
- Use SSH agent forwarding only with trusted hosts.
- Avoid assigning public IP addresses to private instances unless there is a specific requirement.
- Review AWS charges before and after the lab.

## Cleanup

To avoid unnecessary charges:

1. Terminate both EC2 instances.
2. Delete the NAT Gateway and wait for deletion to complete.
3. Release the NAT Gateway's Elastic IP address if it is no longer needed and is not associated with another resource.
4. Delete `training-vpc` after its dependent resources have been removed.
5. Verify that no unused Elastic IP addresses or other billable resources remain.

A NAT Gateway incurs charges while provisioned, even when little or no traffic passes through it. EC2, storage, and public IPv4 resources may also incur charges depending on the account and current AWS pricing.

## Learning Outcomes

This lab demonstrates how to:

- Design a VPC using CIDR blocks and multiple Availability Zones.
- Distinguish public and private subnets based on routing.
- Configure Internet Gateway and NAT Gateway connectivity.
- Implement a bastion-host pattern for controlled administrative access.
- Troubleshoot routing and subnet-association problems.
- Apply least-privilege security group rules and clean up cloud resources responsibly.

## Evidence and Validation

After completing the lab, record the actual resource configuration and add screenshots or other evidence if required.

[ ] VPC resource map showing the public and private subnets.

[ ] Route tables and subnet associations verified.

[ ] SSH connection to the private instance through the bastion confirmed.

[ ] Private-instance outbound connectivity tested, if required.

[ ] Billable resources removed after the lab.

**Status:** This document describes the intended lab configuration. Update the validation checklist and any configuration details to reflect the resources actually deployed and tested.
