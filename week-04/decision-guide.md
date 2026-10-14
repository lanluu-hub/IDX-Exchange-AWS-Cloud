# Week 4 Decision Guide: S3 / EBS / EFS / RDS / DynamoDB

| Service | Type | Use this when... | Avoid when... |
|---|---|---|---|
| **S3** | Object storage | You are storing files or blobs (images, exports, backups, static assets) that are read and written whole, by key, over HTTP. | You need a mounted filesystem, partial in-place edits, or queries over the contents. |
| **EBS** | Block storage (one instance, one AZ) | A single EC2 instance needs a fast, persistent disk, such as a boot volume or a self-managed database's data directory. | Several instances need the same files at once, or the data must survive losing the AZ. |
| **EFS** | Managed network file system (NFS) | Multiple instances or containers need to read and write the same files concurrently, across AZs. | Only one instance needs the disk (EBS is cheaper and faster), or the data is just objects (use S3). |
| **RDS** | Managed relational database (SQL) | Your data is relational and you need joins, transactions, constraints, or ad hoc SQL, such as the `rets_property` table and its `ROW_NUMBER()` queries. | Access is simple key lookups at very large scale, or the schema changes constantly. |
| **DynamoDB** | Managed NoSQL (key-value / document) | You know your access patterns up front and need predictable low-latency reads and writes by key, such as fetching a listing by `L_ListingID`. | You need joins, aggregations, or ad hoc queries across arbitrary columns. |

## Quick decision path

1. Is it a **file or blob**? Use **S3** by default. If it must behave like a disk, go to step 2.
2. Does it need to be a **disk**? One instance: **EBS**. Shared by many: **EFS**.
3. Is it **structured data you query**? Relational with joins and transactions: **RDS**. Key-based lookups at scale: **DynamoDB**.

## How this maps to the labs

- `rets_property` (cleaned, queried with SQL) lives in **RDS**.
- `Properties` (one item per listing, fetched by `L_ListingID`) lives in **DynamoDB**.
- The lifecycle-rule exercise used **S3** because the data was an object that aged out of frequent access.
- The EC2 instance's root volume is **EBS**. Nothing in these labs needed **EFS**, which only matters once multiple instances share files.
