#!/bin/bash
###
# Vault File Download Bash Script
# Requirements: bash, curl, jq, awk, xargs
#
# This script downloads a file from the DBpedia Vault using a Keycloak offline token.
# All configuration is via environment variables (see README for details).
###

SCRIPT_VERSION="2025-07-24"
USER_AGENT="Vault File Download Bash Script $SCRIPT_VERSION"

# All variables can be set via environment, fallback to defaults
DOWNLOAD_URL="${DOWNLOAD_URL:-https://data.dbpedia.io/databus.dbpedia.org/dbpedia-enterprise/sneak-preview/fusion/2025-07-17/fusion_subjectns%3Ddbpedia-io_vocab%3Ddbo_props%3DwikipageUsesTemplate.ttl.gz}"
REFRESH_TOKEN_FILE="${REFRESH_TOKEN_FILE:-vault-token.dat}"
AUTH_URL="${AUTH_URL:-https://auth.dbpedia.org/realms/dbpedia/protocol/openid-connect/token}"
CLIENT_ID="${CLIENT_ID:-vault-token-exchange}"
DEBUG="${DEBUG:-true}"

# Check for required tools
for tool in curl jq awk xargs; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: Required tool '$tool' is not installed or not in PATH." >&2
        exit 2
    fi
done

# Use REFRESH_TOKEN env variable if set, otherwise read token from file
if [ -n "$REFRESH_TOKEN" ]; then
    refresh_token="$REFRESH_TOKEN"
    refresh_token_source="environment variable REFRESH_TOKEN"
else
    if [ ! -f "$REFRESH_TOKEN_FILE" ]; then
        echo "Error: Token file '$REFRESH_TOKEN_FILE' does not exist." >&2
        exit 1
    fi
    refresh_token=$(cat "$REFRESH_TOKEN_FILE")
    refresh_token_source="file $REFRESH_TOKEN_FILE"
    if [ ${#refresh_token} -lt 80 ]; then # This is a heuristic to ensure the token is likely valid
        echo "Warning: Token read from '$refresh_token_source' is less than 80 characters." >&2
    fi
fi

# Getting the Keycloak audience/target client for exchange from DOWNLOAD_URL == FQDN
VAULT_CLIENT_ID="${VAULT_CLIENT_ID:-$(echo "$DOWNLOAD_URL" | awk -F/ '{print $3}') }"
# Trim whitespace/newlines from VAULT_CLIENT_ID
VAULT_CLIENT_ID="$(echo "$VAULT_CLIENT_ID" | xargs)"

# Print debug information
if [ "$DEBUG" = "true" ]; then
    echo "Debug mode is ON"
    echo "Attempting to download file: $DOWNLOAD_URL"
    echo "DBpedia Auth Keycloak URL: $AUTH_URL"
    echo "Token exchange client ID: $CLIENT_ID"
    echo "Vault client ID: $VAULT_CLIENT_ID"
    echo "Refresh token source: $refresh_token_source"
fi

# Suppresses progress meter and most output, only errors and response are shown
if [ "$DEBUG" = "true" ]; then
    curl_print_opts=()
else
    curl_print_opts=(--silent --show-error)
fi

# Get access token to be exchanged for the vault token later
response=$(curl "${curl_print_opts[@]}" --location "$AUTH_URL" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --header "User-Agent: $USER_AGENT" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode 'grant_type=refresh_token' \
    --data-urlencode "refresh_token=$refresh_token")

access_token=$(echo "$response" | jq -r '.access_token')

# Print access token response if debug is enabled
if [ "$DEBUG" = "true" ]; then
    echo -e "\nAccess Token response: $response"
fi

# Exchange access token for vault
response=$(curl "${curl_print_opts[@]}" --location "$AUTH_URL" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --header "User-Agent: $USER_AGENT" \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    --data-urlencode "subject_token=$access_token" \
    --data-urlencode "audience=$VAULT_CLIENT_ID" \
    --data-urlencode "client_id=$CLIENT_ID")

vault_access_token=$(echo "$response" | jq -r '.access_token')
# Print token exchange response if debug is enabled
if [ "$DEBUG" = "true" ]; then
    echo -e "\nToken exchange response: $response"
fi

# Download file
curl --location "$DOWNLOAD_URL" -O --header "Authorization: Bearer $vault_access_token" --header "User-Agent: $USER_AGENT" # agent optional: for usage tracking

status=$?
# Print download result if debug is enabled
if [ "$DEBUG" = "true" ]; then
    if [ $status -eq 0 ]; then
        echo "Download completed successfully: $DOWNLOAD_URL"
    else
        echo "Download failed with exit code $status" >&2
    fi
fi
if [ $status -ne 0 ]; then
    exit $status
fi
