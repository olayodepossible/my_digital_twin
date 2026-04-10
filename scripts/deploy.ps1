param(
    [Parameter(Mandatory=$true)]
    [string]$Environment,
    [string]$ProjectName = "digital-twin"
)

$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Build Lambda package
Set-Location (Split-Path $PSScriptRoot -Parent)   # project root

$dotenvPath = Join-Path (Get-Location) ".env"
if (Test-Path $dotenvPath) {
    Get-Content $dotenvPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { return }
        $name = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if ($name) { [Environment]::SetEnvironmentVariable($name, $val, "Process") }
    }
}
if (-not $env:TF_VAR_openrouter_api_key -and $env:OPENROUTER_API_KEY) {
    $env:TF_VAR_openrouter_api_key = $env:OPENROUTER_API_KEY
}

Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
uv run deploy.py
Set-Location ..

# 2. Terraform workspace & apply
Set-Location terraform
$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsRegion = if (-not [string]::IsNullOrWhiteSpace($env:DEFAULT_AWS_REGION)) {
    $env:DEFAULT_AWS_REGION.Trim()
} else {
    "eu-west-2"
}
& (Join-Path $PSScriptRoot "ensure-terraform-backend.ps1") -AccountId $awsAccountId -Region $awsRegion
terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"

if (-not (terraform workspace list | Select-String $Environment)) {
    terraform workspace new $Environment
} else {
    terraform workspace select $Environment
}

if ($Environment -eq "prod") {
    terraform apply -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
} else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}

$ApiUrl        = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

# 3. Build + deploy frontend
Set-Location ..\frontend

# Create production environment file with API URL
Write-Host "Setting API URL for production..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE)." }
npm run build
if ($LASTEXITCODE -ne 0) { throw "npm run build failed (exit $LASTEXITCODE)." }

$frontendOut = Join-Path (Get-Location) "out"
if (-not (Test-Path -Path $frontendOut -PathType Container)) {
    throw "Static export folder not found: $frontendOut. Fix the Next.js build (next.config needs output: 'export') and ensure npm run build succeeds."
}
aws s3 sync "$frontendOut" "s3://$FrontendBucket/" --delete
if ($LASTEXITCODE -ne 0) { throw "aws s3 sync failed (exit $LASTEXITCODE)." }
Set-Location ..

# 4. Final summary
$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan