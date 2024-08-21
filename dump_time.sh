#!/bin/bash
###
###  to restore your data use pg_restore -U postgres -d target_database -v /path/to/your/dump/file.dump
###

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

mkdir -p "$DUMP_DIR"

echo "Starting TimescaleDB database dump process with full dump..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'timescaledb')

    for pod in $pods; do
        echo "  Checking pod: $pod"

        container_name="timescaledb"

        if kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -q 'PATRONI_SUPERUSER_PASSWORD'; then
            echo "    TimescaleDB container found. Using PATRONI_SUPERUSER_PASSWORD for dumping."
            db_pass=$(kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -i 'PATRONI_SUPERUSER_PASSWORD' | cut -d '=' -f2)
        elif kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -q 'PATRONI_admin_PASSWORD'; then
            echo "    TimescaleDB container found. Using PATRONI_admin_PASSWORD for dumping."
            db_pass=$(kubectl exec -n "$namespace" "$pod" -c "$container_name" -- printenv | grep -i 'PATRONI_admin_PASSWORD' | cut -d '=' -f2)
        else
            echo "    No suitable password found in pod $pod. Skipping."
            continue
        fi

        db_pass_escaped=$(printf '%q' "$db_pass")

        databases=$(kubectl exec -n "$namespace" "$pod" -c "$container_name" -- bash -c "PGPASSWORD=$db_pass_escaped psql -U postgres -d postgres -tAc 'SELECT datname FROM pg_database WHERE datistemplate = false;'")

        if [ $? -ne 0 ]; then
            echo "    Error: Failed to retrieve database list. Ensure that PostgreSQL CLI tools are installed in the container."
            continue
        fi

        echo "    Databases found: $databases"

        for db in $databases; do
            echo "    Performing full dump for database: $db"
            dump_file="${namespace}_${db}_$(date +'%Y%m%d')_full_dump.sql"
            
            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- bash -c "PGPASSWORD=$db_pass_escaped pg_dump -U postgres -d '$db' -F c -b -v -f /tmp/$dump_file"; then
                echo "    Error: Failed to dump database: $db. Skipping."
                continue
            fi

            mkdir -p "$DUMP_DIR/$namespace"

            if ! kubectl cp "$namespace/$pod:/tmp/$dump_file" "$DUMP_DIR/$namespace/$dump_file"; then
                echo "    Error: Failed to copy dump file from pod to local system."
                continue
            fi

            echo "    Dump copied to $DUMP_DIR/$namespace/$dump_file"
            
            if ! kubectl exec -n "$namespace" "$pod" -c "$container_name" -- rm "/tmp/$dump_file"; then
                echo "    Warning: Failed to remove temporary dump file from the container."
            else
                echo "    Temporary dump for database $db removed from the container."
            fi
        done
    done

done < "$NAMESPACE_FILE"

echo "TimescaleDB full dump process completed."