#!/bin/bash

# Author: Ivan Vanyushkin <vanav@vanav.org>

set -o nounset -o errexit -o errtrace -o pipefail
shopt -s inherit_errexit nullglob globstar dotglob
IFS=$'\n\t'
trap 'rc=$?; echo "Aborting due to errexit on line $LINENO in $(realpath -s ${BASH_SOURCE[0]}). Exit code: $rc" >&2' ERR

# Check required commands
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is not installed." >&2
    exit 1
  fi
done

# Set ClouDNS API credentials from environment variables
API_USER="${CLOUDNS_AUTH_ID:-}"
API_PASSWORD="${CLOUDNS_PASSWORD:-}"
if [[ -z "$API_USER" || -z "$API_PASSWORD" ]]; then
  echo "Error: ClouDNS API credentials are not set." >&2
  exit 1
fi

# Function to call the API
fetch_api_data() {
  local endpoint=$1
  shift
  curl -s -G "https://api.cloudns.net/${endpoint}" \
    --data-urlencode "auth-id=${API_USER}" \
    --data-urlencode "auth-password=${API_PASSWORD}" "$@"
}

# Fetch domains list
domains_response=$(fetch_api_data "dns/list-zones.json" \
  --data-urlencode "rows-per-page=100" --data-urlencode "page=1")
if ! echo "$domains_response" | jq . >/dev/null 2>&1; then
  echo "Error: Invalid JSON response for domains list." >&2
  exit 1
fi

# Extract domain names with zone=="domain"
domains=$(echo "$domains_response" | jq -r '.[] | select(.zone=="domain") | .name')
if [[ -z "$domains" ]]; then
  echo "Error: No domains found." >&2
  exit 1
fi

# Process each domain individually
for DOMAIN in $domains; do
  echo "Processing domain: $DOMAIN"
  domain_sanitized=$(echo "$DOMAIN" | tr '.' '_')

  # Fetch nameservers and records for this domain
  #ns_response=$(fetch_api_data "domains/get-nameservers.json" --data-urlencode "domain-name=${DOMAIN}")
  records_response=$(fetch_api_data "dns/records.json" --data-urlencode "domain-name=${DOMAIN}")

  #for response in "$ns_response" "$records_response"; do
  #  if ! echo "$response" | jq . >/dev/null 2>&1; then
  #    echo "Error: Invalid JSON response for ${DOMAIN}." >&2
  #    continue 2
  #  fi
  #done

  # Extract nameservers into an array
  #nameservers=( $(echo "$ns_response" | jq -r '.[]') )

  # Prepare output files for current domain (truncate files)
  tf_file="zone-${DOMAIN}.tf"
  import_file="zone-${DOMAIN}-imports.tf"
  : > "$tf_file"
  : > "$import_file"

  # Write zone resource and its import block
  #nameservers = [$(printf '"%s",' "${nameservers[@]}" | sed 's/,$//')]
  cat <<EOF >> "$tf_file"
resource "cloudns_dns_zone" "${domain_sanitized}" {
  domain = "${DOMAIN}"
  type   = "master"
}

EOF

  cat <<EOF >> "$import_file"
import {
  to = cloudns_dns_zone.${domain_sanitized}
  id = "${DOMAIN}"
}

