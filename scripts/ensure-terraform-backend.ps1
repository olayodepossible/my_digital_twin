param(
    [Parameter(Mandatory = $true)]
    [string]$AccountId,
    [Parameter(Mandatory = $true)]
    [string]$Region
)

$ErrorActionPreference = "Stop"

$Region = $Region.Trim()
$bucketName = "twin-terraform-state-$AccountId"



$headRc = Test-AwsCommand { aws s3api head-bucket --bucket $bucketName 2>$null; $LASTEXITCODE }

if ($headRc -ne 0) {

    Write-Host "Creating S3 bucket for Terraform state: $bucketName ($Region) ..." -ForegroundColor Yellow

    $prevEap = $ErrorActionPreference

    $ErrorActionPreference = "Continue"

    try {

        if ($Region -eq "us-east-1") {

            $createOut = aws s3api create-bucket --bucket $bucketName --region $Region 2>&1

        }

        else {

            $createOut = aws s3api create-bucket --bucket $bucketName --region $Region `

                --create-bucket-configuration LocationConstraint=$Region 2>&1

        }

        if ($LASTEXITCODE -ne 0 -and "$createOut" -notmatch 'BucketAlreadyOwnedByYou') {

            throw "create-bucket failed ($LASTEXITCODE): $createOut"

        }



        $verOut = aws s3api put-bucket-versioning --bucket $bucketName --versioning-configuration Status=Enabled 2>&1

        if ($LASTEXITCODE -ne 0) {

            throw "put-bucket-versioning failed ($LASTEXITCODE): $verOut"

        }



        # Pass JSON via a temp file: bare --server-side-encryption-configuration $var breaks on Windows/PowerShell.

        $encJson = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

        $encFile = Join-Path $env:TEMP ("twin-tf-s3-enc-{0}.json" -f [Guid]::NewGuid())

        try {

            $utf8NoBom = New-Object System.Text.UTF8Encoding $false

            [System.IO.File]::WriteAllText($encFile, $encJson, $utf8NoBom)

            $encUri = "file:///" + (($encFile -replace '\\', '/') -replace '^/', '')

            $encOut = aws s3api put-bucket-encryption --bucket $bucketName --server-side-encryption-configuration $encUri 2>&1

            $encRc = $LASTEXITCODE

            if ($encRc -ne 0) {

                throw "put-bucket-encryption failed ($encRc): $encOut"

            }

        }

        finally {

            Remove-Item -LiteralPath $encFile -Force -ErrorAction SilentlyContinue

        }



        $pabOut = aws s3api put-public-access-block --bucket $bucketName --public-access-block-configuration `

            BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true 2>&1

        if ($LASTEXITCODE -ne 0) {

            throw "put-public-access-block failed ($LASTEXITCODE): $pabOut"

        }

    }

    finally {

        $ErrorActionPreference = $prevEap

    }

}

else {

    Write-Host "Terraform state bucket already exists: $bucketName" -ForegroundColor DarkGray

}


$tableName = "terraform-locks"

$tableExists = aws dynamodb describe-table --table-name $tableName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating DynamoDB table for Terraform locking: $tableName" -ForegroundColor Yellow

    aws dynamodb create-table `
        --table-name $tableName `
        --attribute-definitions AttributeName=LockID,AttributeType=S `
        --key-schema AttributeName=LockID,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST | Out-Null
}
else {
    Write-Host "DynamoDB table already exists: $tableName" -ForegroundColor DarkGray
}