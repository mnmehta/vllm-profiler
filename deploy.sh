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
NAMESPACE="vllm-profiler"
CLUSTER="${CLUSTER:-}"

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
    CLUSTER             Cluster overlay to use (REQUIRED)
                        Available: psap-rhaiis-h200, b200, placeholder
    CONTAINER_RUNTIME   Container runtime to use (default: podman)
    IMAGE_REGISTRY      Image registry (default: quay.io/mimehta)
    IMAGE_TAG           Image tag (default: latest)

Examples:
    # Deploy to h200 cluster
    CLUSTER=psap-rhaiis-h200 $0

    # Deploy to b200 cluster
    CLUSTER=b200 $0

    # Skip building image (use existing)
    CLUSTER=psap-rhaiis-h200 $0 --skip-build

    # Deploy to specific cluster without building
    CLUSTER=b200 $0 --skip-build

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

# Validate CLUSTER is set
if [ -z "${CLUSTER}" ]; then
    log_error "CLUSTER environment variable is required"
    log_info "Available clusters:"
    ls -1 overlays/
    log_info "Usage: CLUSTER=<cluster-name> $0"
    exit 1
fi

# Validate cluster overlay exists
if [ ! -d "overlays/${CLUSTER}" ]; then
    log_error "Cluster overlay 'overlays/${CLUSTER}' not found"
    log_info "Available overlays:"
    ls -1 overlays/
    exit 1
fi

# Main deployment
main() {
    log_info "Starting vLLM Profiler Webhook deployment"
    log_info "Configuration:"
    echo "  - Container Runtime: ${CONTAINER_RUNTIME}"
    echo "  - Image: ${FULL_IMAGE}"
    echo "  - Webhook Namespace: ${NAMESPACE}"
    echo "  - Cluster Overlay: ${CLUSTER}"
    echo ""

    # Step 1: Build and push container image
    if [ "$SKIP_BUILD" = false ]; then
        log_info "Step 1/6: Building container image..."
        if ! ${CONTAINER_RUNTIME} build --platform linux/amd64 -t "${IMAGE_NAME}" .; then
            log_error "Container build failed"
            exit 1
        fi
        log_success "Container image built for linux/amd64"

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
    log_info "Step 2/6: Removing existing resources (if any)..."
    oc kustomize "overlays/${CLUSTER}" --load-restrictor LoadRestrictionsNone | oc delete -f - --ignore-not-found=true
    log_info "Waiting for resources to be deleted..."
    sleep 5
    log_success "Existing resources removed"

    # Step 3: Apply all resources via kustomize overlay
    log_info "Step 3/6: Deploying webhook resources and ConfigMap..."
    if ! oc kustomize "overlays/${CLUSTER}" --load-restrictor LoadRestrictionsNone | oc apply -f -; then
        log_error "Failed to apply kustomize overlay"
        exit 1
    fi
    log_success "Webhook resources and ConfigMap deployed"

    # Step 4: Generate TLS certificates
    log_info "Step 4/6: Generating TLS certificates..."
    if ! bash gen-certs.sh; then
        log_error "Certificate generation failed"
        exit 1
    fi
    log_success "TLS certificates generated"

    # Step 5: Patch webhook with CA bundle
    log_info "Step 5/6: Patching webhook with CA bundle..."
    if ! bash patch-ca-bundle.sh; then
        log_error "CA bundle patching failed"
        exit 1
    fi
    log_success "Webhook CA bundle configured"

    # Step 6: Validate deployment
    if [ "$SKIP_VALIDATION" = false ]; then
        log_info "Step 6/6: Validating webhook deployment..."
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
    log_info "Verify configuration with:"
    echo "  oc logs -n vllm-profiler deployment/env-injector | head -10"
    echo ""
    log_info "Next steps:"
    echo "  1. Create a pod matching the TARGET_LABELS configured in overlays/${CLUSTER}/patch.yaml"
    echo "  2. Check pod logs for profiler output after ~100-150 model executions"
    echo "  3. Retrieve trace file from pod for Chrome trace visualization"
    echo ""
    log_info "To remove all resources, run: CLUSTER=${CLUSTER} ./teardown.sh"
}

# Run main function
main
