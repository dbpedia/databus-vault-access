#!/usr/bin/env bash
set -euo pipefail

# databus_fetch.sh
#
# Downloads assets from DBpedia Databus given a Databus IRI.
# Supported Databus IRI currently
#   - Artifact IRI: https://<databus-host>/<user>/<group>/<artifact>
#       → downloads latest version (default) or the one specified via --version <literal>
#   - Version IRI:  https://<databus-host>/<user>/<group>/<artifact>/<version>
#       → downloads exactly that version of an artifact
#   - File IRI:     https://<databus-host>/<user>/<group>/<artifact>/<version>/<fileName>
#       → downloads only that file, planned is a version override later that downloads e.g. latest version of a file
#
# Files are placed in: <output-dir>/<user>/<group>/<artifact>/<version>/
#
# Vault storage detection:
#   Databus file IRIs redirect to Vault storage (data.dbpedia.io, data.dev.dbpedia.link).
#   Vault downloads require ./download_file_from_vault.sh (with DOWNLOAD_URL set).
#   Non-vault URLs are fetched directly with curl.
#
# CLI options:
#   --version latest|<literal>   Currently only affects artifact IRI input (default: latest); planned is a version override later that downloads e.g. latest version of a specific file or approximate date
#   --sparql-endpoint URL|auto   Manual SPARQL endpoint override (default: auto, derived from Databus host)
#   --dry-run                    Resolve but don’t download
#   --debug                      Verbose execution
#   --output-dir DIR             Output directory (default: current)
#   --continue-on-error          Continue downloading other files even if one fails (default: fail on error)
#
# Dependencies:
#   - bash, curl, awk, sed
#   - ./download_file_from_vault.sh (for vault downloads)

# Check for required tools
for tool in curl awk sed; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: Required tool '$tool' is not installed or not in PATH." >&2
        exit 2
    fi
done

VAULT_HOSTS=("data.dbpedia.io" "data.dev.dbpedia.link")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_HELPER="$SCRIPT_DIR/download_file_from_vault.sh"

# ---------------- CLI ----------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <databus-iri> [--version latest|YYYY-MM-DD] [--sparql-endpoint URL|auto] [--dry-run] [--debug] [--output-dir DIR] [--continue-on-error]" >&2
  exit 2
fi

INPUT_IRI="$1"; shift || true
VERSION_SELECTOR="latest"          # “selector”, only used if INPUT is artifact IRI
SPARQL_ENDPOINT_OVERRIDE=""
DRY_RUN="false"
DEBUG="false"
OUTPUT_DIR="."
FAIL_ON_ERROR="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION_SELECTOR="$2"; shift 2;;
    --sparql-endpoint) SPARQL_ENDPOINT_OVERRIDE="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift;;
    --debug) DEBUG="true"; shift;;
    --output-dir | --ouput-dir) OUTPUT_DIR="$2"; shift 2;;
    --continue-on-error) FAIL_ON_ERROR="false"; shift;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done
[[ "$DEBUG" == "true" ]] && set -x

# ---------------- Utility functions ----------------

# split_url <url>
#   Splits <url> into host and path (without scheme).
#   Prints "host<TAB>path".
split_url() {
  local url="$1"
  local host path
  host="$(printf '%s\n' "$url" | awk -F'//' '{print $2}' | cut -d'/' -f1)"
  path="$(printf '%s\n' "$url" | awk -F'//' '{print $2}' | cut -d'/' -f2-)"
  printf '%s\t%s\n' "$host" "$path"
}

# derive_sparql_endpoint
#   Derives the SPARQL endpoint from the INPUT_IRI’s host.
#   Example: INPUT_IRI=https://databus.dbpedia.org/... → https://databus.dbpedia.org/sparql
derive_sparql_endpoint() {
  local scheme host
  scheme="$(printf '%s' "$INPUT_IRI" | awk -F'://' '{print $1}')"
  [[ -z "$scheme" ]] && scheme="https"
  IFS=$'\t' read -r host _ <<<"$(split_url "$INPUT_IRI")"
  printf '%s://%s/sparql\n' "$scheme" "$host"
}

