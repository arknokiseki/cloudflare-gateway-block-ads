#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================

# API Keys (Secrets from GitHub)
API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"

# Settings
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_LISTS=250
MAX_RETRIES=10

# ==========================================
# ERROR HANDLING
# ==========================================

# Define error function
function error() {
    echo "::error::$1"
    exit 1
}

# Define silent error function
function silent_error() {
    echo "::warning::$1"
    exit 0
}

# ==========================================
# 1. DOWNLOAD & PREPARE LISTS
# ==========================================

# Define your lists
lists=(
  "https://raw.githubusercontent.com/r-a-y/mobile-hosts/master/AdguardDNS.txt"
  "https://raw.githubusercontent.com/r-a-y/mobile-hosts/master/AdguardMobileSpyware.txt"
  "https://raw.githubusercontent.com/r-a-y/mobile-hosts/master/AdguardApps.txt"
  "https://raw.githubusercontent.com/r-a-y/mobile-hosts/master/AdguardTracking.txt"
)

echo "--- DEBUG: Starting Download ---"
rm -f combined_temp.txt

for url in "${lists[@]}"; do
    echo "Fetching: $url"
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors "$url" >> combined_temp.txt || echo "::warning::Failed to download $url"
done

echo "--- DEBUG: Processing & Cleaning ---"

cat combined_temp.txt \
  | tr -d '\r' \
  | awk '$1 ~ /^(0\.0\.0\.0|127\.0\.0\.1|::1)$/ {print $2} !/^(0\.0\.0\.0|127\.0\.0\.1|::1)$/ {print $1}' \
  | cut -d '#' -f 1 \
  | tr -d ' ' \
  | grep -vE '^\s*$' \
  | grep -vE '^(0\.0\.0\.0|127\.0\.0\.1|localhost|::1)$' \
  | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort | uniq > oisd_small_domainswild2.txt

# Remove temp file
rm -f combined_temp.txt

# Remove temp file
rm -f combined_temp.txt

# ==========================================
# 2. DEBUGGING CHECKS
# ==========================================

echo "--- DEBUG: Verification ---"

# Check if file exists and is not empty
[[ -s oisd_small_domainswild2.txt ]] || error "The domains list is empty"

# Count lines
total_lines=$(wc -l < oisd_small_domainswild2.txt)
echo "Total domains found: $total_lines"

# PRINT THE FIRST 5 LINES (Crucial Debugging)
echo "Peek at the first 5 domains:"
head -n 5 oisd_small_domainswild2.txt

# Check against limit
if (( total_lines > MAX_LIST_SIZE * MAX_LISTS )); then
    error "List too large: $total_lines domains. Limit is $((MAX_LIST_SIZE * MAX_LISTS))."
fi

# Calculate required lists
total_lists=$((total_lines / MAX_LIST_SIZE))
[[ $((total_lines % MAX_LIST_SIZE)) -ne 0 ]] && total_lists=$((total_lists + 1))
echo "Lists required: $total_lists"


# ==========================================
# 3. CLOUDFLARE SYNC
# ==========================================

echo "--- DEBUG: Syncing with Cloudflare ---"

# Get current lists from Cloudflare
current_lists=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json") || error "Failed to get current lists from Cloudflare"

# Get current policies
current_policies=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json") || error "Failed to get current policies"

