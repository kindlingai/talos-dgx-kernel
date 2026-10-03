#!/bin/bash
# Print only SHA-256 of the public DER certificate; never persist the private key.
set -euo pipefail
key=$1
cert_public=$(openssl x509 -in "${key}" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
key_public=$(openssl pkey -in "${key}" -pubout -outform DER | openssl dgst -sha256)
test "${cert_public}" = "${key_public}" || { echo 'Signing key and certificate do not match' >&2; exit 1; }
openssl x509 -in "${key}" -outform DER | openssl dgst -sha256 | cut -d ' ' -f 2
