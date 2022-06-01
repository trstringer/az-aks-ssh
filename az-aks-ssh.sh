#!/bin/bash
# vim: set et ts=4 sw=4:

set -euo pipefail

COMMAND=""
OUTPUT_FILE="/dev/stdout"
CLEAR_LOCAL_KEYS=""
DELETE_SSH_POD=""
SSH_POD_NAME="aks-ssh-session"
CLEANUP=""

function usage() {
    local msg="${1:-}"
    if [ -n "$msg" ]; then
        echo "$msg" >&2
    fi

    echo "Usage:"
    echo "  SSH into an AKS agent node (pass in -c to run a single command"
    echo "  or omit for an interactive session):"
    echo "    ./az-aks-ssh.sh \\"
    echo "        -g|--resource-group <resource_group> \\"
    echo "        -n|--cluster-name <cluster> \\"
    echo "        -d|--node-name <node_name|any> \\"
    echo "        [-c|--command <command>] \\"
    echo "        [-o|--output-file <file>]"
    echo ""
    echo "  Delete all locally generated SSH keys (~/.ssh/az_aks_*):"
    echo "    ./az-aks-ssh.sh --clear-local-ssh-keys"
    echo ""
    echo "  Delete the SSH proxy pod:"
    echo "    ./az-aks-ssh.sh --delete-ssh-pod"
    echo ""
    echo "  Cleanup SSH (delete SSH proxy pod and remove all keys):"
    echo "    ./az-aks-ssh.sh --cleanup"
    exit 1
}

while [[ $# -gt 0 ]]; do
    ARG="$1"

    case $ARG in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift
            shift
            ;;
        -n|--cluster-name)
            CLUSTER="$2"
            shift
            shift
            ;;
        -d|--node-name)
            NODE_NAME="$2"
            shift
            shift
            ;;
        -c|--command)
            COMMAND="$2"
            shift
            shift
            ;;
        -o|--output-file)
            OUTPUT_FILE="$2"
            shift
            shift
            ;;
        --clear-local-ssh-keys)
            CLEAR_LOCAL_KEYS="yes"
            shift
            ;;
        --delete-ssh-pod)
            DELETE_SSH_POD="yes"
            shift
            ;;
        --cleanup)
            CLEANUP="yes"
            shift
            ;;
        -h|--help)
            usage
            ;;
    esac
done

# Try to infer some settings from the environment as a convenience.

if [ -z "${RESOURCE_GROUP:-}" ]; then
    RESOURCE_GROUP="${AZURE_DEFAULTS_GROUP:-$(az config get defaults.group --query value --output tsv 2>/dev/null || true)}"
    if [ -z "${RESOURCE_GROUP:-}" ]; then
        usage 'Missing resource group.'
    fi
fi

if [ -z "${CLUSTER:-}" ]; then
    aks_clusters=$(az aks list --resource-group "$RESOURCE_GROUP" --query [].name --output tsv)
    if [ $(echo "$aks_clusters" | wc -l) -eq 1 ]; then
        CLUSTER="$aks_clusters"
    fi

    if [ -z "${CLUSTER:-}" ]; then
        usage 'Missing cluster.'
    fi
fi

clear_local_keys () {
    echo "Clearing local keys"
    rm ~/.ssh/aks_ssh_*
}

delete_ssh_pod () {
    echo "Deleting SSH pod $SSH_POD_NAME"
    kubectl delete po "$SSH_POD_NAME"
}

if [[ -n "$CLEAR_LOCAL_KEYS" ]]; then
    clear_local_keys
    exit
fi

if [[ -n "$DELETE_SSH_POD" ]]; then
    delete_ssh_pod
    exit
fi

if [[ -n "$CLEANUP" ]]; then
    clear_local_keys
    delete_ssh_pod
    exit
fi

if [[ "$NODE_NAME" == "any" ]]; then
    echo "Selected 'any' node name, getting the first node"
    NODE_NAME=$(kubectl get node -o jsonpath="{.items[0].metadata.labels['kubernetes\.io/hostname']}")
fi

echo "Using node: $NODE_NAME"

