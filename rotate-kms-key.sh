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
    echo "Ussage: ./rotate-kms-key.sh passkey.yaml"
    exit 1
fi

passkey_json_file_temp="$(mktemp)"
kubectl create -f $passkey_file --dry-run=client -o json > $passkey_json_file_temp

passkey_kms_key_id=$(jq .spec.awscmkkeyid -r < $passkey_json_file_temp)
passkey_name_old=$(jq .metadata.name -r < $passkey_json_file_temp)
rm $passkey_json_file_temp

if [ "$passkey_kms_key_id" = "null" ]; then
    echo "  - Error: No '.spec.awscmkkeyid' found in $passkey_file"
    exit 1
fi

echo "* Getting current key..."

key_info_file="$(mktemp)"
log_cmd_pipe aws kms describe-key --key-id "$passkey_kms_key_id" > $key_info_file;

# The passkey_kms_key_id might be an alias
kms_key_id=$(jq .KeyMetadata.KeyId -r < $key_info_file)

key_policy_file="$(mktemp)"
log_cmd_pipe aws kms get-key-policy --key-id $kms_key_id --policy-name default | jq .Policy -r > $key_policy_file

echo "* Createing new key..."

new_key_info_file="$(mktemp)"
log_cmd_pipe aws kms create-key \
    --description "$(jq .KeyMetadata.Description -r < $key_info_file)" \
    --key-usage "$(jq .KeyMetadata.KeyUsage -r < $key_info_file)" \
    --key-spec "$(jq .KeyMetadata.KeySpec -r < $key_info_file)" \
    --origin "$(jq .KeyMetadata.Origin -r < $key_info_file)" \
    "$(jq 'if .KeyMetadata.MultiRegion then "--multi-region" else "--no-multi-region" end' -r < $key_info_file)" \
    --policy "$(cat $key_policy_file)" \
    --tags "$(log_cmd_pipe aws kms list-resource-tags --key-id $kms_key_id | jq .Tags)" \
    > $new_key_info_file

new_kms_key_id=$(jq .KeyMetadata.KeyId -r < $new_key_info_file)
echo " - KeyId: $new_kms_key_id"

echo "* Rotating key..."

passkey_name_new=
if echo $passkey_name_old | grep -E -- '_v[0-9]+' > /dev/null; then
    last_version=$(echo $passkey_name_old | grep -o -E -- '_v[0-9]+')
    version_num=$(echo $last_version | grep -o -E -- '[0-9]+')
    new_version="_v$(($version_num + 1))"
    passkey_name_new=$(echo $passkey_name_old | sed "s/$(escape_sed $last_version)/$(escape_sed $new_version)"/)
else
    passkey_name_new="${passkey_name_old}_v1"
fi

echo "* Renaming Passkey: $passkey_name_old -> $passkey_name_new"
new_passkey_file="$(mktemp)"
log_cmd_pipe sed "s/$(escape_sed $passkey_name_old)/$(escape_sed $passkey_name_new)/" $passkey_file > $new_passkey_file
log_cmd mv $new_passkey_file $passkey_file

new_passkey_kms_key_id=$(jq .KeyMetadata.Arn -r < $new_key_info_file)
echo "* Changing Passkey awscmkkeyid: $passkey_kms_key_id -> $new_passkey_kms_key_id"
new_passkey_file="$(mktemp)"
log_cmd_pipe sed "s/$(escape_sed $passkey_kms_key_id)/$(escape_sed $new_passkey_kms_key_id)/" $passkey_file > $new_passkey_file
log_cmd mv $new_passkey_file $passkey_file

echo "* Updating alias..."
alias_name=$(log_cmd_pipe aws kms list-aliases --key-id $kms_key_id | jq .Aliases[0].AliasName -r)
if [ "$alias_name" != "null" ]; then
    log_cmd aws kms update-alias --alias-name $alias_name --target-key-id $new_kms_key_id
fi

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

echo "* Scheduling deletion of old KMS key"
log_cmd aws kms schedule-key-deletion --key-id $kms_key_id --pending-window-in-days 7

echo "* Deleting the old Passkey"
log_cmd kubectl delete passkeys.vault.kio.kasten.io $passkey_name_old


rm $log_file
