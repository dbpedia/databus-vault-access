#!/usr/bin/env bash
set -uo pipefail
# NOTE: We intentionally do NOT use `set -e` globally because it can cause silent exits
# inside command substitutions or pipelines. We handle all errors explicitly instead.

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
#   --debug                      Output useful diagnostics (NO shell trace)
#   --output-dir DIR             Output directory (default: current)
#   --continue-on-error          Continue downloading other files even if one fails (default: fail on error)
#
# Dependencies:
#   - bash, curl, awk, sed
#   - ./download_file_from_vault.sh (for vault downloads)

# ---------- Debug helper (no 'set -x' spam) ----------
DEBUG="false"
log_debug() { [[ "$DEBUG" == "true" ]] && printf '[DEBUG] %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Check for required tools
for tool in curl awk sed; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "Required tool '$tool' is not installed or not in PATH."
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
OUTPUT_DIR="."
FAIL_ON_ERROR="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION_SELECTOR="$2"; shift 2;;
    --sparql-endpoint) SPARQL_ENDPOINT_OVERRIDE="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift;;
    --debug) DEBUG="true"; shift;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    --continue-on-error) FAIL_ON_ERROR="false"; shift;;
    *) die "Unknown arg: $1";;
  esac
done

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
#   Prints the result in TSV format (or empty on no results).
run_sparql_query() {
  local endpoint="$1" query="$2"
  log_debug "POST SPARQL to $endpoint"
  curl -sS -X POST -H 'Accept: text/tab-separated-values' \
       --data-urlencode "query=$query" "$endpoint"
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
if [[ "$SPARQL_ENDPOINT" == "auto" ]]; then
  SPARQL_ENDPOINT="$(derive_sparql_endpoint)"
fi
log_debug "Derived SPARQL endpoint: $SPARQL_ENDPOINT"

IFS=$'\t' read -r host path <<<"$(split_url "$INPUT_IRI")"
log_debug "Input host='$host' path='$path'"
[[ -n "$host" ]] || die "Could not extract host from input IRI: $INPUT_IRI"

IFS='/' read -r -a seg <<<"$path"
(( ${#seg[@]} >= 3 )) || die "path too short. Need at least /<user>/<group>/<artifact>[...]."

user="${seg[0]}"; group="${seg[1]}"; artifact="${seg[2]}"
artifact_iri="https://$host/$user/$group/$artifact"
log_debug "Artifact IRI: $artifact_iri"

mode=""               # artifact | version | file
if   (( ${#seg[@]} == 3 )); then mode="artifact"
elif (( ${#seg[@]} == 4 )); then mode="version"
else                               mode="file"
fi
log_debug "Input mode detected: $mode"

declare -a file_urls=()
version_literal=""

# Safe SPARQL capture wrapper: no global -e, but check rc and show diagnostics in --debug
safe_sparql_capture() {
  # $1: var name to fill; $2: SPARQL query string
  local __outvar="$1" __query="$2" __tmp __rc
  __tmp="$(mktemp)"
  run_sparql_query "$SPARQL_ENDPOINT" "$__query" >"$__tmp"
  __rc=$?
  if [[ $__rc -ne 0 ]]; then
    echo "ERROR: SPARQL request failed (endpoint: $SPARQL_ENDPOINT, rc: $__rc)." >&2
    if [[ "$DEBUG" == "true" ]]; then
      echo "----- SPARQL QUERY BEGIN -----" >&2
      printf '%s\n' "$__query" >&2
      echo "----- SPARQL QUERY END -----" >&2
      if [[ -s "$__tmp" ]]; then
        echo "----- PARTIAL RESPONSE BEGIN -----" >&2
        head -200 "$__tmp" >&2
        echo "----- PARTIAL RESPONSE END -----" >&2
      fi
    fi
    rm -f "$__tmp"
    exit 1
  fi
  # Fill the referenced variable with the whole file content
  local __content
  __content="$(cat "$__tmp")"
  rm -f "$__tmp"
  # shellcheck disable=SC2163
  printf -v "$__outvar" '%s' "$__content"
}

case "$mode" in
  artifact)
    if [[ "$VERSION_SELECTOR" == "latest" ]]; then
      q1="$(build_files_for_artifact_latest "$artifact_iri")"
      tsv_files=""
      safe_sparql_capture tsv_files "$q1"
      mapfile -t file_urls < <(printf '%s\n' "$tsv_files" | tail -n +2 | awk -F'\t' '{print $1}' | sed 's/^<//' | sed 's/>$//' | sed 's/\r$//' | sed '/^\s*$/d')
      q2="$(build_latest_version_literal "$artifact_iri")"
      tsv_ver=""
      safe_sparql_capture tsv_ver "$q2"
      version_literal="$(printf '%s\n' "$tsv_ver" | tail -n +2 | awk -F'\t' 'NR==1{print $1}' | sed 's/^"//' | sed 's/"$//' | sed 's/\r$//')"
    else
      version_literal="$VERSION_SELECTOR"
      q3="$(build_files_for_artifact_version "$artifact_iri" "$version_literal")"
      tsv_files=""
      safe_sparql_capture tsv_files "$q3"
      mapfile -t file_urls < <(printf '%s\n' "$tsv_files" | tail -n +2 | awk -F'\t' '{print $1}' | sed 's/^<//' | sed 's/>$//' | sed 's/\r$//' | sed '/^\s*$/d')
    fi
    ;;
  version)
    version_literal="${seg[3]}"
    q4="$(build_files_for_artifact_version "$artifact_iri" "$version_literal")"
    tsv_files=""
    safe_sparql_capture tsv_files "$q4"
    mapfile -t file_urls < <(printf '%s\n' "$tsv_files" | tail -n +2 | awk -F'\t' '{print $1}' | sed 's/^<//' | sed 's/>$//' | sed 's/\r$//' | sed '/^\s*$/d')
    ;;
  file)
    file_iri="$INPUT_IRI"
    q5="$(build_backlink_from_file "$file_iri")"
    tsv_bl=""
    # Backlink may fail if graph not present; treat as soft failure (still download the file URL).
    run_sparql_query "$SPARQL_ENDPOINT" "$q5" >/dev/null 2>&1 && safe_sparql_capture tsv_bl "$q5" || true
    if [[ -n "$tsv_bl" ]]; then
      artifact_iri="$(printf '%s\n' "$tsv_bl" | tail -n +2 | awk -F'\t' 'NR==1{print $1}' | sed 's/^<//' | sed 's/>$//')"
      version_literal="$(printf '%s\n' "$tsv_bl" | tail -n +2 | awk -F'\t' 'NR==1{print $2}' | sed 's/^"//' | sed 's/"$//')"
    fi
    file_urls+=("$file_iri")
    ;;
esac

(( ${#file_urls[@]} > 0 )) || die "No files resolved."
[[ -n "$version_literal" ]] || die "could not determine version literal."

dest_dir="${OUTPUT_DIR}/${user}/${group}/${artifact}/${version_literal}"
mkdir -p "$dest_dir" || die "cannot create directory: $dest_dir"

echo "---> Resolved ${#file_urls[@]} files from Databus to download into $dest_dir"
for u in "${file_urls[@]}"; do echo "       • $u"; done
log_debug "Version literal: $version_literal"

file_counter=0
failed_files=()
success_count=0
failure_count=0

# Download loop. Abort on first error unless --continue-on-error was passed.
for file_url in "${file_urls[@]}"; do
  echo "------> downloading file $((++file_counter))/${#file_urls[@]}: $file_url"
  [[ "$DRY_RUN" == "true" ]] && continue

  # First redirect probe (non-fatal)
  first_redirect_url=""
  tmp_headers="$(mktemp)"
  curl -sS -I "$file_url" -o "$tmp_headers" 2>/dev/null
  if [[ -s "$tmp_headers" ]]; then
    first_redirect_url="$(awk 'tolower($1)=="location:"{print $2; exit}' "$tmp_headers" | tr -d $'\r')"
  fi
  rm -f "$tmp_headers"
  log_debug "first_redirect_url='${first_redirect_url:-<none>}'"

  if [[ -n "$first_redirect_url" ]]; then
    first_host="$(printf '%s\n' "$first_redirect_url" | awk -F'//' '{print $2}' | cut -d'/' -f1)"
    if is_vault_host "$first_host"; then
      if [[ ! -x "$DOWNLOAD_HELPER" ]]; then
        echo "ERROR: $DOWNLOAD_HELPER required for Vault downloads." >&2
        if [[ "$FAIL_ON_ERROR" == "true" ]]; then exit 2; else ((failure_count++)); failed_files+=("$file_url"); echo "WARNING: Missing vault helper, continuing..."; continue; fi
      fi
      log_debug "vault helper: DOWNLOAD_URL='$first_redirect_url' dest_dir='$dest_dir'"
      DEBUG=false DOWNLOAD_URL="$first_redirect_url" DOWNLOAD_OUTPUT_DIR="$dest_dir" "$DOWNLOAD_HELPER"
      vault_rc=$?
      if [[ $vault_rc -eq 0 ]]; then
        ((success_count++))
      else
        ((failure_count++)); failed_files+=("$file_url")
        if [[ "$FAIL_ON_ERROR" == "true" ]]; then echo "ERROR: Vault download failed for $file_url (exit code: $vault_rc)"; exit 1; else echo "WARNING: Vault download failed for $file_url (exit code: $vault_rc), continuing..."; fi
      fi
      continue
    fi
  fi

  # Non-vault (or no redirect): follow redirects with curl
  curl -fL -o "$dest_dir/$(basename "$file_url")" "$file_url"
  curl_rc=$?
  if [[ $curl_rc -eq 0 ]]; then
    ((success_count++))
  else
    ((failure_count++)); failed_files+=("$file_url")
    if [[ "$FAIL_ON_ERROR" == "true" ]]; then echo "ERROR: Download failed for $file_url (curl exit code: $curl_rc). Please check Vault Token configuration. ABORTING DOWNLOAD!"; exit 1; else echo "WARNING: Download failed for $file_url (curl exit code: $curl_rc). Please check Vault Token configuration. Continuing with remaining files..."; fi
  fi
done

echo "---> Completed downloading $success_count successful and $failure_count failed file(s) into $dest_dir"
if (( failure_count > 0 )); then
  echo "Failed files ($failure_count):"
  for f in "${failed_files[@]}"; do echo "  - $f"; done
fi
