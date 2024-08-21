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

mkdir -p "$DUMP_DIR"

echo "Starting MongoDB database dump process using root..."

while IFS= read -r namespace || [ -n "$namespace" ]; do
    echo "Checking namespace: $namespace"

    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'mongodb')

    for pod in $pods; do
        echo "  Checking pod: $pod"

        if kubectl exec -n "$namespace" "$pod" -- printenv | grep -q 'MONGODB_ROOT_PASSWORD'; then
            echo "    MongoDB container found. Retrieving database list..."

            root_pass=$(kubectl exec -n "$namespace" "$pod" -- printenv | grep -i 'MONGODB_ROOT_PASSWORD' | cut -d '=' -f2)
            root_pass_escaped=$(printf '%q' "$root_pass")

            databases=$(kubectl exec -n "$namespace" "$pod" -- bash -c "mongosh --quiet --host localhost --port 27017 --username root --password $root_pass_escaped --authenticationDatabase admin --eval 'db.adminCommand(\"listDatabases\").databases.map(db => db.name).join(\",\")'")

            if [ $? -ne 0 ]; then
                echo "    Error: Failed to retrieve database list. Ensure that MongoDB CLI tools are installed in the container."
                continue
            fi

            echo "    Databases found: $databases"

            IFS=',' read -ra DB_ARRAY <<< "$databases"
            for db in "${DB_ARRAY[@]}"; do
                echo "    Dumping database: $db with root user, excluding system.sessions"
                dump_file="${namespace}_${db}_$(date +'%Y%m%d')_dump.archive"
                
                if ! kubectl exec -n "$namespace" "$pod" -- bash -c "mongodump --db '$db' --host localhost --port 27017 --username root --password $root_pass_escaped --authenticationDatabase admin --excludeCollection=system.sessions --archive=/tmp/$dump_file"; then
                    echo "      Error: Failed to dump database: $db. Skipping."
                    continue
                fi

                mkdir -p "$DUMP_DIR/$namespace"

                if ! kubectl cp "$namespace/$pod:/tmp/$dump_file" "$DUMP_DIR/$namespace/$dump_file"; then
                    echo "      Error: Failed to copy dump file from pod to local system."
                    continue
                fi

                echo "      Dump copied to $DUMP_DIR/$namespace/$dump_file"
                
                if ! kubectl exec -n "$namespace" "$pod" -- rm "/tmp/$dump_file"; then
                    echo "      Warning: Failed to remove temporary dump file from the container."
                fi
                echo "      Temporary dump for database $db removed from the container."
            done
        else
            echo "    No MongoDB container found."
        fi
    done

done < "$NAMESPACE_FILE"

echo "MongoDB dump process completed."