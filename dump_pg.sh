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

mkdir -p "$DUMP_DIR"

echo "Starting PostgreSQL dump process..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'postgres')

    for pod in $pods; do
        echo "  Checking pod: $pod"

        if kubectl exec -n "$namespace" "$pod" -- printenv | grep -q 'POSTGRES_PASSWORD'; then
            echo "    PostgreSQL container found. Dumping..."

            db_pass=$(kubectl exec -n "$namespace" "$pod" -- printenv | grep -i 'POSTGRES_PASSWORD' | cut -d '=' -f2)
            db_pass_escaped=$(printf '%q' "$db_pass")

            dump_file="${namespace}_$(date +'%Y%m%d')_dump.sql"

            if ! kubectl exec -n "$namespace" "$pod" -- bash -c "PGPASSWORD=$db_pass_escaped pg_dumpall -U postgres > /tmp/$dump_file"; then
                echo "    Error: Failed to create dump in the container."
                continue
            fi

            mkdir -p "$DUMP_DIR/$namespace"

            if ! kubectl cp "$namespace/$pod:/tmp/$dump_file" "$DUMP_DIR/$namespace/$dump_file"; then
                echo "    Error: Failed to copy dump file from pod to local system."
                continue
            fi

            echo "    Dump copied to $DUMP_DIR/$namespace/$dump_file"

            if ! kubectl exec -n "$namespace" "$pod" -- rm "/tmp/$dump_file"; then
                echo "    Warning: Failed to remove temporary dump file from the container."
            else
                echo "    Temporary dump file removed from the container."
            fi
        else
            echo "    Pod doesn't contain PostgreSQL."
        fi
    done

done < "$NAMESPACE_FILE"

echo "PostgreSQL dump process completed."