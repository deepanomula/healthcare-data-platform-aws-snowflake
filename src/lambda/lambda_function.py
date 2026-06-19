import os
import json
import boto3
import hmac
import hashlib
import csv
import io

s3_client = boto3.client('s3')
EXPECTED_COLUMNS = ["encounter_id", "patient_id", "enrollment_date", "gpa"]

def get_secret_salt():
    return os.environ.get("SECRET_SALT", "TexasLonghorns2026!#CloudDataPlatform")

def compute_salted_hash(patient_id, salt):
    if not patient_id or str(patient_id).strip() == "":
        return None
    clean_id = str(patient_id).strip().upper()
    return hmac.new(salt.encode('utf-8'), clean_id.encode('utf-8'), hashlib.sha256).hexdigest()

def lambda_handler(event, context):
    bucket_name = event.get('bucket')
    file_key = event.get('key')
    
    if not bucket_name or not file_key:
        return {'status': 'failed', 'error': 'Malformed event routing schema packet.'}
        
    secret_salt = get_secret_salt()
    
    try:
        filename = file_key.split('/')[-1]
        parts = filename.replace('.csv', '').split('__')
        vendor_id = parts[0]
        file_uuid = parts[3] if len(parts) > 3 else "UNKNOWN_UUID"
    except Exception as parse_meta_err:
        return {'status': 'failed', 'error': f"METADATA PARSE ERROR: {str(parse_meta_err)}"}

    try:
        response = s3_client.get_object(Bucket=bucket_name, Key=file_key)
        raw_data = response['Body'].read().decode('utf-8')
        
        input_stream = io.StringIO(raw_data)
        csv_reader = csv.DictReader(input_stream)
        
        incoming_headers = csv_reader.fieldnames if csv_reader.fieldnames else []
        if not all(col in incoming_headers for col in EXPECTED_COLUMNS):
            raise ValueError(f"SCHEMA VIOLATION: Expected {EXPECTED_COLUMNS}, but received {incoming_headers}")
        
        output_columns = ['encounter_id', 'hashed_patient_id', 'enrollment_date', 'gpa', 'source_vendor', 'lineage_file_uuid']
        output_stream = io.StringIO()
        csv_writer = csv.DictWriter(output_stream, fieldnames=output_columns)
        csv_writer.writeheader()
        
        row_count = 0
        written_rows = 0
        
        for row in csv_reader:
            row_count += 1
            patient_id = row.get('patient_id')
            encounter_id = row.get('encounter_id')
            
            # Row-level Data Quality Validation Check
            if not patient_id or not encounter_id or patient_id.strip() == "" or encounter_id.strip() == "":
                print(f"Skipping Row {row_count}: Critical primary identifier key missing.")
                continue
            
            hashed_patient = compute_salted_hash(patient_id, secret_salt)
            gpa = row.get('gpa', '').strip()
            if not gpa:
                gpa = "0.00"
                
            csv_writer.writerow({
                'encounter_id': encounter_id.strip(),
                'hashed_patient_id': hashed_patient,
                'enrollment_date': row.get('enrollment_date', '').strip(),
                'gpa': gpa,
                'source_vendor': vendor_id,
                'lineage_file_uuid': file_uuid
            })
            written_rows += 1
            
        if written_rows == 0:
            raise ValueError("Data Integrity Failure: File contains 0 valid rows after filtering anomalies.")
            
        # 💡 Flat target mapping layout—leveraging your rich file metadata structure!
        target_bucket = bucket_name.replace("-bronze", "-silver")
        target_key = f"silver-vitals/{filename.replace('.csv', '_clean.csv')}"
        
        s3_client.put_object(Bucket=target_bucket, Key=target_key, Body=output_stream.getvalue())
        return {'status': 'success', 'processed_file': target_key, 'records_mutated': written_rows}
        
    except Exception as run_err:
        print(f"TRANSFORMATION ENGINE CRASH: {str(run_err)}")
        return {'status': 'failed', 'error': str(run_err)}