# Check existing lists
current_lists_count=$(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" 'if (.result | length > 0) then .result | map(select(.name | contains($PREFIX))) | length else 0 end')
current_lists_count_without_prefix=$(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" 'if (.result | length > 0) then .result | map(select(.name | contains($PREFIX) | not)) | length else 0 end')

echo "Existing lists: $current_lists_count"

# Check if we have space
if [[ ${total_lists} -gt $((MAX_LISTS - current_lists_count_without_prefix)) ]]; then
    error "Not enough space in Cloudflare account for $total_lists new lists."
fi

# Split big file into chunks
split -l ${MAX_LIST_SIZE} oisd_small_domainswild2.txt oisd_small_domainswild2.txt.

chunked_lists=()
for file in oisd_small_domainswild2.txt.*; do
    chunked_lists+=("${file}")
done

used_list_ids=()
excess_list_ids=()
list_counter=1

# UPDATE EXISTING LISTS
if [[ ${current_lists_count} -gt 0 ]]; then
    for list_id in $(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" '.result | map(select(.name | contains($PREFIX))) | .[].id'); do
        # If no more chunks left, delete this old list
        if [[ ${#chunked_lists[@]} -eq 0 ]]; then
            echo "Deleting unused list: ${list_id}"
            excess_list_ids+=("${list_id}")
            continue
        fi

        echo "Overwriting list ${list_counter}/${total_lists} (ID: $list_id)..."

        # Get old items to remove
        list_items=$(curl -sSfL -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}/items?limit=${MAX_LIST_SIZE}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")
        list_items_values=$(echo "${list_items}" | jq -r '.result | map(.value) | map(select(. != null))')

        # Get new items to add
        list_items_array=$(jq -R -s 'split("\n") | map(select(length > 0) | { "value": . })' "${chunked_lists[0]}")

        # Construct JSON
        payload=$(jq -n --argjson append_items "$list_items_array" --argjson remove_items "$list_items_values" '{
            "append": $append_items,
            "remove": $remove_items
        }')

        # Send PATCH
        curl -sSfL --retry "$MAX_RETRIES" -X PATCH "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$payload" > /dev/null || error "Failed to patch list ${list_id}"

        used_list_ids+=("${list_id}")
        rm -f "${chunked_lists[0]}"
        chunked_lists=("${chunked_lists[@]:1}")
        list_counter=$((list_counter + 1))
    done
fi

# CREATE NEW LISTS
for file in "${chunked_lists[@]}"; do
    formatted_counter=$(printf "%03d" "$list_counter")
    echo "Creating new list ${list_counter}/${total_lists}..."

    payload=$(jq -n --arg PREFIX "${PREFIX} - ${formatted_counter}" --argjson items "$(jq -R -s 'split("\n") | map(select(length > 0) | { "value": . })' "${file}")" '{
        "name": $PREFIX,
        "type": "DOMAIN",
        "items": $items
    }')

    response=$(curl -sL -w "\nHTTP_STATUS:%{http_code}" -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$payload")

    http_status=$(echo "$response" | tail -n1 | cut -d':' -f2)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_status" -ge 400 ]]; then
        echo "::error::Cloudflare Error ($http_status): $body"
        exit 1
    fi

    # Extract ID from success body
    list=$(echo "$body")

    used_list_ids+=("$(echo "${list}" | jq -r '.result.id')")
    rm -f "${file}"
    list_counter=$((list_counter + 1))
done

# ==========================================
# 4. POLICY UPDATE
# ==========================================

echo "--- DEBUG: Updating Gateway Policy ---"

policy_id=$(echo "${current_policies}" | jq -r --arg PREFIX "${PREFIX}" '.result | map(select(.name == $PREFIX)) | .[0].id')

# Build Condition Logic
conditions=()
if [[ ${#used_list_ids[@]} -eq 1 ]]; then
    conditions='
                "any": {
                    "in": {
                        "lhs": { "splat": "dns.domains" },
                        "rhs": "$'"${used_list_ids[0]}"'"
                    }
                }'
else
    for list_id in "${used_list_ids[@]}"; do
        conditions+=('{
                "any": {
                    "in": {
                        "lhs": { "splat": "dns.domains" },
                        "rhs": "$'"$list_id"'"
                    }
                }
        }')
    done
    conditions=$(IFS=','; echo "${conditions[*]}")
    conditions='"or": ['"$conditions"']'
fi

# JSON Payload for Policy
json_data='{
    "name": "'${PREFIX}'",
    "conditions": [ { "type":"traffic", "expression":{ '"$conditions"' } } ],
    "action":"block",
    "enabled":true,
    "rule_settings":{ "block_page_enabled":false }
}'

if [[ -z "${policy_id}" || "${policy_id}" == "null" ]]; then
    echo "Creating new Policy..."
    curl -sSfL --retry "$MAX_RETRIES" -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_data" > /dev/null || error "Failed to create policy"
else
    echo "Updating existing Policy..."
    curl -sSfL --retry "$MAX_RETRIES" -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_data" > /dev/null || error "Failed to update policy"
fi

# Cleanup old lists
for list_id in "${excess_list_ids[@]}"; do
    echo "Deleting excess list ${list_id}..."
    curl -sSfL --retry "$MAX_RETRIES" -X DELETE "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" > /dev/null
done

# Git Commit (Save state)
git config --global user.email "${GITHUB_ACTOR_ID}+${GITHUB_ACTOR}@users.noreply.github.com"
git config --global user.name "$(gh api /users/${GITHUB_ACTOR} | jq .name -r)"
git add oisd_small_domainswild2.txt
git commit -m "Update domains list [Auto]" --author=. || echo "::warning::No changes to commit"
git push origin main || echo "::warning::Failed to push changes"

echo "Success!"
