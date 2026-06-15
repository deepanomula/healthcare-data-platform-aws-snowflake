import os
import json
import boto3
import hmac
import hashlib
import urllib.parse
import pandas as pd

# Initialize the S3 client
s3_client = boto3.client('client' if os.environ.get('AWS_SAM_LOCAL') else 's3')

def get_secret_salt():
    """
    Simulates fetching the cryptographic secret salt from AWS Secrets Manager.
    """
    return os.environ.get("SECRET_SALT", "TexasLonghorns2026!#CloudDataPlatform")

def compute_salted_hash(patient_id, salt):
    """
    Applies a deterministic SHA-256 hash combined with a secret salt.
    Ensures HIPAA compliance while preserving relational join integrity.
    """
    if pd.isna(patient_id) or str(patient_id).strip() == "":
        return None
    
    clean_id = str(patient_id).strip().upper()
    
    hashed = hmac.new(
        salt.encode('utf-8'),
        clean_id.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()
    
    return hashed

def lambda_handler(event, context):
    """
    Core Transformation Handler triggered DIRECTLY by router_handler.py.
    Processes a single filtered S3 file metadata block payload.
    """
    print(f"Received Direct Invocations from Router: {json.dumps(event)}")
    
    secret_salt = get_secret_salt()
    processed_files = []
    
    # The router wraps the payload inside a standard 'Records' list structure
    for s3_record in event.get('Records', []):
        bucket_name = s3_record['s3']['bucket']['name']
        file_key = urllib.parse.unquote_plus(s3_record['s3']['object']['key'])
        
        print(f"Processing micro-batch from Router: s3://{bucket_name}/{file_key}")
        
        # EXPECTED FILE FORMAT: vendor_A__vitals__20260614__uuid123.csv
        # 1. Extract metadata parameters from the S3 file naming convention
        try:
            filename = file_key.split('/')[-1]
            parts = filename.replace('.csv', '').split('__')
            
            vendor_id = parts[0]
            file_uuid = parts[3] if len(parts) > 3 else "UNKNOWN_UUID"
        except Exception as e:
            print(f"METADATA ERROR: Failed parsing file schema for {file_key}. Error: {str(e)}")
            continue

        # 2. Download the raw CSV file into memory using Pandas
        response = s3_client.get_object(Bucket=bucket_name, Key=file_key)
        df = pd.read_csv(response['Body'])
        
        # 3. DATA INTEGRITY: Drop rows missing critical identifiers
        df.dropna(subset=['patient_id', 'encounter_id'], inplace=True)
        
        if df.empty:
            print(f"WARNING: File {file_key} was empty after dropping null records.")
            continue

        # 4. DATA GOVERNANCE: Mask sensitive patient data using our salted hash function
        df['hashed_patient_id'] = df['patient_id'].apply(lambda x: compute_salted_hash(x, secret_salt))
        
        # Drop the cleartext patient_id column completely to satisfy compliance limits
        df.drop(columns=['patient_id'], inplace=True)

        # 5. Metadata Injection: Stamp lineage columns onto every row
        df['source_vendor'] = vendor_id
        df['lineage_file_uuid'] = file_uuid
        
        # 6. Convert cleansed data frame to compressed Parquet format in memory
        target_bucket = bucket_name.replace("-bronze", "-silver")
        target_key = f"silver-vitals/vendor={vendor_id}/{filename.replace('.csv', '.parquet')}"
        
        parquet_buffer = df.to_parquet(index=False, engine='pyarrow')
        
        # 7. Ship polished Parquet payload out to S3 Silver Tier
        s3_client.put_object(
            Bucket=target_bucket,
            Key=target_key,
            Body=parquet_buffer
            )
        
        print(f"SUCCESS: Transformed data safely stored to s3://{target_bucket}/{target_key}")
        processed_files.append(target_key)
            
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': f"Successfully processed {len(processed_files)} file(s) via Lambda.",
            'processed_files': processed_files
        })
    }