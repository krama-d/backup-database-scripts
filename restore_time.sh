#!/bin/bash

set -e

NAMESPACE_FILE="namespaces.txt"
DUMP_DIR="timescaledb"

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

if [ ! -f "$NAMESPACE_FILE" ] || [ ! -s "$NAMESPACE_FILE" ]; then
    echo "Error: $NAMESPACE_FILE does not exist or is empty"
    exit 1
fi

echo "Starting TimescaleDB database restore process..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    dump_files=$(find "$DUMP_DIR/$namespace" -type f -name '*_full_dump.sql')

    if [ -z "$dump_files" ]; then
        echo "    No dump files found for namespace $namespace. Skipping."
        continue
    fi

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'timescaledb')

    for pod in $pods; do
        echo "  Checking pod: $pod"

        container_name="timescaledb"

        if kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -q 'PATRONI_SUPERUSER_PASSWORD'; then
            echo "    TimescaleDB container found. Using PATRONI_SUPERUSER_PASSWORD for restoring."
            db_pass=$(kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -i 'PATRONI_SUPERUSER_PASSWORD' | cut -d '=' -f2)
        elif kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -q 'PATRONI_admin_PASSWORD'; then
            echo "    TimescaleDB container found. Using PATRONI_admin_PASSWORD for restoring."
            db_pass=$(kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -i 'PATRONI_admin_PASSWORD' | cut -d '=' -f2)
        else
            echo "    No suitable password found in pod $pod. Skipping."
            continue
        fi

        db_pass_escaped=$(printf '%q' "$db_pass")

        for dump_file in $dump_files; do
            db_name=$(basename "$dump_file" | cut -d '_' -f2)
            echo "    Restoring database: $db_name"

            if ! kubectl exec -i -n "$namespace" "$pod" -c "$container_name" -- bash -c "PGPASSWORD=$db_pass_escaped pg_restore -U postgres -h /var/run/postgresql -d '$db_name' -v -c" < "$dump_file"; then
                echo "    Error: Failed to restore database $db_name. Skipping."
                continue
            fi

            echo "    Database $db_name restored successfully."
        done
    done

done < "$NAMESPACE_FILE"

echo "TimescaleDB database restore process completed."
