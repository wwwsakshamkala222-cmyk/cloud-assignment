import json
import boto3
import os
import uuid
from datetime import datetime


s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

TABLE_NAME = os.environ.get('TABLE_NAME')

def lambda_handler(event, context):
    try:
        record = event['Records'][0]
        bucket_name = record['s3']['bucket']['name']
        file_key = record['s3']['object']['key']
        
        print(f"Processing file: {file_key} from bucket: {bucket_name}")

        response = s3_client.get_object(Bucket=bucket_name, Key=file_key)
        file_content = response['Body'].read().decode('utf-8')
        
        
        lines = file_content.splitlines()
        table = dynamodb.Table(TABLE_NAME)
        
        item_count = 0
        
        for line in lines:
            if not line.strip():
                continue
                
            parts = line.split(',')
            
            entry_id = str(uuid.uuid4())
            
            item = {
                'id': entry_id,
                'raw_data': line,
                'source_file': file_key,
                'upload_timestamp': datetime.utcnow().isoformat()
            }
            
            table.put_item(Item=item)
            item_count += 1

        return {
            'statusCode': 200,
            'body': json.dumps(f'Successfully processed {item_count} records.')
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps('Error processing file')
        }