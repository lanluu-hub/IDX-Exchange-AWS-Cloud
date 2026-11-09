# Week 7 Runbook: Serverless PropertyLite (API Gateway, Lambda, DynamoDB, SQS)

Goal: re-host PropertyLite's `GET /properties/<id>` route with no always-on server, then practice SQS with a dead-letter queue.

Region for everything: `us-east-1`. Mixing regions is the number one reason "I created it but can't find it."

## Request path (use this in your README diagram)

```
curl / browser
      |
      v
API Gateway (HTTP API)   route: GET /properties/{id}
      |   (invokes, passes event with pathParameters.id)
      v
Lambda: get-property     (execution role: GetItem on Properties only)
      |
      v
DynamoDB: Properties     (key: L_ListingID)
```

Separate side lab: `producer (CLI) -> SQS property-queue -> (after 3 failed receives) -> property-dlq`

---

## Step 0: Setup shell variables

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo $ACCOUNT_ID
```

You'll know it worked when: `echo` prints a 12-digit number.

Common mistakes: running as the wrong profile (check `aws sts get-caller-identity`), or `unset`-ing env vars in one terminal and not another.

---

## Step 1: Recreate the DynamoDB table

Week 4 cleanup deleted `Properties`. Recreate it.

```bash
aws dynamodb create-table \
  --table-name Properties \
  --attribute-definitions AttributeName=L_ListingID,AttributeType=S \
  --key-schema AttributeName=L_ListingID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

aws dynamodb wait table-exists --table-name Properties
```

Load three rows. These are the synthetic sample rows from Week 0, so no PII and no need to touch the raw `rets_property.sql`.

```bash
aws dynamodb put-item --table-name Properties --item '{"L_ListingID":{"S":"R100234"},"L_City":{"S":"Sacramento"},"L_Keyword2":{"N":"3"},"LM_Dec_3":{"N":"2.0"},"LM_Int2_3":{"N":"1450"},"L_SystemPrice":{"N":"450000"},"L_Status":{"S":"Active"}}'

aws dynamodb put-item --table-name Properties --item '{"L_ListingID":{"S":"R100235"},"L_City":{"S":"Fresno"},"L_Keyword2":{"N":"4"},"LM_Dec_3":{"N":"2.5"},"LM_Int2_3":{"N":"1900"},"L_SystemPrice":{"N":"395000"},"L_Status":{"S":"Active"}}'

aws dynamodb put-item --table-name Properties --item '{"L_ListingID":{"S":"R100236"},"L_City":{"S":"Sacramento"},"L_Keyword2":{"N":"2"},"LM_Dec_3":{"N":"1.0"},"LM_Int2_3":{"N":"900"},"L_SystemPrice":{"N":"299000"},"L_Status":{"S":"Pending"}}'
```

Verify:

```bash
aws dynamodb get-item --table-name Properties --key '{"L_ListingID":{"S":"R100234"}}'
```

You'll know it worked when: you get JSON back with `"L_City": {"S": "Sacramento"}`. The `{"S": ...}` / `{"N": ...}` wrappers are DynamoDB type tags (S = string, N = number). Note numbers are sent as strings inside the tag. That is normal.

Common mistakes: forgetting `AttributeName` is case-sensitive (`L_ListingID`, not `l_listingid`) · running the table commands in a different region than the Lambda.

---

## Step 2: Create the Lambda function

1. Console search bar: **Lambda** -> **Create function**
2. **Author from scratch**
3. Function name: `get-property`
4. Runtime: **Python 3.12**
5. Architecture: leave default (x86_64)
6. Permissions: leave "Create a new role with basic Lambda permissions" selected. This role can write logs and nothing else. That's on purpose, you'll see why in Step 3.
7. **Create function**

In the **Code** tab, replace everything in `lambda_function.py` with this, then click **Deploy**:

```python
import json
import boto3
from decimal import Decimal

# Created outside the handler on purpose: this runs once per cold start,
# and warm invocations reuse it (faster).
table = boto3.resource("dynamodb").Table("Properties")


def to_json(value):
    # boto3 returns DynamoDB numbers as Decimal, which json.dumps can't handle.
    if isinstance(value, Decimal):
        return int(value) if value % 1 == 0 else float(value)
    raise TypeError(f"Not serializable: {type(value)}")


