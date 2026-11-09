import json, boto3
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('Properties')

def to_json(value):
    # boto3 returns DynamoDB numbers as Decimal, which json.dumps can't handle.
    if isinstance(value, Decimal):
        return int(value) if value % 1 == 0 else float(value)
    raise TypeError(f"Not serializable: {type(value)}")

def lambda_handler(event, context):
    listing_id = event['pathParameters']['id']
    resp = table.get_item(Key={'L_ListingID': listing_id}).get("Item")
    
    if not resp:
        return {
            'statusCode': 404,
            'headers': {
                'Content-Type': 'application/json'
            },
            'body': json.dumps({'error': 'Property not found'})
        }
    
    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json'
        },
        'body': json.dumps(resp, default=to_json)
    }