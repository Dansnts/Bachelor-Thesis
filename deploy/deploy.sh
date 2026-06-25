#!/usr/bin/env bash
# Requires: sops WITH the age key available and kubectl pointing at CORRECT the cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# Decrypts and applies the SOPS secrets.
echo "Applying SOPS secrets..."
for secret in "$ROOT"/secrets/*.enc.yaml; do
    echo "    $secret"
    sops -d "$secret" | kubectl apply -f -
done

# Applies everything else via the root kustomization.
echo "Applying the stack..."
kubectl apply -k "$ROOT"

echo "Done"
