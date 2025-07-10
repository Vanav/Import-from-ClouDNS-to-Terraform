# List of zone definitions (locals.zones_*) to include.
# Update this list when you add or remove a zones-*.tf file.
locals {
  zones = merge(
    #local.zones_example_com,
    #local.zones_example_org
  )
}
