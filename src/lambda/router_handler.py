import os
import json
import boto3
import urllib.parse

# Initialize clients for Lambda routing and Glue job triggers
lambda_client = boto3.client('lambda')
glue_client = boto3.client('glue')

# Define our architectural thresholds (50MB in bytes)
SIZE_THRESHOLD_BYTES = 50 * 1024 * 1024 

def lambda_handler(event, context):
    print(f"Router received SQS Event: {json.dumps(event)}")
    
    for record in event.get('Records', []):
        sqs_body = json.loads(record['body'])
        if 'Records' not in sqs_body:
            continue
            
        for s3_record in sqs_body['Records']:
            bucket_name = s3_record['s3']['bucket']['name']
            file_key = urllib.parse.unquote_plus(s3_record['s3']['object']['key'])
            file_size = s3_record['s3']['object']['size']
            
            # Reconstruct the single event payload to forward down the line
            forward_payload = {"Records": [s3_record]}
            
            # Check route conditions: File size >= 50MB OR it's an XML file
            if file_size >= SIZE_THRESHOLD_BYTES or file_key.lower().endswith('.xml'):
                print(f"🚀 LARGE OR NESTED FILE DETECTED ({file_size} bytes). Routing to AWS Glue...")
                
                # Trigger the AWS Glue Spark Job asynchronously
                response = glue_client.start_job_run(
                    JobName='university-vitals-glue-spark-job',
                    Arguments={
                        '--s3_bucket': bucket_name,
                        '--s3_key': file_key
                    }
                )
                print(f"Glue Job triggered. RunID: {response['JobRunId']}")
                
            else:
                print(f"⚡ SMALL FILE DETECTED ({file_size} bytes). Routing to AWS Lambda...")
                
                # Invoke our cleansing Lambda function asynchronously (Event invocation type)
                lambda_client.invoke(
                    FunctionName='university-vitals-transformer-lambda',
                    InvocationType='Event',
                    Payload=json.dumps(forward_payload)
                )
                print("Transformer Lambda invoked successfully.")
                
    return {
        'statusCode': 200,
        'body': json.dumps("Files routed successfully based on size and format constraints.")
    }