# is_vault_host <hostname>
#   Checks if <hostname> is one of the known Vault storage hosts.
#   Returns 0 (true) if yes, 1 otherwise.
is_vault_host() {
  local host="$1"
  for v in "${VAULT_HOSTS[@]}"; do [[ "$host" == "$v" ]] && return 0; done
  return 1
}

# escape_sparql_literal <string>
#   Escapes <string> for safe use as a SPARQL literal.
escape_sparql_literal() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# run_sparql_query <endpoint> <sparql>
#   Executes <sparql> against <endpoint>.
#   Prints the result in TSV format.
run_sparql_query() {
  local endpoint="$1" query="$2"
  curl -fsSL -X POST -H 'Accept: text/tab-separated-values' \
       --data-urlencode "query=$query" "$endpoint"
}

# resolve_final_url <url>
#   Follows HTTP redirects and prints the final effective URL.
resolve_final_url() {
  curl -sSL -o /dev/null -w '%{url_effective}\n' "$1"
}

# parse_artifact_segments <artifact-iri>
#   Splits an artifact IRI into user, group, artifact segments.
#   Prints "user<TAB>group<TAB>artifact".
parse_artifact_segments() {
  local iri="$1"
  local path
  path="$(printf '%s\n' "$iri" | awk -F'//' '{print $2}' | cut -d'/' -f2-)"
  local user group artifact
  user="$(printf '%s' "$path" | cut -d'/' -f1)"
  group="$(printf '%s' "$path" | cut -d'/' -f2)"
  artifact="$(printf '%s' "$path" | cut -d'/' -f3)"
  printf '%s\t%s\t%s\n' "$user" "$group" "$artifact"
}

# ---------------- SPARQL query builders ----------------

# build_files_for_artifact_version <artifact-iri> <version-literal>
#   Builds a query to select all files of <artifact-iri> with given <version-literal>.
build_files_for_artifact_version() {
  local art="$1" ver="$(escape_sparql_literal "$2")"
  cat <<EOF
PREFIX dcat:   <http://www.w3.org/ns/dcat#>
PREFIX dct:    <http://purl.org/dc/terms/>
PREFIX databus:<https://dataid.dbpedia.org/databus#>
SELECT ?file WHERE {
  GRAPH ?g {
    ?dataset databus:artifact <${art}> .
    ?dataset dcat:distribution ?dist .
    ?dist dct:hasVersion "${ver}" .
    ?dist databus:file ?file .
  }
}
ORDER BY STR(?file)
EOF
}

# build_files_for_artifact_latest <artifact-iri>
#   Builds a query to select all files of the latest version of <artifact-iri>.
build_files_for_artifact_latest() {
  local art="$1"
  cat <<EOF
PREFIX dcat:   <http://www.w3.org/ns/dcat#>
PREFIX dct:    <http://purl.org/dc/terms/>
PREFIX databus:<https://dataid.dbpedia.org/databus#>
SELECT ?file WHERE {
  GRAPH ?g {
    ?dataset databus:artifact <${art}> .
    {
      SELECT ?dataset (STR(?v) AS ?latestVersionLiteral) {
        GRAPH ?g2 { ?dataset databus:artifact <${art}> . ?dataset dct:hasVersion ?v . }
      } ORDER BY DESC(?latestVersionLiteral) LIMIT 1
    }
    ?dataset dcat:distribution ?dist .
    ?dist dct:hasVersion ?latestVersionLiteral .
    ?dist databus:file ?file .
  }
}
ORDER BY STR(?file)
EOF
}

