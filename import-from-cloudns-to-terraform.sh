#!/bin/bash

# Author: Ivan Vanyushkin <vanav@vanav.org>. © All rights reserved.
# Source: https://github.com/Vanav/Import-from-ClouDNS-to-Terraform

set -o nounset -o errexit -o errtrace -o pipefail
shopt -s inherit_errexit lastpipe nullglob globstar dotglob
IFS=$'\n\t'
err_trace() { rc=$?; loc=$(caller); echo "Error code $rc on line $loc" >&2; }
trap err_trace ERR

require_commands() {
  local cmds=(curl jq fold sed)
  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Error: ${cmd} not installed" >&2
      exit 1
    fi
  done
}

validate_credentials() {
  : "${CLOUDNS_AUTH_ID:?Error: set CLOUDNS_AUTH_ID and CLOUDNS_PASSWORD}"
  : "${CLOUDNS_PASSWORD:?Error: set CLOUDNS_AUTH_ID and CLOUDNS_PASSWORD}"
}

fetch_api() {
  local endpoint="$1"; shift
  curl --fail -sS -G "https://api.cloudns.net/${endpoint}" --data-urlencode "auth-id=${CLOUDNS_AUTH_ID}" \
    --data-urlencode "auth-password=${CLOUDNS_PASSWORD}" "$@"
}

process_domain() {
  local domain="$1"
  echo "Processing domain: ${domain}"

  local dsafe="${domain//[^[:alnum:]]/_}"
  local import_file="zone-${domain}-imports.tf"
  local tf_file="zone-${domain}.tf"

  # Initialize import file
  : >"$import_file"
  cat >>"$import_file" <<EOF
import {
  to = cloudns_dns_zone.zones["${domain}"]
  id = "${domain}"
}

EOF

  # Fetch all records as JSON entries
  local records_json
  records_json=$(fetch_api dns/records.json --data-urlencode domain-name="$domain" --data-urlencode order-by=host)

  jq -e -c 'to_entries[]' <<<"$records_json" | mapfile -t entries

  # Compute max width for padding "type = ...,"
  local max_type_len=15  # 'type = "CNAME",'
  for entry in "${entries[@]}"; do
    local t
    t=$(jq -r '.value.type' <<<"$entry")
    local fld="type = \"${t}\","
    (( ${#fld} > max_type_len )) && max_type_len=${#fld}
  done

  # Start Terraform locals block
  cat >"$tf_file" <<EOF
locals {
  zones_${dsafe} = {
    "${domain}" = {
      records = [
EOF

  declare -A base_count=()

  # Iterate each record entry
  for entry in "${entries[@]}"; do
    # Build associative array of record attributes
    declare -A record=(
      [id]="$(jq -r '.key' <<<"$entry")"
      [type]="$(jq -r '.value.type' <<<"$entry")"
      [host]="$(jq -r '.value.host' <<<"$entry")"
      [value]="$(jq -r '.value.record' <<<"$entry")"
      [ttl]="$(jq -r '.value.ttl' <<<"$entry")"
      [prio]="$(jq -r '(.value.priority // "")' <<<"$entry")"
      [status]="$(jq -r '.value.status' <<<"$entry")"
    )

    # Generate a unique Terraform resource key
    local lower_type="${record["type"],,}"
    local base
    if [[ -n "${record["host"]}" ]]; then
      base="${domain}_${lower_type}_${record["host"]}"
    else
      base="${domain}_${lower_type}"
    fi
    local count=$(( ${base_count[$base]:-0} + 1 ))
    base_count[$base]=$count
    local key="$base"
    (( count > 1 )) && key="${base}_${count}"

    # Comment out disabled records
    local prefix=""
    [[ "${record["status"]}" == "0" ]] && prefix='# '

    # Pad the "type" field
    local type_field="type = \"${record["type"]}\","
    local pad_spaces
    pad_spaces=$(printf '%*s' $((max_type_len - ${#type_field})) "")

    {
      # Start the record block
      printf '%s{ %s%s name = "%s", ' "$prefix" "$type_field" "$pad_spaces" "${record["host"]}"

      # Handle long records
      if [[ $(( ${#record["host"]} + ${#record["value"]} )) -gt 107 ]]; then
        echo 'data = join("", ['
        echo "${record["value"]}" | fold -w153 | sed 's/.*/    "&",/; $s/,$//'
        printf '  ]), ttl = %s' "${record["ttl"]}"
      else
        printf 'data = "%s", ttl = %s' "${record["value"]//\"/\\\"}" "${record["ttl"]}"
      fi

      # Optional priority
      [[ -n "${record["prio"]}" ]] && printf ', priority = %s' "${record["prio"]}"

      # Close this record
      echo " },"
    } >>"$tf_file"

    # Append to import file
    cat >>"$import_file" <<EOF
import {
  to = cloudns_dns_record.records["${key}"]
  id = "${domain}/${record["id"]}"
}
EOF
  done

  # Close Terraform locals block
  cat >>"$tf_file" <<EOF
      ]
    }
  }
}
EOF

  echo "Wrote ${tf_file} and ${import_file}"
}

main() {
  require_commands
  validate_credentials

  local domains_json domains domain
  domains_json=$(fetch_api dns/list-zones.json --data-urlencode rows-per-page=100 --data-urlencode page=1)

  jq -e -r '.[] | select(.zone=="domain") | .name' <<<"$domains_json" | mapfile -t domains

  for domain in "${domains[@]}"; do
    process_domain "$domain"
  done
}

main "$@"
