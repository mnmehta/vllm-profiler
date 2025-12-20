#!/bin/bash
podman build --runtime=runc -t vllmprofiler .
podman tag localhost/vllmprofiler quay.io/mimehta/vllmprofiler
podman push quay.io/mimehta/vllmprofiler:latest
oc delete -f manifests.yaml
sleep 15
oc apply -f manifests.yaml
oc apply -k .
bash gen-certs.sh 
bash patch-ca-bundle.sh 
DO_SIMPLE_TEST=1 ./validate_webhook.sh 

if [ "${DO_VLLM_TEST:-0}" = "1" ]; then
  oc get pods | grep -- -decode- | awk '{print $1}' | xargs oc delete pod
  sleep 2
  newpod=$(oc get pods | grep -- -decode- | awk '{print $1}')
  timeout 30 oc logs -f "$newpod" | tee foo
  oc cp my_method.py "$newpod":profiler.py
  oc logs -f "$newpod" | tee -a foo
fi
