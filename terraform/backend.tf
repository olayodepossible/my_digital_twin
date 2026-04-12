terraform {
  backend "s3" {
    bucket         = "twin-terraform-state-PLACEHOLDER"
    key            = "terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}