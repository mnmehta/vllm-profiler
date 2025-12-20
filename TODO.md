# Project TODOs

## Convert to using import hook

## make the webhook run in the current namespace

Use the Downward API to inject the namespace into an environment variable.

In your Pod (or Deployment) spec:
'''
apiVersion: v1
kind: Pod
metadata:
  name: example
spec:
  containers:
    - name: app
      image: your-image
      env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
'''
When the Pod starts, POD_NAMESPACE will be set to the namespace the Pod is running in.

Notes
	•	This works for Pods, Deployments, StatefulSets, Jobs, etc.
	•	No RBAC permissions are required.
	•	The value is resolved by the kubelet at runtime.

If you also need related fields (pod name, UID, node name, etc.), they can be injected the same way via fieldRef.