# build_latest_version_literal <artifact-iri>
#   Builds a query to get the latest version literal of <artifact-iri>.
build_latest_version_literal() {
  local art="$1"
  cat <<EOF
PREFIX dct:    <http://purl.org/dc/terms/>
PREFIX databus:<https://dataid.dbpedia.org/databus#>
SELECT (STR(?v) AS ?latest) WHERE {
  GRAPH ?g { ?dataset databus:artifact <${art}> . ?dataset dct:hasVersion ?v . }
}
ORDER BY DESC(?latest) LIMIT 1
EOF
}

# build_backlink_from_file <file-iri>
#   Builds a query to get artifact IRI and version literal for <file-iri>.
build_backlink_from_file() {
  local file="$1"
  cat <<EOF
PREFIX dct:    <http://purl.org/dc/terms/>
PREFIX dcat:   <http://www.w3.org/ns/dcat#>
PREFIX databus:<https://dataid.dbpedia.org/databus#>
SELECT ?artifact ?version WHERE {
  GRAPH ?g {
    ?dataset dcat:distribution ?dist .
    ?dist databus:file <${file}> .
    ?dataset databus:artifact ?artifact .
    ?dist dct:hasVersion ?version .
  }
} LIMIT 1
EOF
}

# ---------------- Main logic ----------------

SPARQL_ENDPOINT="${SPARQL_ENDPOINT_OVERRIDE:-auto}"
endpoint=""
if [[ "$SPARQL_ENDPOINT" == "auto" ]]; then
  endpoint="$(derive_sparql_endpoint)"
else
  endpoint="$SPARQL_ENDPOINT"
fi

IFS=$'\t' read -r host path <<<"$(split_url "$INPUT_IRI")"
[[ "$DEBUG" == "true" ]] && echo "[DEBUG] Extracted Databus hostname: '$host', path: '$path'" 
if [[ -z "$host" ]]; then
  echo "ERROR: Could not extract host from input IRI: $INPUT_IRI" >&2
  exit 2
fi

