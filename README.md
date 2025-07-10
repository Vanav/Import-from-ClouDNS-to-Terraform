# Import from ClouDNS to Terraform
Script to import DNS zones and records from ClouDNS to Terraform

## Usage
1. Create API key in ClouDNS (paid supscription required)
2. Add key ID and password to environment variables
3. Call script. It will import all zones and will create in current directory multiple files:
- `zone-example.com.tf`: `resource`'s for zone and all records
- `zone-example.com-import.tf`: initial `import`'s. Can be removed after Terraform state is created.
```
export CLOUDNS_AUTH_ID=_id_ CLOUDNS_PASSWORD=_password_
bash import-from-cloudns-to-terraform.sh
terraform init -upgrade
terraform plan
terraform apply
```

## Features
- Will import all zones from ClouDNS account.
- Records are sorted by record name
- Uniqie resource ID for Terraform are automatically generated in shortest possible way
- `priority` field is added only if needed.
- `status` is added if record is disabled in ClouDNS UI, but it is read only field in current implementation of
ClouDNS Terraform provider. You can comment out or delete this resources after import.
- I don't use `terraform plan -generate-config-out=generated.tf`, because it generates a lot of empty fields,
doesn't sort records and generates not user friendly resource names.

## Resources
- [Terraform ClouDNS provider](https://registry.terraform.io/providers/ClouDNS/cloudns/latest/docs/resources/dns_record)
- [ClouDNS API](https://www.cloudns.net/wiki/article/46/)