def lambda_handler(event, context):
    listing_id = event["pathParameters"]["id"]
    item = table.get_item(Key={"L_ListingID": listing_id}).get("Item")

    if not item:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "not found"}),
        }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(item, default=to_json),
    }
```

Why this differs from the handbook's snippet: the original does `json.dumps(resp.get('Item', {}))`. Your items contain numbers, so it crashes with `Object of type Decimal is not JSON serializable`. This version also returns 404 for a missing listing, which matches what `propertylite/app.py` does.

### Test it in the console (expect a failure first)

1. **Test** tab -> **Create new event**
2. Event name: `get-r100234`
3. Event JSON:

```json
{
  "pathParameters": { "id": "R100234" }
}
```

4. **Save** -> **Test**

Expected right now: **failure** with `AccessDeniedException ... not authorized to perform: dynamodb:GetItem`. Good. That proves least privilege is working. Fix it in Step 3.

Common mistakes: forgetting to click **Deploy** after pasting code (Test runs the old code) · indentation errors from pasting.

---

## Step 3: Give the Lambda read access to one table only

Find the role: Lambda -> `get-property` -> **Configuration** -> **Permissions** -> click the role name under **Execution role**. This opens IAM.

1. **Add permissions** -> **Create inline policy**
2. Switch to the **JSON** tab, paste (replace `<ACCOUNT_ID>` with your 12 digits):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/Properties"
    }
  ]
}
```

3. Next -> name it `PropertiesGetItemOnly` -> **Create policy**

Why only `GetItem`: the function only reads one item by key. No Scan, no Query, no writes, no other tables. If someone compromises this function, that's the blast radius.

Re-run the **Test** from Step 2.

You'll know it worked when: status is **Succeeded** and the response body shows the Sacramento listing with plain numbers (`"L_SystemPrice": 450000`).

Also test the not-found case: change the id to `R999999` and test. Expect `statusCode: 404`.

Common mistakes: typo in the table name in the ARN (`Property` vs `Properties`) · wrong account ID or region in the ARN · policy attached to the wrong role (each Lambda gets its own role).

---

## Step 4: Put API Gateway in front of it

Use an **HTTP API** (not REST API, not WebSocket). It's the cheaper, simpler one.

1. Console search: **API Gateway** -> **Create API** -> **HTTP API** -> **Build**
2. **Add integration** -> **Lambda**, region `us-east-1`, function `get-property`
3. API name: `property-api-http` -> **Next**
4. Routes: method `GET`, resource path `/properties/{id}`
   - The `{id}` is a path variable. It becomes `event["pathParameters"]["id"]` in your code. The name must match.
5. **Next** -> Stage: leave `$default` with **auto-deploy** on -> **Next** -> **Create**
6. Copy the **Invoke URL** from the API's overview page (looks like `https://abc123.execute-api.us-east-1.amazonaws.com`)

The handbook says "Deploy". With HTTP APIs and auto-deploy on, there is no separate deploy click. If you manually edit routes later and auto-deploy is off, you must deploy again.

Test:

```bash
export API_URL=https://<api-id>.execute-api.us-east-1.amazonaws.com

curl $API_URL/properties/R100234
curl -i $API_URL/properties/R999999
```

You'll know it worked when: the first call returns the listing JSON, the second returns HTTP 404 with `{"error": "not found"}`.

Compare with the EC2 version: `/properties/R100234` should return the same fields. One difference: the CSV version returns every value as a string, this one returns real numbers. Mention that in your write-up.