EOF

  # Reinitialize arrays for current domain
  declare -A host_occurrences=()
  declare -A record_imports=()
  declare -A record_resources=()
  declare -A type_occurrences=()
  declare -a records_sort=()
  entries=()

  # Read record entries into an array (only for this domain)
  mapfile -t entries < <(echo "$records_response" | jq -r 'to_entries[] | @base64')

  # First pass: count occurrences per host (ignoring record type)
  for entry in "${entries[@]}"; do
    rec=$(echo "$entry" | base64 --decode)
    host=$(echo "$rec" | jq -r '.value.host')
    type=$(echo "$rec" | jq -r '.value.type')
    # Do not substitute empty host—leave it empty.
    sanitized_host=$(echo "$host" | sed 's/\*/wildcard/g' | tr '. ' '_')
    lower_type=$(echo "$type" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$sanitized_host" ]]; then
      host_key="${domain_sanitized}_${lower_type}_${sanitized_host}"
      host_occurrences["$host_key"]=$(( ${host_occurrences["$host_key"]:-0} + 1 ))
      host_key="${domain_sanitized}_${sanitized_host}"
      host_occurrences["$host_key"]=$(( ${host_occurrences["$host_key"]:-0} + 1 ))
    else
      host_key="${domain_sanitized}_${lower_type}"
      host_occurrences["$host_key"]=$(( ${host_occurrences["$host_key"]:-0} + 1 ))
    fi

  done

  # Second pass: build record resource blocks
  for entry in "${entries[@]}"; do
    rec=$(echo "$entry" | base64 --decode)
    rec_id=$(echo "$rec" | jq -r '.key')
    type=$(echo "$rec" | jq -r '.value.type')
    host=$(echo "$rec" | jq -r '.value.host')
    record_value=$(echo "$rec" | jq -r '.value.record')
    ttl=$(echo "$rec" | jq -r '.value.ttl')
    status=$(echo "$rec" | jq -r '.value.status')
    priority=$(echo "$rec" | jq -r '.value.priority // empty')

    sanitized_host=$(echo "$host" | sed 's/\*/wildcard/g' | tr '. ' '_')
    lower_type=$(echo "$type" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$sanitized_host" ]]; then
      host_key="${domain_sanitized}_${sanitized_host}"
    else
      host_key="${domain_sanitized}_${lower_type}"
    fi

    # Build resource name:
    # If the host occurs only once, use the host key.
    # Otherwise, include the lowercased type (if host is non-empty) and a counter.
    if [[ ${host_occurrences["$host_key"]:-0} -gt 1 ]]; then
      if [[ -n "$sanitized_host" ]]; then
        typed_key="${domain_sanitized}_${lower_type}_${sanitized_host}"
        if [[ ${host_occurrences["$typed_key"]:-0} -gt 1 ]]; then
          type_occurrences["$typed_key"]=$(( ${type_occurrences["$typed_key"]:-0} + 1 ))
          resource_name="${typed_key}_${type_occurrences["$typed_key"]}"
        else
          resource_name="${typed_key}"
        fi
      else
        typed_key="${domain_sanitized}_${lower_type}"
        if [[ ${host_occurrences["$typed_key"]:-0} -gt 1 ]]; then
          type_occurrences["$typed_key"]=$(( ${type_occurrences["$typed_key"]:-0} + 1 ))
          resource_name="${typed_key}_${type_occurrences["$typed_key"]}"
        else
          resource_name="${typed_key}"
        fi
      fi
    else
      resource_name="$host_key"
    fi

    # Build the import block text.
    import_text=$(cat <<EOF
import {
  to = cloudns_dns_record.${resource_name}
  id = "${DOMAIN}/${rec_id}"
}
EOF
)

    read -r -d '' resource_text <<EOF || true
resource "cloudns_dns_record" "${resource_name}" {
  type  = "${type}"
  name  = "${host}"$( [[ -n "${priority:-}" ]] && printf "\n  priority = %s" "$priority" )
  value = "${record_value}"
  ttl   = ${ttl}$( [[ $status -eq 0 ]] && printf "\n  #status = %s  - read-only value, comment out or delete this resource" "$status" )
  zone  = "${DOMAIN}"
}
EOF

    record_imports["$resource_name"]="$import_text"
    record_resources["$resource_name"]="$resource_text"
    # Build a sort key using the actual "name" field from the record (host).
    # If host is empty, use an empty string.
    sort_key="${host}"
    # Append a delimiter and resource name.
    records_sort+=( "${sort_key}|||${resource_name}" )
  done

  # Sort records_sort array by the sort key (the part before "|||")
  IFS=$'\n' sorted_entries=($(printf "%s\n" "${records_sort[@]}" | sort -t '|' -k1,1))
  unset IFS

  # Write sorted output to files.
  for entry in "${sorted_entries[@]}"; do
    # Extract the resource name (the part after "|||")
    resource_name="${entry#*|||}"
    printf "%s\n" "${record_imports["$resource_name"]}" >> "$import_file"
    printf "%s\n" "${record_resources["$resource_name"]}" >> "$tf_file"
  done

  echo "Finished processing domain: $DOMAIN"
done
