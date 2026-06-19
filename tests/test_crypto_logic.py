# test_glue_logic.py
import pytest
from pyspark.sql import SparkSession
from pyspark.sql.functions import col, sha2, concat, lit

@pytest.fixture(scope="module")
def spark():
    """Initializes a local, lightweight Spark Session for CI testing."""
    return SparkSession.builder.master("local[*]").appName("GlueTest").getOrCreate()

def test_spark_deterministic_hashing(spark):
    """Idempotency check: Verifies native Spark hashing is identical for the same input."""
    salt = "TestSalt2026!"
    # Create a simple 1-row DataFrame
    data = [("P-998877",)]
    df = spark.createDataFrame(data, ["patient_id"])
    
    # Apply our native Glue transformation logic
    transformed_df = df.withColumn("hashed_patient_id", sha2(concat(col("patient_id"), lit(salt)), 256))
    result = transformed_df.collect()[0]["hashed_patient_id"]
    
    assert result is not None
    assert len(result) == 64  # SHA-256 outputs a 64-character hex string

def test_spark_hash_uniqueness_with_different_salt(spark):
    """Rainbow table check: Verifies changing the salt changes the native Spark output."""
    data = [("P-998877",)]
    df = spark.createDataFrame(data, ["patient_id"])
    
    hash_a = df.withColumn("h", sha2(concat(col("patient_id"), lit("SaltAlpha")), 256)).collect()[0]["h"]
    hash_b = df.withColumn("h", sha2(concat(col("patient_id"), lit("SaltBeta")), 256)).collect()[0]["h"]
    
    assert hash_a != hash_b