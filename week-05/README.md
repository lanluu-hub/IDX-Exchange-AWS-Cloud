# Week 5 — VPC Networking Deep Dive

## Overview

This lab demonstrates how to securely access an EC2 instance in a private subnet using a bastion host in a public subnet.

The objective is to understand how public and private subnet routing, SSH, and security groups work together to provide controlled access to private resources without exposing them directly to the internet.

## Traffic Path

The connection follows this path:

**Local Machine → Bastion Host → Private Instance**

### 1. Local Machine to Bastion Host

From my laptop, I initiate an SSH connection to the bastion host using its public IPv4 address.

- **Destination:** Bastion host's public IP address
- **Protocol:** SSH over TCP port 22
- **Network path:** Internet → Internet Gateway → Public subnet
- **Security:** The bastion host's security group allows SSH only from my public IP address.

The Internet Gateway provides connectivity between the VPC and the internet. The bastion host resides in a public subnet whose route table directs internet-bound traffic to the Internet Gateway.

### 2. Bastion Host to Private Instance

After successfully connecting to the bastion host, I initiate a second SSH connection to the private instance using its private IPv4 address.

- **Destination:** Private instance's private IP address
- **Protocol:** SSH over TCP port 22
- **Network path:** Bastion host → VPC internal routing → Private subnet
- **Security:** The private instance's security group allows SSH only from the bastion host's security group.

Because both instances are in the same VPC, the connection uses the VPC's local route. The private instance does not need a public IP address or direct inbound internet access.

### 3. SSH Authentication

SSH agent forwarding can be used to authenticate to the private instance without copying the private key to the bastion host.

From my laptop:

```bash
ssh -A -i ~/.ssh/training-key.pem \
  ec2-user@<bastion-public-ip>
```

From the bastion host:

```bash
ssh ec2-user@<private-instance-private-ip>
```

Agent forwarding should only be used with a trusted bastion host. The private key remains on my local machine, although the remote host may be able to use the forwarded agent while the connection is active.

## Network Security

The bastion host acts as a controlled entry point into the VPC.

The security group configuration follows the principle of least privilege:

- **Bastion host:** Allow inbound SSH only from my current public IP address.
- **Private instance:** Allow inbound SSH only from the bastion host's security group.
- **Private instance:** No direct inbound SSH access from the public internet.

This configuration reduces the private instance's exposure while still allowing administrative access through the bastion.

## Conclusion

This lab demonstrates how a bastion host provides controlled SSH access to a private EC2 instance. The first connection uses the bastion host's public IP address, while the second connection uses the private instance's private IP address and the VPC's internal routing.

By combining route tables and security group restrictions, private resources can remain inaccessible to direct inbound internet connections while still supporting authorized administrative access.
