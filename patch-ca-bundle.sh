#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   NS=vllmbench-profiler SVC=env-injector ./patch-ca-bundle.sh
#
# Reads the CA from the ${SVC}-certs secret and patches the
# MutatingWebhookConfiguration caBundle field.

NS="${NS:-vllmbench-profiler}"
SVC="${SVC:-env-injector}"
MWC="${MWC:-env-injector-webhook}"

CA_BUNDLE="$(kubectl -n "${NS}" get secret "${SVC}-certs" -o jsonpath='{.data.tls\.crt}' | base64 -d | base64 -w0)"

kubectl get mutatingwebhookconfiguration "${MWC}" -o json \
  | jq --arg ca "${CA_BUNDLE}" '.webhooks[].clientConfig.caBundle = $ca' \
  | kubectl apply -f -

echo "Patched ${MWC} caBundle."


