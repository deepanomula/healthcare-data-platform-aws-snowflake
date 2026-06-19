import os
import json
import boto3
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

# Initialize AWS clients outside the handler to optimize for execution container warm-up
lambda_client = boto3.client('lambda')
glue_client = boto3.client('glue')
sqs_client = boto3.client('sqs')

SIZE_THRESHOLD_BYTES = 50 * 1024 * 1024 

def invoke_transformer_parallel(transformer_name, payload, receipt_handle):
    """
    Worker function executed inside separate concurrent threads to isolate 
    synchronous RequestResponse handshakes away from blocking main orchestration lines.
    """
    try:
        response = lambda_client.invoke(
            FunctionName=transformer_name,
            InvocationType='RequestResponse',
            Payload=json.dumps(payload)
        )
        response_payload = json.loads(response['Payload'].read().decode('utf-8'))
        
        if response.get('FunctionError') or response_payload.get('status') != 'success':
            return {"status": "failed", "handle": receipt_handle, "error": response_payload.get('error')}
            
        return {"status": "success", "handle": receipt_handle}
    except Exception as thread_err:
        return {"status": "failed", "handle": receipt_handle, "error": str(thread_err)}

def lambda_handler(event, context):
    print(f"Router received SQS Event Batch: {json.dumps(event)}")
    
    TRANSFORMER_NAME = os.environ.get("TRANSFORMER_LAMBDA_NAME")
    GLUE_JOB_NAME = os.environ.get("GLUE_JOB_NAME")
    SECRET_SALT = os.environ.get("SECRET_SALT")
    
    successful_receipt_handles = []
    lambda_tasks = [] # Collects concurrent futures threads
    
    for record in event.get('Records', []):
        receipt_handle = record['receiptHandle']
        sqs_body = json.loads(record['body'])
        
        if 'Records' not in sqs_body:
            continue
            
        for s3_record in sqs_body['Records']:
            bucket_name = s3_record['s3']['bucket']['name']
            file_key = urllib.parse.unquote_plus(s3_record['s3']['object']['key'])
            file_size = s3_record['s3']['object']['size']
            
            forward_payload = {"bucket": bucket_name, "key": file_key}
            
            # --- PATH A: LARGE OR XML FILES (Asynchronous Glue Spark Cluster) ---
            if file_size >= SIZE_THRESHOLD_BYTES or file_key.lower().endswith('.xml'):
                try:
                    print(f"🚀 LARGE/NESTED DATA CEILING BROKEN ({file_size} bytes). Directing to AWS Glue...")
                    response = glue_client.start_job_run(
                        JobName=GLUE_JOB_NAME,
                        Arguments={
                            '--s3_bucket': bucket_name,
                            '--s3_key': file_key,
                            '--secret_salt': SECRET_SALT
                        }
                    )
                    print(f"Glue execution run initialized asynchronously. RunId: {response['JobRunId']}")
                    successful_receipt_handles.append(receipt_handle)
                except Exception as glue_trigger_err:
                    print(f"❌ Failed allocating execution command to Glue Cluster: {str(glue_trigger_err)}")
                    
            # --- PATH B: SMALL FILES (Multi-Threaded Parallel Lambda Handshake) ---
            else:
                lambda_tasks.append((forward_payload, receipt_handle))

    # Execute all synchronous micro-batch tasks concurrently across a parallel worker thread pool
    if lambda_tasks:
        print(f"⚡ Spawning parallel execution thread array to process {len(lambda_tasks)} micro-batches...")
        with ThreadPoolExecutor(max_workers=10) as executor:
            future_to_handle = {
                executor.submit(invoke_transformer_parallel, TRANSFORMER_NAME, task[0], task[1]): task[1] 
                for task in lambda_tasks
            }
            
            for future in as_completed(future_to_handle):
                result = future.result()
                if result["status"] == "success":
                    print(f"Transformer successfully verified record allocation.")
                    successful_receipt_handles.append(result["handle"])
                else:
                    print(f"❌ Thread process reported downstream transformation failure: {result.get('error')}")
                    # By omitting from successful_receipt_handles, the message naturally rolls back into SQS FIFO

    # Batch purge only explicitly authenticated execution receipt tokens
    if successful_receipt_handles:
        queue_url = derive_queue_url_from_arn(event['Records'][0]['eventSourceARN'])
        print(f"Purging {len(successful_receipt_handles)} successfully transformed records permanently from SQS...")
        for handle in successful_receipt_handles:
            try:
                sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=handle)
            except Exception as delete_err:
                print(f"⚠️ SQS Acknowledgment deletion warning: {str(delete_err)}")
                
    return {'statusCode': 200, 'body': json.dumps("Ingestion routing execution sweep complete.")}

def derive_queue_url_from_arn(arn):
    parts = arn.split(':')
    return f"https://sqs.{parts[3]}.amazonaws.com/{parts[4]}/{parts[5]}"