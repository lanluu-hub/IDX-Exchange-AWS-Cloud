# Lab 6 Runbook: PropertyLite ASG behind an ALB

**Goal:** `curl http://<alb-dns-name>/health` returns `{"status":"ok"}` and `/properties` returns listings, served by 2 instances in private subnets behind an ALB.

## Ground rules (each of these caused a block so far)

- **Check the VPC on every create screen.** The console defaults to the default VPC. Before every Create click, confirm VPC = `training-vpc`. Mixed VPCs break security group references and leave the ALB unable to reach targets. A resource can't be moved to another VPC later.
- **Region:** N. Virginia (us-east-1), top right.
- **Use `http://`, not `https://`.** The only listener is HTTP:80, so https hangs until it times out.
- **Private instances need the NAT gateway.** The user data downloads packages, so no NAT means the app never starts.
- **Cost:** NAT gateway, ALB, and instances bill hourly. Tear down at the end of each session.

## Phase 0: Network

Check VPC → Your VPCs for `training-vpc`. If it's missing, rebuild it with Lab 5.1:

- VPC → Create VPC → "VPC and more"
- Name tag: `training`, IPv4 CIDR `10.0.0.0/16`
- 2 AZs, 2 public subnets, 2 private subnets, NAT gateways "In 1 AZ"

**Write down:** the VPC ID, both public subnet IDs, both private subnet IDs.

**Catches**

- The private route table needs a `0.0.0.0/0` route to the NAT gateway, and the private subnets must be explicitly associated with it (check the Subnet associations tab, not just Routes).
- The NAT gateway must sit in a public subnet with an Elastic IP.

## Phase 1: Security groups

EC2 → Security Groups → Create. **VPC = `training-vpc` on each one.** Leave outbound at default. Create in this order, since `property-api-sg` references the other two.

| Name              | Inbound rule          | Source            |
| ----------------- | --------------------- | ----------------- |
| `property-alb-sg` | HTTP, port 80         | `0.0.0.0/0`       |
| `bastion-sg`      | SSH, port 22          | My IP             |
| `property-api-sg` | Custom TCP, port 8080 | `property-alb-sg` |
| `property-api-sg` | SSH, port 22          | `bastion-sg`      |

**Catches**

- If a security group doesn't show up in the Source dropdown, the two groups are in different VPCs. Pasting the `sg-xxxx` ID won't fix that. Recreate the wrong one.
- Copying Week 3's "8080 from My IP" onto the API group causes the 502 in Debug Lab 6.3. The source must be the ALB's security group.
- "My IP" is a snapshot. If SSH starts hanging later, compare `curl ifconfig.me` against the rule and update it.

## Phase 2: Bastion host

EC2 → Launch instance:

- Name `bastion`, Amazon Linux 2023, `t3.micro`, key pair `training-key`
- Network: VPC `training-vpc`, a **public** subnet, **auto-assign public IP = Enable**
- Security group: select existing `bastion-sg`

Test: `ssh -i ~/.ssh/training-key.pem ec2-user@<bastion-public-ip>`

**Catches**

- `UNPROTECTED PRIVATE KEY FILE`: run `chmod 400 ~/.ssh/training-key.pem`.
- Hang or timeout: stale My IP rule, no public IP assigned, or the subnet's route table has no route to the internet gateway.
- `Permission denied (publickey)`: wrong username (use `ec2-user`) or wrong key pair.

## Phase 3: Launch template

EC2 → Launch Templates → Create. Name `property-api-template`.

