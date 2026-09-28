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
