import pytest
import pandas as pd
from lambda_function import compute_salted_hash

def test_deterministic_hashing():
    """
    Ensures that the exact same patient ID + salt combination 
    always yields the identical hash string (Idempotency check).
    """
    patient_id = "P-998877"
    salt = "TestSalt2026!"
    
    hash_one = compute_salted_hash(patient_id, salt)
    hash_two = compute_salted_hash(patient_id, salt)
    
    assert hash_one is not None
    assert hash_one == hash_two
    # Ensure raw ID isn't exposed in the output string
    assert patient_id not in hash_one 

def test_hash_uniqueness_with_different_salt():
    """
    Guarantees that a different salt changes the output,
    proving the salt protects against rainbow table attacks.
    """
    patient_id = "P-998877"
    
    hash_standard = compute_salted_hash(patient_id, "SaltAlpha")
    hash_modified = compute_salted_hash(patient_id, "SaltBeta")
    
    assert hash_standard != hash_modified

def test_null_handling_logic():
    """
    Tests that empty or missing values return None gracefully 
    instead of throwing execution runtime errors.
    """
    assert compute_salted_hash("", "Salt") is None
    assert compute_salted_hash(None, "Salt") is None