## Runbook: RDS MySQL + EC2 + DynamoDB (Labs 4.2 to 4.4)

Order matters. Most of the trouble in the first run came from doing steps out of sequence or from the wrong machine. Each "Gotcha" below is a mistake that cost time.

### Where each command runs

| Machine | What runs there |
|---|---|
| Local (WSL/Ubuntu) | `scp`, `ssh`, `chmod`. Nothing that talks to the database. |
| EC2 instance | `mysql`, `nc`, `aws dynamodb ...`, `yum` |

**Gotcha:** The RDS instance is private (not publicly accessible), so its endpoint resolves to a `172.31.x.x` address. A local machine cannot reach it ("No route to host" or error 115). All database commands run from EC2. Also, `yum` only exists on Amazon Linux. On local Ubuntu it is `apt`, and you do not need the MariaDB client locally at all.

### 1. Create the RDS instance (Lab 4.2, steps 37 to 42)

1. Console > RDS > Create database > Standard create > MySQL > engine 8.0.x (needed for `ROW_NUMBER()`).
2. Template: Free tier. Identifier: `training-db`. Master username: `admin`. Save the password in a password manager.
3. Connectivity: **Don't make it publicly accessible**, default VPC.
4. Create. Wait until status is **Available** (5 to 10 minutes). Do not connect before then.

Note the endpoint (`training-db.<id>.us-east-1.rds.amazonaws.com`) and the VPC security group ID (default group, `sg-...`).

### 2. Launch the EC2 instance

1. Amazon Linux 2023, `t3.micro` (free tier eligible), **default VPC** (same VPC as RDS).
2. Key pair: create or select one in `us-east-1`. Download the `.pem` once and keep it.
3. Network settings: create a new security group (call it `ec2-sg`) allowing SSH (22) from **My IP**. Auto-assign public IP: enabled.

**Gotcha:** EC2 must be in the same VPC as RDS. If your home IP changes, SSH starts timing out. Update the SSH rule's source.

### 3. Wire the security groups (do this BEFORE trying to connect)

1. RDS > `training-db` > Connectivity & security > click the VPC security group.
2. Edit inbound rules > Add rule: Type **MySQL/Aurora**, port 3306, Source **Custom = the EC2 instance's security group** (`ec2-sg`, select by name or `sg-` ID).
3. Save.

**Gotcha:** The source must be the EC2 security group, not "My IP". Traffic comes from EC2's private IP, so an IP rule will not match. A new RDS instance's default group only has a self-referencing rule, which blocks EC2 unless the instance happens to share that group. Symptom of a missing rule: `ERROR 2002 ... (115)` or a hang.

### 4. Copy the SQL file to EC2 (run locally)

```bash
chmod 400 ~/.ssh/training-key.pem
scp -i ~/.ssh/training-key.pem rets_property.sql ec2-user@<ec2-public-ip>:~
```

**Gotchas:**
- `-i` is required. Without it, `scp` treats the `.pem` as a file to upload and auth fails with `Permission denied (publickey...)`. It would also copy your private key to the server.
- Run it from the folder containing `rets_property.sql`, or use the full path.
- The post-quantum key exchange warning is harmless.

### 5. Connect, test, import (on EC2)

```bash
ssh -i ~/.ssh/training-key.pem ec2-user@<ec2-public-ip>

sudo yum install -y mariadb105
nc -zv <rds-endpoint> 3306          # expect: Succeeded
```

If `nc` is missing: `sudo yum install -y nmap-ncat`. If it does not say Succeeded, go back to step 3.

```bash
mysql -h <rds-endpoint> -u admin -p -e "CREATE DATABASE training_data;"
mysql -h <rds-endpoint> -u admin -p training_data < rets_property.sql
```

**Gotchas:**
- The import is slow on free tier (1 GB RAM, throttled IOPS). A large dump can take tens of minutes.
- Do not Ctrl+C partway. You would have to drop the tables and restart.
- If your SSH session drops, the import dies. For a big file, run it inside `tmux` (`sudo yum install -y tmux`).
- Check progress from a second session: `mysql -h <rds-endpoint> -u admin -p -e "SELECT COUNT(*) FROM training_data.rets_property;"`

Verify when done:

```sql
SHOW TABLES;
SELECT COUNT(*) FROM rets_property;
```

### 6. PII cleanup (Lab 4.2, step 10)

Open an interactive session first:

```bash
mysql -h <rds-endpoint> -u admin -p training_data
```

Then, at the `mysql>` prompt:

```sql
-- 1. Backup (DROP COLUMN is irreversible, and reimporting is slow)
CREATE TABLE rets_property_backup AS SELECT * FROM rets_property;

-- 2. Confirm exact column names
DESCRIBE rets_property;

-- 3. Run the ALTER TABLE ... DROP COLUMN statement from the lab
```

**Gotchas:**
- Pasting SQL into the bash prompt gives `ALTER: command not found`. The `mysql>` prompt must be open first.
- One misspelled or missing column makes the whole `ALTER` fail (error 1091) and changes nothing. Compare against `DESCRIBE` output.
- Drop the backup table when you are done confirming the cleanup, so PII does not linger: `DROP TABLE rets_property_backup;`

### 7. DynamoDB (Lab 4.3, on EC2 or local with credentials)

```bash
aws dynamodb create-table \
  --table-name Properties \
  --attribute-definitions AttributeName=L_ListingID,AttributeType=S \
  --key-schema AttributeName=L_ListingID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

1. Pull one real row from the cleaned `rets_property` table (real listing ID, not the `R100234` placeholder).
2. `put-item` with that row's values, then `get-item` with the same key. Success is `get-item` returning the item as JSON.

**Gotcha:** The AWS CLI needs credentials (an instance role on EC2, or `aws configure`) and the same region you created the table in.

### 8. Debug reference (Lab 4.4)

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR 2002 (115)` or hang from EC2 | No inbound 3306 rule referencing the EC2 security group | Step 3 |
| `nc: No route to host` from local machine | RDS is private, wrong machine | Run from EC2 |
| `yum: command not found` | Not on Amazon Linux | Run on EC2, or `apt install mariadb-client` locally |
| `Permission denied (publickey)` on scp/ssh | Missing `-i`, wrong key, or wrong user | `-i key.pem`, user `ec2-user` |
| `UNPROTECTED PRIVATE KEY FILE` | Key permissions too open | `chmod 400 key.pem` |
| SSH times out | EC2 SSH rule has an old IP | Update the rule to your current IP |
| `ALTER: command not found` | SQL pasted into bash | Open `mysql` first |
| `ERROR 1091` on `ALTER` | A column name does not exist | Check `DESCRIBE`, fix names |

### 9. Cleanup (order matters, and deletes are irreversible)

1. **RDS:** delete `training-db`. Decide on the final snapshot (snapshots cost money if kept). Wait for it to finish deleting.
2. **DynamoDB:** `aws dynamodb delete-table --table-name Properties`
3. **EC2:** terminate the instance. Release any Elastic IPs.
4. **Security groups:** delete `ec2-sg` and any leftover rules. A group cannot be deleted while another group's rule still references it, so remove the RDS rule that points at `ec2-sg` first.
5. **Key pair:** delete in EC2 > Key Pairs if you no longer need it. Keep the `.pem` only if you plan to reuse the pair.
6. Check Billing > Free Tier usage to confirm nothing is still running.
