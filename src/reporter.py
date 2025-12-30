import json
import boto3
import os
from datetime import datetime, timedelta

dynamodb = boto3.resource('dynamodb')
ses_client = boto3.client('ses')

TABLE_NAME = os.environ.get('TABLE_NAME')
SENDER_EMAIL = os.environ.get('SENDER_EMAIL')
RECIPIENT_EMAIL = os.environ.get('RECIPIENT_EMAIL')

def lambda_handler(event, context):
    try:
        table = dynamodb.Table(TABLE_NAME)
        
        
        response = table.scan()
        items = response.get('Items', [])
        
        total_records = len(items)
        report_date = datetime.utcnow().strftime('%Y-%m-%d')
        
        
        today_records = [
            i for i in items 
            if i.get('upload_timestamp', '').startswith(report_date)
        ]
        count_today = len(today_records)

        subject = f"Daily Data Processing Report - {report_date}"
        body_text = (
            f"Hello,\n\n"
            f"Here is your automated daily report:\n"
            f"-----------------------------------\n"
            f"Date: {report_date}\n"
            f"Total Records in Database: {total_records}\n"
            f"Records Processed Today: {count_today}\n"
            f"-----------------------------------\n"
            f"End of Report."
        )

        ses_client.send_email(
            Source=SENDER_EMAIL,
            Destination={
                'ToAddresses': [RECIPIENT_EMAIL]
            },
            Message={
                'Subject': {'Data': subject},
                'Body': {'Text': {'Data': body_text}}
            }
        )

        return {
            'statusCode': 200,
            'body': json.dumps('Report sent successfully')
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps('Error sending report')
        }