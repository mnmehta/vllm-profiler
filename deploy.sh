#!/bin/bash
set -euo pipefail

# vLLM Profiler Webhook Deployment Script
# Builds, pushes, and deploys the mutating admission webhook for vLLM profiling

# Configuration
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
IMAGE_NAME="${IMAGE_NAME:-vllmprofiler}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-quay.io/mimehta}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
MANIFESTS_FILE="manifests.yaml"
NAMESPACE="vllm-profiler"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-downstream-llm-d}"
TARGET_LABELS="${TARGET_LABELS:-llm-d.ai/inferenceServing=true,app.kubernetes.io/component=llminferenceservice-workload}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy the vLLM profiler mutating admission webhook to Kubernetes.

Options:
    --skip-build        Skip container image build and push
    --skip-validation   Skip webhook validation after deployment
    --help              Show this help message

Environment Variables:
    CONTAINER_RUNTIME   Container runtime to use (default: podman)
    IMAGE_REGISTRY      Image registry (default: quay.io/mimehta)
    IMAGE_TAG           Image tag (default: latest)
    TARGET_NAMESPACE    Namespace to inject profiler into (default: downstream-llm-d)
    TARGET_LABELS       Labels to match for injection (default: llm-d.ai/inferenceServing=true,app.kubernetes.io/component=llminferenceservice-workload)

Examples:
    # Full deployment
    $0

    # Skip building image (use existing)
    $0 --skip-build

    # Use different namespace
    TARGET_NAMESPACE=my-namespace $0

    # Use custom namespace and labels
    TARGET_NAMESPACE=my-namespace TARGET_LABELS="app=myapp" $0

EOF
    exit 0
}

# Parse arguments
SKIP_BUILD=false
SKIP_VALIDATION=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Main deployment
main() {
    log_info "Starting vLLM Profiler Webhook deployment"
    log_info "Configuration:"
    echo "  - Container Runtime: ${CONTAINER_RUNTIME}"
    echo "  - Image: ${FULL_IMAGE}"
    echo "  - Webhook Namespace: ${NAMESPACE}"
    echo "  - Target Namespace: ${TARGET_NAMESPACE}"
    echo "  - Target Labels: ${TARGET_LABELS}"
    echo ""

    # Step 1: Build and push container image
    if [ "$SKIP_BUILD" = false ]; then
        log_info "Step 1/8: Building container image..."
        if ! ${CONTAINER_RUNTIME} build --runtime=runc -t "${IMAGE_NAME}" .; then
            log_error "Container build failed"
            exit 1
        fi
        log_success "Container image built"

        log_info "Tagging image as ${FULL_IMAGE}..."
        ${CONTAINER_RUNTIME} tag "localhost/${IMAGE_NAME}" "${FULL_IMAGE}"

        log_info "Pushing image to registry..."
        if ! ${CONTAINER_RUNTIME} push "${FULL_IMAGE}"; then
            log_error "Image push failed"
            exit 1
        fi
        log_success "Container image pushed to ${FULL_IMAGE}"
    else
        log_warn "Skipping container build (--skip-build specified)"
    fi

    # Step 2: Delete existing resources (idempotent deployment)
    log_info "Step 2/8: Removing existing resources (if any)..."
    oc delete -f "${MANIFESTS_FILE}" --ignore-not-found=true
    log_info "Waiting for resources to be deleted..."
    sleep 5
    log_success "Existing resources removed"

    # Step 2.5: Update manifests and kustomization with TARGET_NAMESPACE and TARGET_LABELS
    log_info "Updating configuration files..."
    log_info "  TARGET_NAMESPACE=${TARGET_NAMESPACE}"
    log_info "  TARGET_LABELS=${TARGET_LABELS}"
    # Update manifests.yaml TARGET_NAMESPACE env var
    sed -i "s/value: \"downstream-llm-d\"/value: \"${TARGET_NAMESPACE}\"/g" "${MANIFESTS_FILE}"
    # Update manifests.yaml TARGET_LABELS env var
    sed -i "s|value: \"llm-d.ai/inferenceServing=true,app.kubernetes.io/component=llminferenceservice-workload\"|value: \"${TARGET_LABELS}\"|g" "${MANIFESTS_FILE}"
    # Update kustomization.yaml namespace
    sed -i "s/namespace: downstream-llm-d/namespace: ${TARGET_NAMESPACE}/g" kustomization.yaml
    log_success "Configuration files updated"

    # Step 3: Create namespace (needed before cert generation)
    log_info "Step 3/8: Creating namespace ${NAMESPACE}..."
    oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
    log_success "Namespace ready"

    # Step 4: Generate TLS certificates (before deploying webhook)
    log_info "Step 4/8: Generating TLS certificates..."
    if ! bash gen-certs.sh; then
        log_error "Certificate generation failed"
        exit 1
    fi
    log_success "TLS certificates generated"

    # Step 5: Apply manifests (now secret exists)
    log_info "Step 5/8: Deploying webhook resources..."
    if ! oc apply -f "${MANIFESTS_FILE}"; then
        log_error "Failed to apply manifests"
        exit 1
    fi
    log_success "Webhook resources deployed"

    # Step 6: Apply kustomization (ConfigMap)
    log_info "Step 6/8: Creating ConfigMap with profiler code..."
    if ! oc apply -k .; then
        log_error "Failed to apply kustomization"
        exit 1
    fi
    log_success "ConfigMap created in ${TARGET_NAMESPACE}"

    # Step 7: Patch webhook with CA bundle
    log_info "Step 7/8: Patching webhook with CA bundle..."
    if ! bash patch-ca-bundle.sh; then
        log_error "CA bundle patching failed"
        exit 1
    fi
    log_success "Webhook CA bundle configured"

    # Step 8: Validate deployment
    if [ "$SKIP_VALIDATION" = false ]; then
        log_info "Step 8/8: Validating webhook deployment..."
        if ! DO_SIMPLE_TEST=1 ./validate_webhook.sh; then
            log_warn "Webhook validation reported issues (see output above)"
        else
            log_success "Webhook validation passed"
        fi
    else
        log_warn "Skipping validation (--skip-validation specified)"
    fi

    echo ""
    log_success "Deployment complete!"
    echo ""
    log_info "Next steps:"
    echo "  1. Create a pod in namespace '${TARGET_NAMESPACE}' with label:"
    echo "     llm-d.ai/inferenceServing=true"
    echo "  2. Check pod logs for profiler output after ~100-150 model executions"
    echo "  3. Retrieve trace file from pod for Chrome trace visualization"
    echo ""
    log_info "To remove all resources, run: ./teardown.sh"
}

# Run main function
main
