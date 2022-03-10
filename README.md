# Kasten K10 Key Rotation

Scripts for automating key rotation in Kasten K10.

## Vault

See the [Kasten docs](https://docs.kasten.io/latest/install/configure.html#hashicorp-vault-transit-secrets-engine) on how to setup encryption using Vault in Kasten and the [Vault docs on key rotation in the Transit Secret Engine](https://learn.hashicorp.com/tutorials/vault/eaas-transit#rotate-the-encryption-key).

If you want to rotate the Vault key used in Kasten, you have to follow a three step process:

1. Create a new version of the key in Vault (i.e. trigger the `/rotate` API)
2. Create a new Passkey to force Kasten to re-encrypt the master key
3. Bump the min decryption version in Vault.

The old Passkey can then be deleted.

If you have a Passkey yaml file, the following script will automatically do the above:

However:

1. Make sure `kubectl` is set to the right context
2. Make sure `vault` is connected to your instance

```sh
./rotate-vault-key.sh passkey-vault-example.yaml
```

You can also use `VAULT_CMD` to override the Vault command.
For example if you are running vault in Kubernetes:

```sh
export VAULT_CMD="kubectl --context vault-cluster-context -n vault exec -i vault-0 -- vault"
./rotate-vault-key.sh passkey-vault-example.yaml
```

## KMS

See the [Kasten docs](https://docs.kasten.io/latest/install/configure.html#aws-customer-managed-keys) on how to setup encryption using KMS in Kasten and the [AWS docs on manual key rotation](https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html#rotate-keys-manually).

If you want to rotate the KMS key used in Kasten, you have to follow a three step process:

1. Create a new key in KMS
2. Create a new Passkey with the new KMS key
3. Delete the KMS key and update the alias

The old Passkey can then be deleted.

If you have a Passkey yaml file, the following script will automatically do the above:

However:

1. Make sure `kubectl` is set to the right context
2. Make sure `aws` is configured to use the right account/region

```sh
./rotate-kms-key.sh passkey-kms-example.yaml
```
