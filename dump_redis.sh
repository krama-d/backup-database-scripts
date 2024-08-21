#!/bin/bash

set -e

NAMESPACE_FILE="namespaces.txt"
DUMP_DIR="redis"
RDB_PATH="/data"

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

if [ ! -f "$NAMESPACE_FILE" ] || [ ! -s "$NAMESPACE_FILE" ]; then
    echo "Error: $NAMESPACE_FILE does not exist or is empty"
    exit 1
fi

mkdir -p "$DUMP_DIR"

echo "Starting Redis RDB file save and copy process..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'redis')

    for pod in $pods; do
        echo "  Checking pod: $pod"
        container_name="redis"

        echo "    Running BGSAVE in pod $pod"
        if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- redis-cli BGSAVE; then
            echo "    Error: BGSAVE failed in pod $pod. Skipping."
            continue
        fi

        echo "    Waiting for BGSAVE to complete..."
        sleep 30

        file_exists=$(kubectl exec -n "$namespace" "$pod" -c "$container_name" -- bash -c "[ -f $RDB_PATH/dump.rdb ] && echo 'exists' || echo 'not found'")

        if [ "$file_exists" == "not found" ]; then
            echo "    Error: RDB file not found in pod $pod after BGSAVE. Skipping."
            continue
        fi

        echo "    Copying RDB file..."
        dump_file="${namespace}_redis_$(date +'%Y%m%d_%H%M%S').rdb"
        mkdir -p "$DUMP_DIR/$namespace"

        if ! kubectl cp "$namespace/$pod:$RDB_PATH/dump.rdb" "$DUMP_DIR/$namespace/$dump_file"; then
            echo "    Error: Failed to copy RDB file from pod $pod. Skipping."
            continue
        fi

        echo "    RDB file copied to $DUMP_DIR/$namespace/$dump_file"
    done

done < "$NAMESPACE_FILE"

echo "Redis RDB file save and copy process completed."