IFS='/' read -r -a seg <<<"$path"
(( ${#seg[@]} >= 3 )) || { echo "ERROR: path too short. Need at least /<user>/<group>/<artifact>[...]."; exit 2; }

user="${seg[0]}"; group="${seg[1]}"; artifact="${seg[2]}"
artifact_iri="https://$host/$user/$group/$artifact"

mode=""               # artifact | version | file
if   (( ${#seg[@]} == 3 )); then mode="artifact"
elif (( ${#seg[@]} == 4 )); then mode="version"
else                               mode="file"
fi

declare -a file_urls
version_literal=""

case "$mode" in
  artifact)
    if [[ "$VERSION_SELECTOR" == "latest" ]]; then
      tsv_files="$(run_sparql_query "$endpoint" "$(build_files_for_artifact_latest "$artifact_iri")")"
      mapfile -t file_urls < <(printf '%s\n' "$tsv_files" | tail -n +2 | awk -F'\t' '{print $1}' | sed 's/^<//' | sed 's/>$//' | sed '/^\s*$/d')
      tsv_ver="$(run_sparql_query "$endpoint" "$(build_latest_version_literal "$artifact_iri")")"
      version_literal="$(printf '%s\n' "$tsv_ver" | tail -n +2 | awk -F'\t' 'NR==1{print $1}' | sed 's/^"//' | sed 's/"$//')"
    else
      version_literal="$VERSION_SELECTOR"
      tsv_files="$(run_sparql_query "$endpoint" "$(build_files_for_artifact_version "$artifact_iri" "$version_literal")")"
      mapfile -t file_urls < <(printf '%s\n' "$tsv_files" | tail -n +2 | awk -F'\t' '{print $1}' | sed 's/^<//' | sed 's/>$//' | sed '/^\s*$/d')
    fi
    ;;
  version)
    version_literal="${seg[3]}"
    tsv_files="$(run_sparql_query "$endpoint" "$(build_files_for_artifact_version "$artifact_iri" "$version_literal")")"
    mapfile -t file_urls < <(printf '%s\n' "$tsv_files" | tail -n +2 | awk -F'\t' '{print $1}' | sed 's/^<//' | sed 's/>$//' | sed '/^\s*$/d')
    ;;
  file)
    file_iri="$INPUT_IRI"
    tsv_bl="$(run_sparql_query "$endpoint" "$(build_backlink_from_file "$file_iri")" || true)"
    artifact_iri="$(printf '%s\n' "$tsv_bl" | tail -n +2 | awk -F'\t' 'NR==1{print $1}' | sed 's/^<//' | sed 's/>$//')"
    version_literal="$(printf '%s\n' "$tsv_bl" | tail -n +2 | awk -F'\t' 'NR==1{print $2}' | sed 's/^"//' | sed 's/"$//')"
    file_urls=("$file_iri")
    ;;
esac

(( ${#file_urls[@]} > 0 )) || { echo "No files resolved."; exit 1; }
[[ -n "$version_literal" ]] || { echo "ERROR: could not determine version literal."; exit 1; }

dest_dir="${OUTPUT_DIR}/${user}/${group}/${artifact}/${version_literal}"
mkdir -p "$dest_dir"


echo "---> Resolved ${#file_urls[@]} files from Databus to download into $dest_dir"
file_counter=0
failed_files=()
success_count=0
failure_count=0

# If continue-on-error, disable errexit during download loop; restore afterwards
restore_errexit=""
if [[ "$FAIL_ON_ERROR" == "false" ]]; then
  # remember previous -e state (bash specific)
  [[ $- == *e* ]] && restore_errexit="set -e" || restore_errexit=":"
  set +e
fi

for file_url in "${file_urls[@]}"; do
  echo "------> downloading file $((++file_counter))/${#file_urls[@]}: $file_url"
  [[ "$DRY_RUN" == "true" ]] && continue

  download_success=false

  # Workaround: Check the first redirect location with a robust, non-fatal probe
  first_redirect_url="$(curl -s -I "$file_url" | awk 'tolower($1)=="location:"{print $2; exit}' | tr -d $'\r')"
  if [[ -n "$first_redirect_url" ]]; then
    first_host="$(printf '%s\n' "$first_redirect_url" | awk -F'//' '{print $2}' | cut -d'/' -f1)"
    if is_vault_host "$first_host"; then
      [[ -x "$DOWNLOAD_HELPER" ]] || { echo "ERROR: $DOWNLOAD_HELPER required for Vault downloads."; exit 2; }
      if ( cd "$dest_dir" && DEBUG=false DOWNLOAD_URL="$first_redirect_url" "$DOWNLOAD_HELPER" ); then
        download_success=true
        ((success_count++))
      else
        vault_status=$?
        ((failure_count++))
        failed_files+=("$file_url")
        if [[ "$FAIL_ON_ERROR" == "true" ]]; then
          echo "ERROR: Vault download failed for $file_url (exit code: $vault_status)"
          exit 1
        else
          echo "WARNING: Vault download failed for $file_url (exit code: $vault_status), continuing..."
        fi
      fi
      continue
    fi
  fi

  # Not vault or no redirect, follow redirects with curl (guarded by if to cooperate with set -e)
  if ( cd "$dest_dir" && curl -fL -O "$file_url" ); then
    download_success=true
    ((success_count++))
  else
    curl_status=$?
    ((failure_count++))
    failed_files+=("$file_url")
    if [[ "$FAIL_ON_ERROR" == "true" ]]; then
      echo "ERROR: Download failed for $file_url (curl exit code: $curl_status)"
      exit 1
    else
      echo "WARNING: Download failed for $file_url (curl exit code: $curl_status), continuing..."
    fi
  fi
done

# Restore errexit if we disabled it for continue-on-error
[[ -n "$restore_errexit" ]] && eval "$restore_errexit"

echo "---> Completed downloading $success_count successful and $failure_count failed file(s) into $dest_dir"
if (( failure_count > 0 )); then
  echo "Failed files ($failure_count): ${failed_files[*]}"
fi