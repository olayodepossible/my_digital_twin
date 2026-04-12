terraform {
  backend "s3" {
    # Bucket, key, region, encrypt, and use_lockfile are supplied at init time
    # (see scripts/deploy.ps1 and scripts/destroy.ps1 -backend-config=...).
    # S3 native locking (use_lockfile) avoids a DynamoDB lock table.
  }
}
