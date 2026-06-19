import sys
import urllib.parse
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, regexp_extract, lit, sha2, concat

# Resolve variables passed seamlessly from our parallel Router configuration script
args = getResolvedOptions(sys.argv, ['JOB_NAME', 's3_bucket', 's3_key', 'secret_salt'])

glueContext = GlueContext(SparkContext.getOrCreate())
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

bucket = args['s3_bucket']
key = urllib.parse.unquote_plus(args['s3_key'])
SECRET_SALT = args['secret_salt']

input_path = f"s3://{bucket}/{key}"
filename = key.split('/')[-1]
EXPECTED_COLUMNS = ["encounter_id", "patient_id", "enrollment_date", "gpa"]

try:
    # Handle multi-format data structures dynamically based on file format type extension
    if key.lower().endswith('.xml'):
        raw_df = spark.read.format("xml").option("rowTag", "record").load(input_path)
    else:
        raw_df = spark.read.option("header", "true").option("inferSchema", "true").csv(input_path)

    # Validate structural schema layout contract
    if not all(col_name in raw_df.columns for col_name in EXPECTED_COLUMNS):
        raise ValueError(f"SCHEMA ENFORCEMENT MISMATCH: Expected {EXPECTED_COLUMNS}, but got {raw_df.columns}")

    # Drop null primary row keys
    cleansed_df = raw_df.dropna(subset=["patient_id", "encounter_id"])
    if cleansed_df.count() == 0:
        raise ValueError("DATA VALIDATION REJECTION: Zero rows survived validation scrubbing filters.")

    # Apply data lineage mappings and encrypt identity attributes via native Spark SHA2 calculations
    final_df = cleansed_df.withColumn("path_string", lit(key)) \
        .withColumn("source_vendor", regexp_extract(col("path_string"), r"([^/]+)__vitals__", 1)) \
        .withColumn("hashed_patient_id", sha2(concat(col("patient_id"), lit(SECRET_SALT)), 256)) \
        .drop("patient_id", "path_string")

    # Save to Silver Zone using partitioned formats for heavy analytic processing optimization
    target_bucket = bucket.replace("-bronze", "-silver")
    target_path = f"s3://{target_bucket}/silver-vitals/"
    
    final_df.write.mode("append").partitionBy("source_vendor").parquet(target_path)
    print(f"Glue Cluster Processing complete for path: {target_path}")

except Exception as spark_failure:
    print(f"🛑 CRITICAL WORKER FAULT DETECTED: {str(spark_failure)}")
    print("Executing distributed S3-based DLQ text isolation logic sequence...")
    
    # Clone the raw data payload directly into your dedicated bucket DLQ path folder
    dlq_path = f"s3://{bucket}/dlq/glue-failures/{filename}"
    raw_text_df = spark.read.text(input_path)
    raw_text_df.write.mode("overwrite").text(dlq_path)
    
    print(f"🚨 Anomalous macro-batch successfully quarantined to S3 DLQ directory: {dlq_path}")
    raise spark_failure

job.commit()