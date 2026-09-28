## Policy Explanation

### S3UploaderOnly-lanluu

- **What it allow**: upload (PutObject) and download (GetObject) of objects in my-training-bucket-lanluu only. /\* means objects inside the bucket, not the bucket itself. Which mean Listing the bucket, listing all buckets, deleting objects, access to any other bucket, or any other AWS service are not allow.
- **Why it is scoped this way**: I scoped it this way to support Least privilege. If there is a credentials leak, the damage is limited to reading and writing objects in one training bucket.
