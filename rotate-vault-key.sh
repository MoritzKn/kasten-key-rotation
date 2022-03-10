#!/usr/bin/env bash

set -e
set -o pipefail

escape_sed() {
  echo $1 | sed -e 's/[\/&]/\\&/g'
}

log_file="$(mktemp)"
on_error() {
    echo " > Failed!"
    cat $log_file
    exit 1
}

log_cmd() {
  echo " >" "$@" >&2
  "$@" > $log_file 2>&1 || on_error
}

log_cmd_pipe() {
  echo " >" "$@" >&2
  "$@"
}

passkey_file="$1"

if [ ! -f "$passkey_file" ]; then
    echo "No such file: '$passkey_file'"
    echo "Ussage: ./rotate-vault-key.sh passkey.yaml"
    exit 1
fi

vault_cmd=$VAULT_CMD
if [ -z "$vault_cmd" ]; then
    vault_cmd="vault"
fi

echo "* Checking Vault connection..."
if $vault_cmd status > /dev/null; then
    # echo "Connected to Vault!"
    # Do not do anything
    true
else
    echo " - Can not connect to Vault!"
    echo " - Failed to run \$VAULT_CMD:"
    echo " - $vault_cmd status"
    exit 1
fi

passkey_json_file_temp="$(mktemp)"
kubectl create -f $passkey_file --dry-run=client -o json > $passkey_json_file_temp

vault_transit_path=$(jq .spec.vaulttransitpath -r < $passkey_json_file_temp)
vault_key_name=$(jq .spec.vaulttransitkeyname -r < $passkey_json_file_temp)
passkey_name_old=$(jq .metadata.name -r < $passkey_json_file_temp)
rm $passkey_json_file_temp

if [ "$vault_transit_path" = "null" ]; then
    echo "  - Error: No '.spec.vaulttransitpath' found in $passkey_file"
    exit 1
fi
if [ "$vault_key_name" = "null" ]; then
    echo "  - Error: No '.spec.vaulttransitkeyname' found in $passkey_file"
    exit 1
fi

vault_min_decryption_version=$($vault_cmd read $vault_transit_path/keys/$vault_key_name -format=json | jq .data.min_decryption_version)
echo "* Min decryption version was: $vault_min_decryption_version"

echo "* Rotating key..."
log_cmd $vault_cmd write -f  $vault_transit_path/keys/$vault_key_name/rotate
vault_key_latest_version=$($vault_cmd read $vault_transit_path/keys/$vault_key_name -format=json | jq .data.latest_version)
echo "* New version is: $vault_key_latest_version"

passkey_name_new=
if echo $passkey_name_old | grep -E -- '_v[0-9]+' > /dev/null; then
    last_version=$(echo $passkey_name_old | grep -o -E -- '_v[0-9]+')
    new_version="_v$vault_key_latest_version"
    passkey_name_new=$(echo $passkey_name_old | sed "s/$(escape_sed $last_version)/$(escape_sed $new_version)"/)
else
    passkey_name_new="${passkey_name_old}_v$vault_key_latest_version"
fi

echo "* Renaming Passkey: $passkey_name_old -> $passkey_name_new"
new_passkey_file="$(mktemp)"
log_cmd_pipe sed "s/$(escape_sed $passkey_name_old)/$(escape_sed $passkey_name_new)/" $passkey_file > $new_passkey_file
log_cmd mv $new_passkey_file $passkey_file

echo "* Updating Passkey..."
log_cmd kubectl create -f $passkey_file

echo "* Checking key..."
status_file_temp=$(mktemp)
passkey_is_inuse=false
for i in 1 2 3 4 5; do
    log_cmd_pipe kubectl get passkeys.vault.kio.kasten.io $passkey_name_new -o json > $status_file_temp
    passkey_is_inuse=$(jq .status.inuse < $status_file_temp)
    if [ "$passkey_is_inuse" = "true" ]; then
        echo " - The used Passkey now is '$passkey_name_new'"
        break
    fi
    echo " - Not yet inuse, trying again in 1 second..."
    sleep 1
done
rm $status_file_temp

if [ "$passkey_is_inuse" != "true" ]; then
    echo " - Error: Passkey '$passkey_name_new' still not active after 5 tries"
    exit 1
fi

echo "* Setting min decryption version to: $vault_key_latest_version"
log_cmd $vault_cmd write $vault_transit_path/keys/$vault_key_name/config min_decryption_version=$vault_key_latest_version

echo "* Deleting the old Passkey"
log_cmd kubectl delete passkeys.vault.kio.kasten.io $passkey_name_old

rm $log_file
