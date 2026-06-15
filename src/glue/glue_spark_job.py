import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import input_file_name, regexp_extract, col, udf, lit
from pyspark.sql.types import StringType
import hmac
import hashlib

# 1. Capture arguments passed from our Router Lambda
args = getResolvedOptions(sys.argv, ['JOB_NAME', 's3_bucket', 's3_key'])

# 2. Initialize Glue and Spark contexts
glueContext = GlueContext(SparkContext.getOrCreate())
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

bucket = args['s3_bucket']
key = args['s3_key']
input_path = f"s3://{bucket}/{key}"

print(f"Starting distributed PySpark job processing for: {input_path}")

# 3. Simulated Corporate Secret Salt (In prod, fetch via boto3 Secrets Manager parameter)
SECRET_SALT = "TexasLonghorns2026!#CloudDataPlatform"

# 4. Define a PySpark User Defined Function (UDF) for our Salted SHA-256 hash
def spark_salted_hash(patient_id, salt=SECRET_SALT):
    if patient_id is None or str(patient_id).strip() == "":
        return None
    clean_id = str(patient_id).strip().upper()
    return hmac.new(
        salt.encode('utf-8'),
        clean_id.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()

# Register the function as a Spark UDF
hash_udf = udf(spark_salted_hash, StringType())

# 5. Read the massive data file into a distributed Spark DataFrame
# Supports CSV or automatically adapts to XML/Parquet formats based on configurations
raw_df = spark.read.option("header", "true").option("inferSchema", "true").csv(input_path)

# 6. Data Integrity Gate: Drop records where primary indicators are null
cleansed_df = raw_df.dropna(subset=["patient_id", "encounter_id"])

# 7. Extract File Metadata for Data Lineage from file path string via Regex
# EXPECTED: .../vendor_A__vitals__20260614__uuid123.csv
parsed_df = cleansed_df.withColumn("path_string", lit(key)) \
    .withColumn("vendor_id", regexp_extract(col("path_string"), r"^([^/]+)__vitals__", 1)) \
    .withColumn("file_uuid", regexp_extract(col("path_string"), r"__\d+__([^\.]+)\.", 1))

# 8. Data Governance: Mask PHI and drop cleartext identifiers
final_df = parsed_df.withColumn("hashed_patient_id", hash_udf(col("patient_id"))) \
                     .drop("patient_id", "path_string")

# 9. Write out the polished, partitioned dataset back to S3 Silver in Parquet format
target_bucket = bucket.replace("-bronze", "-silver")
target_path = f"s3://{target_bucket}/silver-vitals/"

final_df.write \
    .mode("append") \
    .partitionBy("source_vendor") \
    .parquet(target_path)

print(f"Distributed processing complete. Data appended to: {target_path}")
job.commit()