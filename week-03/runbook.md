# Deploy PropertyLite API on EC2

**Purpose:** Run the PropertyLite Flask API on a t3.micro instance and verify it from outside AWS.
**Last tested:** 2026-10-04
**Owner:** Lan

## Prerequisites

- AWS account with EC2 access
- Key pair stored at `~/.ssh/training-key.pem` (created in step 1)
- A laptop terminal with `ssh` and `curl`

## Procedure

### 1. Launch the instance

1. Console -> EC2 -> **Launch instance**. If prompted, click "Launch without a walkthrough".
2. **Name:** `property-api-01`.
3. **AMI:** Amazon Linux 2023 (Free Tier eligible). Confirm the AMI name starts with `al2023-ami`.
   _Why:_ the bootstrap script uses `yum` and the `ec2-user` account, which match Amazon Linux. The Ubuntu tile sits right next to it in Quick Start and is easy to click by mistake.
4. **Instance type:** `t3.micro`. Confirm the architecture is 64-bit (x86).
5. **Key pair:** Create new key pair -> name `training-key` -> type RSA -> format `.pem` -> Create. The file downloads once. Move it somewhere permanent, e.g. `~/.ssh/training-key.pem`.
6. **Network settings:** click Edit, then:
   - Auto-assign public IP: Enable.
   - Create security group, named `property-api-sg`.
   - SSH rule: port 22, source **My IP**.
   - Click **Add security group rule** -> Custom TCP -> port range `8080` -> source type Anywhere (`0.0.0.0/0`).

   _Why:_ SSH is limited to my IP so only I can log in. Port 8080 is open to everyone because API clients must be able to reach it. In a real deployment this would sit behind a load balancer.

7. **User data:** scroll to Advanced details -> User data and paste the script below. Line 1 must be exactly `#!/bin/bash` with no blank line or space above it. Leave "User data has already been base64 encoded" unchecked.

   _Why:_ cloud-init only runs a script if it starts with a shebang, and it only runs user data on first boot. If the paste is wrong, the instance still launches fine and silently skips the script. Fixing it later means rerunning the script by hand or relaunching.

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

**Note:** Python is whitespace-sensitive. Every function body in `app.py` must keep its indentation when pasted, and each `def` must start at column 0 directly under its decorator.

8. Click **Launch instance**. Wait 1 to 2 minutes for user data to finish.

**Verify:** the instance state is "running" and a public IPv4 is assigned.

### 2. Connect over SSH

Copy the public IPv4 from the console, then run on the laptop:

```bash
chmod 400 ~/.ssh/training-key.pem
ssh -i ~/.ssh/training-key.pem ec2-user@<public-ip>
```

_Why:_ SSH refuses a key file that other users can read, so `chmod 400` is required.

On the instance, check that cloud-init ran the script and that the app code is valid:

```bash
cloud-init status --long
python3 -m py_compile /opt/property-api/app.py
curl http://localhost:8080/health
```

Expected: `status: done`, no output from `py_compile` (no output means valid syntax), and `{"status":"ok"}`.

### 3. Verify from outside AWS

Run these in a normal laptop terminal, not the SSH session:

```bash
curl http://<public-ip>:8080/health
curl http://<public-ip>:8080/properties/R100234
```

Expected: `{"status":"ok"}`, then the Sacramento listing (R100234, 450000, Active).

_Why:_ the laptop curl travels through the internet and the security group, which is the path a real client takes. `curl localhost` on the instance skips the security group, so it can pass while the public path is broken.

### 4. EBS snapshot practice

1. Console -> EC2 -> Volumes -> select the root volume of `property-api-01` (match the Attached instance column; 8 GiB, `/dev/xvda`).
2. Actions -> **Create snapshot**. Add a description such as `property-api-01 root snapshot`.
3. EC2 -> Snapshots. Wait until the status reads "completed".

**Verify:** the snapshot appears in EC2 -> Snapshots with status "completed".

**What happens if I create a volume from it:** I get a new EBS volume that is a copy of the root disk as it was when the snapshot was taken, which I can attach to an instance, including one in a different Availability Zone.

Take the snapshot after the health check passes so it captures a working app.

## Troubleshooting

| Symptom                                                                                           | Diagnosis                                                                                                                                                                 | Fix                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `curl` from laptop times out                                                                      | Timeout (not "refused") usually means the security group is dropping packets. On the instance, `curl localhost:8080/health` separates app problems from network problems. | Check the Security tab for Custom TCP 8080 from `0.0.0.0/0` and that the instance uses `property-api-sg`. If "My IP" changed (new network), re-select it for the SSH rule. |
| `curl localhost:8080` says "Could not connect"                                                    | Nothing is listening on 8080, so the app never started.                                                                                                                   | Work through the rows below to find out why.                                                                                                                               |
| `/var/log/cloud-init-output.log` missing, `cat /etc/os-release` shows Ubuntu, cloud-init disabled | Wrong AMI selected at launch.                                                                                                                                             | Terminate and relaunch with the Amazon Linux tile. User data cannot be fixed in place.                                                                                     |
| Log ends after network info with no "user scripts" section and no pip output                      | cloud-init skipped the script: the User data field was empty, or line 1 was not exactly `#!/bin/bash`.                                                                    | Save the script on the instance as `setup.sh` and run `sudo bash setup.sh`, or relaunch with a correct paste.                                                              |
| `IndentationError: expected an indented block` in `property-api.log`                              | The pasted `app.py` lost its indentation, or a `def` was indented under its decorator.                                                                                    | Fix the indentation, then rerun `sudo bash setup.sh`. Check with `python3 -m py_compile /opt/property-api/app.py`.                                                         |
| `Permission denied` on `/var/log/property-api.log` when running the script by hand                | The `>` redirect runs as `ec2-user`, which cannot write to `/var/log`. User data runs as root, so this only happens by hand.                                              | Run the script with `sudo bash setup.sh`, or redirect to `~/property-api.log`.                                                                                             |

Note: the pip warning about running as root is harmless here.

Note: the app was started with `nohup`, so it does not survive a reboot. A systemd unit would fix that.

## Rollback / Cleanup

Terminating and deleting snapshots are irreversible.

1. EC2 -> Instances -> select `property-api-01` -> Instance state -> **Terminate (delete) instance**.
2. EC2 -> Volumes: confirm the root volume is deleted too.
3. EC2 -> Snapshots: delete the practice snapshot (snapshots are billed per GB stored).
4. EC2 -> Elastic IPs: release any you allocated.

The key pair and `property-api-sg` stay behind. They are harmless and can be reused.
