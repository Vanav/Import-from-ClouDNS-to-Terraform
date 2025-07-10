# © Ivan Vanyushkin <vanav@vanav.org>. All rights reserved.

variable "cloudns_auth_id" {
  description = "ClouDNS API key ID"
  type        = number
  ephemeral   = true
}

variable "cloudns_auth_password" {
  description = "ClouDNS API key password"
  type        = string
  ephemeral   = true
  sensitive   = true
}

terraform {
  required_version = ">= 1.0"
  required_providers {
    cloudns = {
      source  = "Cloudns/cloudns"
      version = ">= 1.0"
    }
  }
}

provider "cloudns" {
  # Optional, ClouDNS currently maxxes out at 20 requests per second per ip. Defaults to 5.
  rate_limit = 35

  auth_id  = var.cloudns_auth_id
  password = var.cloudns_auth_password
}

locals {
  # Flatten zones → records and build key_base in one go
  all_records = flatten([
    for zone_name, zone_data in local.zones : [
      for rec in zone_data.records : merge(rec, {
        zone     = zone_name
        key_base = join("_", compact([
          zone_name,
          lower(rec.type),
          rec.name  # compact() drops empty strings
        ]))
      })
    ]
  ])

  # For each key_base, collect the list of record indexes
  occurrences = {
    for base in distinct(local.all_records[*].key_base) :
    base => [
      for idx, r in local.all_records :
      idx if r.key_base == base
    ]
  }

  # Tag each record with its 1-based occurrence count
  records_with_count = [
    for idx, rec in local.all_records : merge(rec, {
      count = index(local.occurrences[rec.key_base], idx) + 1
    })
  ]

  # Build the for_each map, suffixing duplicates “_2”, “_3”, …
  record_map = {
    for rec in local.records_with_count : (
      rec.count == 1 ?
      rec.key_base :
      "${rec.key_base}_${rec.count}"
    ) => merge(rec, {
      zone_id = cloudns_dns_zone.zones[rec.zone].id
    })
  }
}

resource "cloudns_dns_zone" "zones" {
  for_each    = local.zones
  domain      = each.key
  type        = "master"
  nameservers = [each.key]  # Real NS or null will create unmanaged NS records
  lifecycle {
    ignore_changes = [nameservers]  # Ignore changes from provider
  }
}

resource "cloudns_dns_record" "records" {
  for_each = local.record_map
  zone     = each.value.zone_id
  type     = each.value.type
  name     = each.value.name
  value    = each.value.data
  ttl      = each.value.ttl
  priority = try(each.value.priority, null)
}