- AMI: Amazon Linux 2023, instance type `t3.micro`
- **Key pair: `training-key`** (needed to SSH in Phase 8; it can't be added to an instance after launch)
- Security group: `property-api-sg`
- Don't set a subnet (the ASG chooses). No public IP.
- Advanced details → User data: paste the script below

```bash
#!/bin/bash
yum update -y
yum install -y python3 python3-pip
pip3 install flask==3.0.3
mkdir -p /opt/property-api
cat > /opt/property-api/app.py << 'PYEOF'
import csv, os
from flask import Flask, jsonify, request
app = Flask(__name__)
DATA_PATH = os.environ.get("PROPERTY_DATA_PATH", "rets_property_sample.csv")
def load_properties():
    with open(DATA_PATH, newline="") as f:
        return list(csv.DictReader(f))
@app.route("/health")
def health():
    return jsonify(status="ok")
@app.route("/properties")
def list_properties():
    city = request.args.get("city")
    rows = load_properties()
    if city:
        rows = [r for r in rows if r.get("L_City", "").lower() == city.lower()]
    return jsonify(rows[:50])
@app.route("/properties/<listing_id>")
def get_property(listing_id):
    rows = load_properties()
    match = next((r for r in rows if r.get("L_ListingID") == listing_id), None)
    if not match:
        return jsonify(error="not found"), 404
    return jsonify(match)
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
PYEOF
cat > /opt/property-api/rets_property_sample.csv << 'CSVEOF'
L_ListingID,L_City,L_Keyword2,LM_Dec_3,LM_Int2_3,L_SystemPrice,L_Status
R100234,Sacramento,3,2.0,1450,450000,Active
R100235,Fresno,4,2.5,1900,395000,Active
R100236,Sacramento,2,1.0,900,299000,Pending
CSVEOF
cd /opt/property-api && nohup python3 app.py > /var/log/property-api.log 2>&1 &
```

**Catches**

- Week 3's script has a `# ... same app.py ...` placeholder. The script above has the real code. Leave nothing as a placeholder.
- Python indentation inside the heredoc must survive pasting. If the app crashes on start, check indentation first.
- Templates are versioned and immutable. Editing creates a new version, and only newly launched instances use it. To fix a running ASG: new version, point the ASG at it, then run an instance refresh.

## Phase 4: Target group

EC2 → Target Groups → Create.

- Target type: **Instances**, name `property-api-tg`
- Protocol HTTP, **port 8080**, VPC `training-vpc`
- Health check path: `/health`, success code 200
- Skip registering targets (the ASG does that). Create.

**Catches**

- Port is 8080, not 80. A wrong port makes every target unhealthy.
- The target group's VPC can't be changed after creation.

## Phase 5: Application Load Balancer

EC2 → Load Balancers → Create → Application Load Balancer.

- Name `property-alb`, scheme **Internet-facing**, IPv4
- VPC `training-vpc`, both AZs, **public** subnets only
- Security group: `property-alb-sg` (remove the default group that's pre-selected)
- Listener HTTP:80 → forward to `property-api-tg`
- Create, wait for State = Active (2 to 3 minutes), copy the DNS name

**Catches**

- Internal scheme or private subnets means the ALB is unreachable from the internet.
- Leaving the default security group attached next to yours is a common slip.

## Phase 6: Auto Scaling Group

EC2 → Auto Scaling Groups → Create.

- Name `property-api-asg`, launch template `property-api-template` (confirm the version that has the key pair)
- Network: VPC `training-vpc`, subnets = **both private subnets**
- Load balancing: attach to an existing load balancer target group → `property-api-tg`
- Health checks: **turn on Elastic Load Balancing health checks**, grace period **300 seconds**
- Group size: desired 2, min 1, max 4
- Scaling policy: target tracking, Average CPU utilization, target 50, instance warmup 120 to 300 seconds
- Create

**Catches**

- Without ELB health checks, the ASG only sees EC2 status and never replaces an instance whose app is dead.
- A short grace period makes the ASG kill instances before `yum update` finishes, creating a launch and terminate loop.
- Public subnets here would put instances outside the intended design. Use private.

## Phase 7: Verify

Wait 3 to 5 minutes, then check EC2 → Target Groups → `property-api-tg` → Targets: both should show **healthy**.

```bash
curl http://<alb-dns-name>/health
curl http://<alb-dns-name>/properties
```

Expected: `{"status":"ok"}` and the three listings.

## Phase 8: Lab 6.2, self-healing and scaling

**Self-healing:** EC2 → Instances → terminate one ASG instance. Watch the ASG's Activity tab. A replacement should launch within 1 to 2 minutes, and the ALB keeps answering from the other instance meanwhile.

**Scaling:**

1. Get the instance's private IP from EC2 → Instances.
2. `ssh -A -i ~/.ssh/training-key.pem ec2-user@<bastion-public-ip>`, then `ssh ec2-user@<instance-private-ip>`
3. `sudo dnf install -y stress-ng` then `stress-ng --cpu 2 --timeout 300`

**Catches**

- The handbook's `amazon-linux-extras` command is for Amazon Linux 2 and won't work on AL2023. The `stress-ng` route is my best understanding for AL2023 but is unverified. Check the AL2023 docs if it fails.
- The policy tracks the **average** CPU across the group. Stressing one of two instances gives roughly 50%, right at the target. Run the stress on **both** instances to trigger scale-out reliably.
- If `ssh` from the bastion says permission denied, run `ssh-add ~/.ssh/training-key.pem` on your laptop and reconnect with `-A`.
- Basic CloudWatch monitoring is 5-minute granularity, so allow several minutes before scale-out appears.

**Screenshots for the deliverable:** CloudWatch CPU graph showing the spike, and the ASG Activity tab showing the scale-out event. Note both timestamps.

## Phase 9: Teardown

Delete in this order, waiting for each to finish:

1. Auto Scaling Group (terminates its instances)
2. Application Load Balancer
3. Target group
4. Bastion and any stray instances (check Volumes for leftovers)
5. Launch template (optional, it's free)
6. Security groups: `property-api-sg`, `bastion-sg`, then `property-alb-sg`
7. NAT gateway, wait for "Deleted", then release its Elastic IP
8. VPC, only if you want a full reset

Verify: 0 instances, 0 load balancers, 0 NAT gateways, 0 Elastic IPs. Screenshot the Billing dashboard into the week folder.

## Troubleshooting quick table

| Symptom                                    | Likely cause                                                  | Fix                                                                     |
| ------------------------------------------ | ------------------------------------------------------------- | ----------------------------------------------------------------------- |
| curl hangs on `https://`                   | No 443 listener                                               | Use `http://`                                                           |
| curl hangs on `http://`                    | ALB internal, wrong subnets, or ALB SG missing port 80        | Check scheme, public subnets, `property-alb-sg`                         |
| 502 or 503                                 | Targets unhealthy or none registered                          | Targets tab; check `property-api-sg` allows 8080 from `property-alb-sg` |
| Targets stay unhealthy                     | App not booted, wrong port, or no NAT for package install     | Wait for grace period; port 8080; check private route to NAT            |
| SG missing from dropdown                   | Different VPCs                                                | Recreate in `training-vpc`                                              |
| SSH to bastion hangs                       | Stale My IP, no public IP, no IGW route                       | See Phase 2 catches                                                     |
| Can't SSH to ASG instance                  | No key pair in template, or no port 22 rule from `bastion-sg` | New template version with key, add rule, instance refresh               |
| Instances launch then terminate repeatedly | Grace period too short                                        | Set 300 seconds                                                         |
| Dead app never replaced                    | ASG health check type is EC2                                  | Enable ELB health checks                                                |

## Deliverable

`week-06/load-test-report.md` with the CloudWatch CPU screenshot, the scale-out event screenshot, and the timestamp gap between them. Commit and push.

**Confidence:** high on the architecture and gotchas, medium on exact console labels, which AWS changes often.
