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

echo "Starting Redis RDB file restore process..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    dump_files=$(find "$DUMP_DIR/$namespace" -type f -name '*.rdb')

    if [ -z "$dump_files" ]; then
        echo "    No RDB files found for namespace $namespace. Skipping."
        continue
    fi

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'redis')

    for pod in $pods; do
        echo "  Checking pod: $pod"
        container_name="redis"

        for dump_file in $dump_files; do
            echo "    Restoring RDB file: $dump_file to pod $pod"

            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- redis-cli CONFIG SET appendonly no; then
                echo "    Error: Failed to disable AOF persistence in pod $pod. Skipping."
                continue
            fi

            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- redis-cli CONFIG SET save ""; then
                echo "    Error: Failed to disable RDB persistence in pod $pod. Skipping."
                continue
            fi

            echo "    Stopping Redis server in pod $pod"
            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- redis-cli SHUTDOWN NOSAVE; then
                echo "    Error: Failed to stop Redis server in pod $pod. Skipping."
                continue
            fi

            if ! kubectl cp "$dump_file" "$namespace/$pod:$RDB_PATH/dump.rdb"; then
                echo "    Error: Failed to copy RDB file to pod $pod. Skipping."
                continue
            fi

            echo "    RDB file copied to pod $pod"

            echo "    Starting Redis server in pod $pod"
            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- redis-server --daemonize yes; then
                echo "    Error: Failed to start Redis server in pod $pod. Skipping."
                continue
            fi

            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- redis-cli CONFIG SET appendonly yes; then
                echo "    Error: Failed to re-enable AOF persistence in pod $pod."
            fi

            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- redis-cli CONFIG SET save "900 1 300 10 60 10000"; then
                echo "    Error: Failed to re-enable RDB persistence in pod $pod."
            fi

            echo "    Redis RDB file restored successfully in pod $pod"
        done
    done

done < "$NAMESPACE_FILE"

echo "Redis RDB file restore process completed."
