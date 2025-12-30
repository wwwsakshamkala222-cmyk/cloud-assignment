terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# 1. Configure the AWS Provider
provider "aws" {
  region = "us-east-1"  # Change this if your SES verified email is in a different region
}

# Variable for your email (REPLACE THE DEFAULT VALUE)
variable "admin_email" {
  description = "The email address verified in SES to receive reports"
  type        = string
  default     = "sakshamkala111@gmail.com" # <--- UPDATE THIS
}

# ---------------------------------------------------------
# 2. Storage Resources (S3 & DynamoDB)
# ---------------------------------------------------------

# Generate a random suffix so your bucket name is unique globally
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "data_bucket" {
  bucket        = "cloud-assignment-data-${random_id.bucket_suffix.hex}"
  force_destroy = true  # Allows deleting bucket even if it contains files (good for testing)
}

resource "aws_dynamodb_table" "processed_data" {
  name         = "ProcessedData"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# ---------------------------------------------------------
# 3. IAM Role (Permissions)
# ---------------------------------------------------------

# Create a role that allows Lambda to run
resource "aws_iam_role" "lambda_role" {
  name = "assignment_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Attach permissions to the role (S3, DynamoDB, SES, and Logging)
resource "aws_iam_role_policy" "lambda_policy" {
  name = "assignment_lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ],
        Resource = aws_dynamodb_table.processed_data.arn
      },
      {
        Effect = "Allow",
        Action = ["s3:GetObject"],
        Resource = "${aws_s3_bucket.data_bucket.arn}/*"
      },
      {
        Effect = "Allow",
        Action = ["ses:SendEmail", "ses:SendRawEmail"],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ---------------------------------------------------------
# 4. Prepare Code for Deployment
# ---------------------------------------------------------

# Zip the Python code automatically
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/lambda_function.zip"
}

# ---------------------------------------------------------
# 5. Lambda Functions
# ---------------------------------------------------------

# Processor Function (Triggered by S3)
resource "aws_lambda_function" "processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "DataProcessorFunction"
  role             = aws_iam_role.lambda_role.arn
  handler          = "processor.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.9"
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.processed_data.name
    }
  }
}

# Reporter Function (Triggered by EventBridge)
resource "aws_lambda_function" "reporter" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "DailyReportFunction"
  role             = aws_iam_role.lambda_role.arn
  handler          = "reporter.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.9"
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME      = aws_dynamodb_table.processed_data.name
      SENDER_EMAIL    = var.admin_email
      RECIPIENT_EMAIL = var.admin_email
    }
  }
}

# ---------------------------------------------------------
# 6. Triggers (Event-Driven & Scheduled)
# ---------------------------------------------------------

# Grant S3 permission to invoke the Processor Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.data_bucket.arn
}

# Configure S3 to actually send the event
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.data_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# Create a Schedule (EventBridge) - Runs every day at 9 AM UTC
resource "aws_cloudwatch_event_rule" "daily_schedule" {
  name                = "daily-report-trigger"
  description         = "Triggers daily report lambda"
  schedule_expression = "cron(0 9 * * ? *)"
}

# Target the Reporter Lambda
resource "aws_cloudwatch_event_target" "check_foo" {
  rule      = aws_cloudwatch_event_rule.daily_schedule.name
  target_id = "reporter_lambda"
  arn       = aws_lambda_function.reporter.arn
}

# Grant EventBridge permission to invoke the Reporter Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_schedule.arn
}