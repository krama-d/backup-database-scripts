#!/bin/bash

set -e

NAMESPACE_FILE="namespaces.txt"
DUMP_DIR="postgresql"

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

if [ ! -f "$NAMESPACE_FILE" ] || [ ! -s "$NAMESPACE_FILE" ]; then
    echo "Error: $NAMESPACE_FILE does not exist or is empty"
    exit 1
fi

echo "Starting PostgreSQL database restore process..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    dump_files=$(find "$DUMP_DIR/$namespace" -type f -name 'dev-chinchin_*_dump.sql')

    if [ -z "$dump_files" ]; then
        echo "    No dump files found for namespace $namespace. Skipping."
        continue
    fi

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'postgres')

    for pod in $pods; do
        echo "  Checking pod: $pod"

        if kubectl exec -n "$namespace" "$pod" -- printenv | grep -q 'POSTGRES_PASSWORD'; then
            echo "    PostgreSQL container found. Restoring database..."

            db_pass=$(kubectl exec -n "$namespace" "$pod" -- printenv | grep -i 'POSTGRES_PASSWORD' | cut -d '=' -f2)
            db_pass_escaped=$(printf '%q' "$db_pass")

            for dump_file in $dump_files; do
                db_name=$(basename "$dump_file" | cut -d '_' -f1)
                echo "    Restoring database: $db_name"

                if ! kubectl exec -n "$namespace" "$pod" -- bash -c "PGPASSWORD=$db_pass_escaped psql -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '$db_name';\"" | grep -q 1; then
                    echo "    Database $db_name does not exist. Creating database..."
                    if ! kubectl exec -n "$namespace" "$pod" -- bash -c "PGPASSWORD=$db_pass_escaped createdb -U postgres $db_name"; then
                        echo "    Error: Failed to create database $db_name. Skipping."
                        continue
                    fi
                fi

                if ! kubectl exec -n "$namespace" "$pod" -- bash -c "PGPASSWORD=$db_pass_escaped psql -U postgres -d $db_name -f /tmp/$(basename "$dump_file")"; then
                    echo "    Error: Failed to restore database $db_name. Skipping."
                    continue
                fi

                echo "    Database $db_name restored successfully."
            done
        else
            echo "    Pod doesn't contain PostgreSQL."
        fi
    done

done < "$NAMESPACE_FILE"

echo "PostgreSQL database restore process completed."