NODE_RESOURCE_GROUP=$(az aks show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER" \
    --query "nodeResourceGroup" -o tsv \
    --only-show-errors)
VMSS_LIST=$(az vmss list \
    --resource-group "$NODE_RESOURCE_GROUP" \
    --query "[*].name" -o tsv \
    --only-show-errors)
echo "Found VMSS(es):"
echo "$VMSS_LIST"
CONTAINING_VMSS=""
for VMSS in $VMSS_LIST; do
    INSTANCE_ID=$(az vmss list-instances \
        --resource-group "$NODE_RESOURCE_GROUP" \
        --name "$VMSS" \
        --query "[?osProfile.computerName == '$NODE_NAME'].{instanceId:instanceId}" -o tsv)
    if [[ -n "$INSTANCE_ID" ]]; then
        CONTAINING_VMSS="$VMSS"
        break
    fi
done

if [[ -z "$CONTAINING_VMSS" ]]; then
    echo "Unable to locate node $NODE_NAME in any VMSS"
    exit 1
else
    echo "Found $NODE_NAME in $CONTAINING_VMSS"
fi

SSH_KEY_FILE_NAME="aks_ssh_${NODE_NAME}"
SSH_KEY_FILE="~/.ssh/${SSH_KEY_FILE_NAME}"
SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"
CREATED_KEY_FILE=""
if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Key doesn't exist. Creating new key: $SSH_KEY_FILE"
    ssh-keygen \
        -t rsa \
        -N "" \
        -q -f "$SSH_KEY_FILE"
    CREATED_KEY_FILE="yes"
fi

echo "Instance ID is $INSTANCE_ID"

ACCESS_EXTENSION=$(az vmss show \
    --resource-group "$NODE_RESOURCE_GROUP" \
    --name "$CONTAINING_VMSS" \
    --instance-id $INSTANCE_ID \
    --query "instanceView.extensions[?name == 'VMAccessForLinux']" -o tsv)

if [[ -z "$ACCESS_EXTENSION" || -n "$CREATED_KEY_FILE" ]]; then
    echo "Access extension does not exist or new key generated, adding to VM"
    az vmss extension set \
        --resource-group "$NODE_RESOURCE_GROUP" \
        --vmss-name "$CONTAINING_VMSS" \
        --name "VMAccessForLinux" \
        --publisher "Microsoft.OSTCExtensions" \
        --version "1.4" \
        --protected-settings "{\"username\":\"azureuser\", \"ssh_key\":\"$(cat ${SSH_KEY_FILE}.pub)\"}" > /dev/null

    az vmss update-instances \
        --resource-group "$NODE_RESOURCE_GROUP" \
        --name "$CONTAINING_VMSS" \
        --instance-ids "$INSTANCE_ID"
else
    echo "Access extension already exists"
fi

INSTANCE_IP=$(kubectl get no \
    "$NODE_NAME" \
    -o jsonpath="{.status.addresses[?(@.type == 'InternalIP')].address}")

echo "Instance IP is $INSTANCE_IP"

if ! kubectl get po "$SSH_POD_NAME"; then
    echo "Proxy pod doesn't exist, setting it up"
    kubectl run "$SSH_POD_NAME" --image ubuntu:bionic -- /bin/bash -c "sleep infinity"
    while true; do
        echo "Waiting for proxy pod to be in a Running state"
        POD_STATE=$(kubectl get po "$SSH_POD_NAME" -o jsonpath="{.status.phase}")
        if [[ "$POD_STATE" == "Running" ]]; then
            break
        fi
        sleep 1
    done
    kubectl exec "$SSH_POD_NAME" -- /bin/bash -c "apt-get update && apt-get install -y openssh-client"
fi

kubectl cp "$SSH_KEY_FILE" "${SSH_POD_NAME}:/${SSH_KEY_FILE_NAME}"
kubectl exec "$SSH_POD_NAME" -- chmod 400 /$SSH_KEY_FILE_NAME

if [[ -z "$COMMAND" ]]; then
    echo "No command passed, running in interactive mode"
    kubectl exec -it "$SSH_POD_NAME" -- /bin/bash -c "ssh -i /$SSH_KEY_FILE_NAME -o StrictHostKeyChecking=no azureuser@$INSTANCE_IP"
else
    echo "Running command non-interactively"
    kubectl exec "$SSH_POD_NAME" -- /bin/bash -c "ssh -i /$SSH_KEY_FILE_NAME -o StrictHostKeyChecking=no azureuser@$INSTANCE_IP '$COMMAND'" > "$OUTPUT_FILE"
fi
