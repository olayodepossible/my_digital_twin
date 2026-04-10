param(
    [Parameter(Mandatory = $true)]
    [string]$AccountId,
    [Parameter(Mandatory = $true)]
    [string]$Region
)

$ErrorActionPreference = "Stop"

$bucket = "twin-terraform-state-$AccountId"
$table = "twin-terraform-locks"

aws s3api head-bucket --bucket $bucket 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating S3 bucket for Terraform state: $bucket ($Region) ..." -ForegroundColor Yellow
    if ($Region -eq "eu-west-2") {
        aws s3api create-bucket --bucket $bucket --region $Region
    } else {
        aws s3api create-bucket --bucket $bucket --region $Region `
            --create-bucket-configuration LocationConstraint=$Region
    }
    aws s3api put-bucket-versioning --bucket $bucket --versioning-configuration Status=Enabled
    $enc = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-bucket-encryption --bucket $bucket --server-side-encryption-configuration $enc
    aws s3api put-public-access-block --bucket $bucket --public-access-block-configuration `
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
} else {
    Write-Host "Terraform state bucket already exists: $bucket" -ForegroundColor DarkGray
}

aws dynamodb describe-table --table-name $table --region $Region 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating DynamoDB Terraform lock table: $table ($Region) ..." -ForegroundColor Yellow
    aws dynamodb create-table `
        --table-name $table `
        --attribute-definitions AttributeName=LockID,AttributeType=S `
        --key-schema AttributeName=LockID,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST `
        --region $Region
    aws dynamodb wait table-exists --table-name $table --region $Region
} else {
    Write-Host "Terraform lock table already exists: $table" -ForegroundColor DarkGray
}
