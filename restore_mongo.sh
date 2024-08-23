#!/bin/bash

set -e

NAMESPACE_FILE="namespaces.txt"
DUMP_DIR="mongodb"

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

if [ ! -f "$NAMESPACE_FILE" ] || [ ! -s "$NAMESPACE_FILE" ]; then
    echo "Error: $NAMESPACE_FILE does not exist or is empty"
    exit 1
fi

echo "Starting MongoDB database restore process using root..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    dump_files=$(find "$DUMP_DIR/$namespace" -type f -name '*_dump.archive')

    if [ -z "$dump_files" ]; then
        echo "    No dump files found for namespace $namespace. Skipping."
        continue
    fi

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'mongodb')

    for pod in $pods; do
        echo "  Checking pod: $pod"

        if kubectl exec -n "$namespace" "$pod" -- printenv | grep -q 'MONGODB_ROOT_PASSWORD'; then
            echo "    MongoDB container found. Restoring databases..."

            root_pass=$(kubectl exec -n "$namespace" "$pod" -- printenv | grep -i 'MONGODB_ROOT_PASSWORD' | cut -d '=' -f2)
            root_pass_escaped=$(printf '%q' "$root_pass")

            for dump_file in $dump_files; do
                db_name=$(basename "$dump_file" | sed -E 's/^[^_]+_([^_]+)_.+_dump\.archive$/\1/')
                echo "    Restoring database: $db_name"

                if ! kubectl exec -i -n "$namespace" "$pod" -- bash -c "mongorestore --host localhost --port 27017 --username root --password $root_pass_escaped --authenticationDatabase admin --archive --drop" < "$dump_file"; then
                    echo "      Error: Failed to restore database $db_name. Skipping."
                    continue
                fi

                echo "      Database $db_name restored successfully."
            done
        else
            echo "    No MongoDB container found."
        fi
    done

done < "$NAMESPACE_FILE"

echo "MongoDB database restore process completed."
