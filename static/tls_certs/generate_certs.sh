#!/usr/bin/env bash
# Generate the self-signed TLS material Icarust needs (run once before first use).
#
# Produces, in this directory:
#   ca.crt / ca.key       - a local certificate authority
#   server.crt / server.key - the sequencer's cert, signed by the CA (SAN: localhost)
#
# These files are intentionally NOT committed (they contain private keys). Clients
# must trust ca.crt:  export MINKNOW_TRUSTED_CA=".../static/tls_certs/ca.crt"
#
# Usage:  ./generate_certs.sh        (from this directory or the repo root)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

DAYS=825

# 1. Certificate authority
openssl req -x509 -newkey rsa:4096 -nodes -keyout ca.key -out ca.crt -days "$DAYS" \
  -subj "/C=GB/O=Icarust/CN=Icarust Root CA"

# 2. Server key + CSR
openssl req -newkey rsa:4096 -nodes -keyout server.key -out server.csr \
  -subj "/CN=localhost"

# 3. Sign the server cert with a SAN for localhost (required by modern gRPC/TLS)
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$DAYS" \
  -extfile <(printf "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1,IP:::1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth")

rm -f server.csr ca.srl
echo "Generated ca.crt, ca.key, server.crt, server.key in $DIR"
openssl verify -CAfile ca.crt server.crt
