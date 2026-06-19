import unittest
from unittest.mock import patch, MagicMock
import json
import io

# Import your lambda handler function from your script file
# Assumes your Lambda code is saved in a file named `transformer_lambda.py`
from transformer_lambda import lambda_handler

class TestTransformerLambda(unittest.TestCase):

    def setUp(self):
        """Runs before every individual test to set up mock event payloads."""
        self.mock_event = {
            "bucket": "university-vitals-bronze-bucket",
            "key": "vendor_A/vendor_A__vitals__20260614__uuid123.csv"
        }
        self.mock_context = MagicMock()

    @patch('transformer_lambda.s3_client')
    def test_successful_transformation(self, mock_s3):
        """Test the golden path: Clean CSV input produces valid, hashed output in Silver S3."""
        # 1. Arrange: Setup mock cleartext CSV data matching expected schema
        csv_data = (
            "encounter_id,patient_id,enrollment_date,gpa\n"
            "E101,PID999,2026-06-01,3.85\n"
            "E102,PID888,2026-06-02,\n"  # Missing GPA should default to '0.00'
        )
        
        # Simulate S3 get_object response stream
        mock_response = {'Body': MagicMock()}
        mock_response['Body'].read.return_value = csv_data.encode('utf-8')
        mock_s3.get_object.return_value = mock_response

        # 2. Act: Invoke the handler function directly
        response = lambda_handler(self.mock_event, self.mock_context)

        # 3. Assert: Verify the function returned a success flag
        self.assertEqual(response['status'], 'success')
        self.assertEqual(response['records_mutated'], 2)
        self.assertIn('transformed_vendor_A', response['processed_file'])

        # Verify that s3_client.put_object was actually invoked to save the file
        mock_s3.put_object.assert_called_once()
        
        # Extract and verify the contents written to S3 Silver
        called_kwargs = mock_s3.put_object.call_args[1]
        written_body = called_kwargs['Body']
        
        self.assertIn("hashed_patient_id", written_body)
        self.assertNotIn("PID999", written_body)  # Cleartext must be completely gone!
        self.assertIn("0.00", written_body)       # Verifies missing GPA default logic

    @patch('transformer_lambda.s3_client')
    def test_schema_validation_failure(self, mock_s3):
        """Test that an incorrect input schema causes the Lambda to fail gracefully."""
        # Arrange: Setup a bad CSV missing the critical column 'encounter_id'
        bad_csv_data = (
            "bad_column,patient_id,enrollment_date,gpa\n"
            "E101,PID999,2026-06-01,3.85\n"
        )
        mock_response = {'Body': MagicMock()}
        mock_response['Body'].read.return_value = bad_csv_data.encode('utf-8')
        mock_s3.get_object.return_value = mock_response

        # Act
        response = lambda_handler(self.mock_event, self.mock_context)

        # Assert
        self.assertEqual(response['status'], 'failed')
        self.assertIn('SCHEMA MISMATCH', response['error'])
        # Ensure it stopped execution before writing anything out to S3 Silver
        mock_s3.put_object.assert_not_called()

    @patch('transformer_lambda.s3_client')
    def test_data_integrity_drop_all_rows(self, mock_s3):
        """Test that files with missing primary keys are rejected entirely."""
        # Arrange: Every record is missing either patient_id or encounter_id
        corrupt_csv_data = (
            "encounter_id,patient_id,enrollment_date,gpa\n"
            ",PID999,2026-06-01,3.85\n"  # Missing encounter_id
            "E102,,2026-06-02,3.50\n"    # Missing patient_id
        )
        mock_response = {'Body': MagicMock()}
        mock_response['Body'].read.return_value = corrupt_csv_data.encode('utf-8')
        mock_s3.get_object.return_value = mock_response

        # Act
        response = lambda_handler(self.mock_event, self.mock_context)

        # Assert
        self.assertEqual(response['status'], 'failed')
        self.assertIn('completely empty or entirely corrupt', response['error'])
        mock_s3.put_object.assert_not_called()

if __name__ == '__main__':
    unittest.main()