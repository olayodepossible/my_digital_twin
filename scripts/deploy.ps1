param(
    [Parameter(Mandatory=$false)]
    [string]$Environment = "dev",  #Defaults to 'dev' if no value provided
    [string]$ProjectName = "digital-twin"
)

$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Build Lambda package
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot

# Load .env variables into the Process environment
$dotenvPath = Join-Path $ProjectRoot ".env"
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

# --- Fix: Robust OpenRouter Key Bridging ---
# Ensure TF_VAR_openrouter_api_key is set only if a non-empty key exists
if (-not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) {
    $env:TF_VAR_openrouter_api_key = $env:OPENROUTER_API_KEY.Trim()
}

if (-not [string]::IsNullOrWhiteSpace($env:TF_VAR_openrouter_api_key)) {
    $maskedKey = $env:TF_VAR_openrouter_api_key.Substring(0, 10) + "..."
    Write-Host "Using OpenRouter Key: $maskedKey" -ForegroundColor Gray
} else {
    Write-Warning "No OpenRouter API Key found in environment variables."
}

if ($env:GITHUB_ACTIONS -eq "true") {
    if (-not [string]::IsNullOrWhiteSpace($env:TF_VAR_openrouter_api_key)) {
        Write-Host "GitHub Actions: API Key verified." -ForegroundColor Cyan
    } else {
        Write-Warning "GitHub Actions: API Key is MISSING."
    }
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

# Ensure S3 Backend exists (Fix for LocationConstraint handled inside this script)
& (Join-Path $PSScriptRoot "ensure-terraform-backend.ps1") -AccountId $awsAccountId -Region $awsRegion

terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"

# --- Fix: Workspace Selection Logic ---
$currentWorkspaces = terraform workspace list
# Use regex boundary \b to ensure we don't match 'dev' inside 'dev-test'
if ($currentWorkspaces -match "\b$Environment\b") {
    Write-Host "Selecting workspace: $Environment" -ForegroundColor Gray
    terraform workspace select $Environment
} else {
    Write-Host "Creating new workspace: $Environment" -ForegroundColor Yellow
    terraform workspace new $Environment
}

if ($Environment -eq "prod") {
    terraform apply -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
} else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}

$ApiUrl         = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

# 3. Build + deploy frontend
Set-Location ..\frontend

Write-Host "Setting API URL for production..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
npm run build
if ($LASTEXITCODE -ne 0) { throw "npm run build failed." }

$frontendOut = Join-Path (Get-Location) "out"
if (-not (Test-Path -Path $frontendOut -PathType Container)) {
    throw "Static export folder not found: $frontendOut."
}
aws s3 sync "$frontendOut" "s3://$FrontendBucket/" --delete
if ($LASTEXITCODE -ne 0) { throw "aws s3 sync failed." }
Set-Location ..

# 4. Final summary
$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl -and $CustomUrl -notmatch "Output not found") {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan