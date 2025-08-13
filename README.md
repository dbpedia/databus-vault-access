# DBpedia Databus Vault Access
Code to programmatically access the DBpedia Databus Vaults via the DBpedia Unified Account

## Roadmap
At the moment, there is only a minimal bash script. Later more utility will be added like parallel downloads, different programming languages like Python/Scala. If you are a developer, it can help you to implement your own download code or use ChatGPT. 


## Bash Usage: download_file_from_vault.sh
Script to authorize towards a DBpedia Vault to download files.

### Step 1: Getting the access (refresh) token 
1. If you do not have a DBpedia Account yet (Forum/Databus), please register at https://account.dbpedia.org  
2. Login at https://account.dbpedia.org and create your token.
3. Save the token to a file `vault-token.dat`.

**Security considerations**: The token that will be issued for your account is similar to an API key and is valid for a long period of time (months). Anybody who has access to this token can perform actions "on behalf" of you in particular download private data on DBpedia Vaults to which you have access. If you are working in a shared environment, please consider to delete the token file after use. **If you know that your token is compromised, contact DBpedia to invalidate your token and get a new one. **

### Step 2: Download and prepare the script
1. Make sure that `download_file_from_vault.sh` is in the same directory as `vault-token.dat` and that `chmod u+x download_file_from_vault.sh` is set:
```
ls -ls
8 -rwxrw-r-- 1 kurzum kurzum 4214 Aug  7 15:59 download_file_from_vault.sh
4 -rw-rw-r-- 1 kurzum kurzum  682 Aug  7 15:58 vault-token.dat
```
2. Make sure the necessary libraries are installed (see header in `download_file_from_vault.sh`)
3. (optional) the script provides parameters to change the file name, i.e. `REFRESH_TOKEN_FILE=someothertokenfile.dat` as well as pass the token directly `REFRESH_TOKEN=1234yourtoken`.

### Step 3: (Optional) test run
```bash 
./download_file_from_vault.sh
```
Should download a test file.  

### Step 4: Download Data
Specify the download file URL by setting the environment variable `DOWNLOAD_URL` to the desired URL before running the script:

```bash 
DOWNLOAD_URL="https://data.dbpedia.io/databus.dbpedia.org/dbpedia-enterprise/sneak-preview/fusion/2025-07-17/fusion_subjectns%3Ddbpedia-io_vocab%3Drdf_props%3Dtype.ttl.gz" ./download_file_from_vault.sh
```

## Environment Variables

The following environment variables can be set to control the behavior of the download script:

| Variable            | Description                                                                                         | Default Value                                                                 |
|---------------------|-----------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| `DOWNLOAD_URL`      | The URL of the file to download from the DBpedia Vault.                                              | Example DBpedia file URL                                                      |
| `REFRESH_TOKEN`     | The (refresh) token to use for authentication. If not set, the script reads from file.       | (not set)                                                                     |
| `REFRESH_TOKEN_FILE`| Path to the file containing the offline (refresh) token. Used if `REFRESH_TOKEN` is not set.         | `vault-token.dat`                                                           |
| `AUTH_URL`          | The Keycloak token endpoint URL.                                                                    | `https://auth.dbpedia.org/realms/dbpedia/protocol/openid-connect/token`       |
| `CLIENT_ID`         | The Keycloak client ID to use for token exchange.                                                   | `vault-token-exchange`                                                        |
| `VAULT_CLIENT_ID`   | The audience/target client for token exchange. If not set, derived from the FQDN of `DOWNLOAD_URL`. | FQDN from `DOWNLOAD_URL`                                                      |
| `DEBUG`             | If set to `true`, enables debug output and disables curl silent mode.                               | `true`                                                                        |

You can set these variables in your shell before running the script, for example:

```bash
export DEBUG=false
DOWNLOAD_URL="https://data.dbpedia.io/databus.dbpedia.org/dbpedia-enterprise/dev/fusion-sneak-preview/2025-04-24-BETA/commons.wikimedia.org.nt.gz"./download_file_from_vault.sh
```