Common mistakes: route created as `/properties` without `{id}` (gives `KeyError: 'id'` in the logs) · calling the URL without the `/properties/...` path (API Gateway returns `{"message":"Not Found"}`, that's API Gateway, not your Lambda) · wrong HTTP method on the route.

---

## Step 5: SQS with a dead-letter queue

A DLQ is where a message goes after it has failed to be processed too many times, so a bad message doesn't loop forever.

### 5a. Create the DLQ and get its ARN

```bash
aws sqs create-queue --queue-name property-dlq

export DLQ_URL=$(aws sqs get-queue-url --queue-name property-dlq --query QueueUrl --output text)
export DLQ_ARN=$(aws sqs get-queue-attributes --queue-url $DLQ_URL \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)
echo $DLQ_ARN
```

You'll know it worked when: `echo` prints `arn:aws:sqs:us-east-1:<account>:property-dlq`.

### 5b. Create the main queue pointing at the DLQ

The redrive policy is JSON inside JSON, which breaks on shell quoting. Write it to a file instead:

```bash
cat > queue-attrs.json <<EOF
{
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}",
  "VisibilityTimeout": "5"
}
EOF

aws sqs create-queue --queue-name property-queue --attributes file://queue-attrs.json

export QUEUE_URL=$(aws sqs get-queue-url --queue-name property-queue --query QueueUrl --output text)
```

`VisibilityTimeout: 5` is set low just for this lab so you don't wait 30 seconds (the default) between attempts.

### 5c. Send and receive a message

```bash
aws sqs send-message --queue-url $QUEUE_URL --message-body '{"L_ListingID":"R100234"}'
aws sqs receive-message --queue-url $QUEUE_URL
```

You'll know it worked when: `receive-message` returns your JSON in `Body`.

I used `L_ListingID` instead of the handbook's `PropertyId: P1002` so the message matches your actual data model.

### 5d. Prove the DLQ works (optional but worth it)

Receiving a message does **not** delete it. It hides it for the visibility timeout, then it reappears. Each receive bumps its receive count. After 3, SQS moves it to the DLQ.

```bash
# you already received it once in 5c, so do a few more WITHOUT deleting
for i in 1 2 3 4; do
  sleep 6
  aws sqs receive-message --queue-url $QUEUE_URL --wait-time-seconds 2
done

# check the DLQ
aws sqs receive-message --queue-url $DLQ_URL
```

You'll know it worked when: the message shows up when you read from `property-dlq`. The move can take one extra poll, so if the DLQ is empty, run another receive on the main queue, wait a few seconds, then check the DLQ again.

Common mistakes: wrong `deadLetterTargetArn` (must be the ARN, not the URL) · using the main queue URL in the DLQ check · expecting the message to vanish after `receive-message` (you have to `delete-message` with the `ReceiptHandle` for that).

---

## Troubleshooting table

| Symptom | Where to look | Likely cause | Fix |
|---|---|---|---|
| `{"message":"Internal Server Error"}` from curl | Lambda -> Monitor -> View CloudWatch logs, newest log stream | Read the stack trace, don't guess | See next rows |
| `AccessDeniedException` in logs | Execution role | Policy missing, wrong table ARN, wrong region/account | Fix the inline policy (Step 3) |
| `KeyError: 'id'` | API Gateway routes | Route is `/properties` not `/properties/{id}` | Edit the route to `GET /properties/{id}` |
| `Decimal is not JSON serializable` | Lambda code | Using the handbook's original `json.dumps` | Use the `default=to_json` version from Step 2 |
| `ResourceNotFoundException` | Lambda code / region | Table name typo or table doesn't exist in this region | Check `aws dynamodb list-tables --region us-east-1` |
| `{"message":"Not Found"}` | API Gateway | URL path doesn't match any route | Check the route and the URL |
| Empty `{}` or 404 for a real id | DynamoDB | Row wasn't loaded (table was recreated empty) | Re-run the `put-item` commands |

Rule: with any Lambda error, read CloudWatch Logs first. The HTTP response alone almost never tells you the cause.

---

## Cleanup (the handbook omits this for Week 7, do it anyway)

Order matters a little: delete things that depend on others first.

```bash
# SQS
aws sqs delete-queue --queue-url $QUEUE_URL
aws sqs delete-queue --queue-url $DLQ_URL

# DynamoDB
aws dynamodb delete-table --table-name Properties
```

Console:

1. API Gateway -> `property-api-http` -> **Actions/Delete**
2. Lambda -> `get-property` -> **Actions** -> **Delete function**
3. CloudWatch -> Log groups -> delete `/aws/lambda/get-property`
4. IAM -> Roles -> delete the `get-property-role-xxxx` role (its inline policy goes with it)

Lambda, API Gateway, SQS and DynamoDB on-demand are near-free at lab volume, but clean up anyway so it becomes a habit. Then check the Billing dashboard and save the screenshot to `week-07/billing-screenshot.png`.

---

## Week 7 deliverable checklist

- [ ] `week-07/lambda_function.py` (the code from Step 2)
- [ ] curl collection: `week-07/curl-tests.sh` containing the three curls from Step 4 plus the SQS commands
- [ ] `week-07/README.md` with the request path diagram and 1 paragraph on why the role only has `GetItem` on one table
- [ ] Screenshot of a successful curl response
- [ ] Billing screenshot
- [ ] Commit + push, then tear down
