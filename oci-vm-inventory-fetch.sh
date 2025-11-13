#!/bin/bash

set -euo pipefail

###############################################################################
# OCI Compute Instance Inventory Export Script
# Author: Amaan Ul Haq Siddiqui - DevOps Engineer
# Description: Exports comprehensive inventory of OCI compute
#              instances including compartment names, network
#              configuration, image metadata, and attached disks.
###############################################################################

# Configuration: Target region and output settings
REGION="me-jeddah-1"
DATE=$(date +%Y%m%d)
OUTPUT_DIR="oci_vm_inventory_${REGION}_${DATE}"
LOG_FILE="${OUTPUT_DIR}/vm_inventory.log"
JSON_OUTPUT="${OUTPUT_DIR}/vm_clean.json"
CSV_OUTPUT="${OUTPUT_DIR}/vm_inventory.csv"
TEMP_DIR="${OUTPUT_DIR}/temp"

# Initialize output directory structure
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

echo "-----------------------------------------------------------"
echo "OCI Compute Instance Inventory Export"
echo "Region: $REGION | Date: $DATE"
echo "-----------------------------------------------------------"

echo "Retrieving tenancy configuration..."
# Extract tenancy OCID from OCI CLI configuration file
TENANCY_OCID=$(grep '^tenancy' ~/.oci/config | awk -F'=' '{print $2}' | tr -d ' ')

# Validate tenancy OCID is present
if [[ -z "$TENANCY_OCID" ]]; then
    echo "ERROR: Unable to determine tenancy OCID from ~/.oci/config" | tee -a "$LOG_FILE"
    exit 1
fi

echo "Tenancy OCID: $TENANCY_OCID"

echo "Retrieving compartment hierarchy..."
# Query OCI for all compartments in the tenancy
COMPARTMENTS_JSON=$(oci iam compartment list \
    --compartment-id "$TENANCY_OCID" \
    --compartment-id-in-subtree true \
    --all \
    --output json 2>>"$LOG_FILE")

# Build compartment ID to name mapping
echo "$COMPARTMENTS_JSON" | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | [.id, .name] | @tsv' > "${TEMP_DIR}/compartment_map.tsv"

# Include root tenancy in compartment mapping
TENANCY_NAME=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --query 'data.name' --raw-output 2>>"$LOG_FILE")
echo -e "${TENANCY_OCID}\t${TENANCY_NAME}" >> "${TEMP_DIR}/compartment_map.tsv"

# Extract list of active compartment OCIDs
COMPARTMENT_IDS=$(echo "$COMPARTMENTS_JSON" | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | .id')
COMPARTMENT_IDS="$COMPARTMENT_IDS"$'\n'"$TENANCY_OCID"

# Validate compartments were found
if [[ -z "$COMPARTMENT_IDS" ]]; then
    echo "ERROR: No active compartments found" | tee -a "$LOG_FILE"
    exit 1
fi

COMPARTMENT_COUNT=$(echo "$COMPARTMENT_IDS" | wc -l)
echo "Discovered $COMPARTMENT_COUNT active compartments"

echo "Collecting compute instance data..."
# Initialize array to store instance data
VM_DATA=()

# Iterate through each compartment to collect compute instances
for COMP_ID in $COMPARTMENT_IDS; do
    INSTANCES_JSON=$(oci compute instance list \
        --compartment-id "$COMP_ID" \
        --all \
        --region "$REGION" \
        --output json 2>>"$LOG_FILE" || true)

    # Append non-empty results to array
    if [[ -n "$INSTANCES_JSON" && "$INSTANCES_JSON" != "[]" ]]; then
        VM_DATA+=("$INSTANCES_JSON")
    fi
done

echo "Retrieving network and storage configuration for instances..."
# Begin JSON array output
echo "[" > "$JSON_OUTPUT"
first=1

# Process each instance to enrich with network and disk information
for VM_JSON in "${VM_DATA[@]}"; do
    INSTANCE_IDS=$(echo "$VM_JSON" | jq -r '.data[].id')

    for INSTANCE_ID in $INSTANCE_IDS; do
        echo "Processing instance: $INSTANCE_ID"
        
        # Extract instance metadata
        INSTANCE_DATA=$(echo "$VM_JSON" | jq --arg id "$INSTANCE_ID" '.data[] | select(.id == $id)')
        COMP_ID=$(echo "$INSTANCE_DATA" | jq -r '.["compartment-id"]')

        # Retrieve VNIC attachments for instance
        VNIC_ATTACHMENTS=$(oci compute vnic-attachment list \
            --compartment-id "$COMP_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --output json 2>>"$LOG_FILE" || echo '{"data":[]}')

        # Collect private IP addresses from all attached VNICs
        PRIVATE_IPS=""
        VNIC_IDS=$(echo "$VNIC_ATTACHMENTS" | jq -r '.data[] | select(."lifecycle-state"=="ATTACHED") | ."vnic-id"')

        for VNIC_ID in $VNIC_IDS; do
            # Query VNIC details for IP information
            VNIC_INFO=$(oci network vnic get \
                --vnic-id "$VNIC_ID" \
                --region "$REGION" \
                --output json 2>>"$LOG_FILE" || echo '{"data":{}}')

            # Extract and concatenate private IPs
            PRIVATE_IP=$(echo "$VNIC_INFO" | jq -r '.data."private-ip" // ""')
            if [[ -n "$PRIVATE_IP" ]]; then
                if [[ -z "$PRIVATE_IPS" ]]; then
                    PRIVATE_IPS="$PRIVATE_IP"
                else
                    PRIVATE_IPS="${PRIVATE_IPS};${PRIVATE_IP}"
                fi
            fi
        done

        # Retrieve boot volume attachments
        BOOT_VOL_ATTACHMENTS=$(oci compute boot-volume-attachment list \
            --availability-domain "$(echo "$INSTANCE_DATA" | jq -r '.["availability-domain"]')" \
            --compartment-id "$COMP_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --output json 2>>"$LOG_FILE" || echo '{"data":[]}')

        # Collect boot volume information
        DISK_INFO=""
        BOOT_VOL_IDS=$(echo "$BOOT_VOL_ATTACHMENTS" | jq -r '.data[] | select(."lifecycle-state"=="ATTACHED") | ."boot-volume-id"')

        for BOOT_VOL_ID in $BOOT_VOL_IDS; do
            BOOT_VOL_DATA=$(oci bv boot-volume get \
                --boot-volume-id "$BOOT_VOL_ID" \
                --region "$REGION" \
                --output json 2>>"$LOG_FILE" || echo '{"data":{}}')

            BOOT_VOL_NAME=$(echo "$BOOT_VOL_DATA" | jq -r '.data."display-name" // "Unknown"')
            BOOT_VOL_SIZE=$(echo "$BOOT_VOL_DATA" | jq -r '.data."size-in-gbs" // "0"')

            if [[ -n "$BOOT_VOL_NAME" && "$BOOT_VOL_NAME" != "Unknown" ]]; then
                if [[ -z "$DISK_INFO" ]]; then
                    DISK_INFO="${BOOT_VOL_NAME} (${BOOT_VOL_SIZE}GB)"
                else
                    DISK_INFO="${DISK_INFO}; ${BOOT_VOL_NAME} (${BOOT_VOL_SIZE}GB)"
                fi
            fi
        done

        # Retrieve block volume attachments
        BLOCK_VOL_ATTACHMENTS=$(oci compute volume-attachment list \
            --compartment-id "$COMP_ID" \
            --instance-id "$INSTANCE_ID" \
            --region "$REGION" \
            --output json 2>>"$LOG_FILE" || echo '{"data":[]}')

        BLOCK_VOL_IDS=$(echo "$BLOCK_VOL_ATTACHMENTS" | jq -r '.data[] | select(."lifecycle-state"=="ATTACHED") | ."volume-id"')

        for BLOCK_VOL_ID in $BLOCK_VOL_IDS; do
            BLOCK_VOL_DATA=$(oci bv volume get \
                --volume-id "$BLOCK_VOL_ID" \
                --region "$REGION" \
                --output json 2>>"$LOG_FILE" || echo '{"data":{}}')

            BLOCK_VOL_NAME=$(echo "$BLOCK_VOL_DATA" | jq -r '.data."display-name" // "Unknown"')
            BLOCK_VOL_SIZE=$(echo "$BLOCK_VOL_DATA" | jq -r '.data."size-in-gbs" // "0"')

            if [[ -n "$BLOCK_VOL_NAME" && "$BLOCK_VOL_NAME" != "Unknown" ]]; then
                if [[ -z "$DISK_INFO" ]]; then
                    DISK_INFO="${BLOCK_VOL_NAME} (${BLOCK_VOL_SIZE}GB)"
                else
                    DISK_INFO="${DISK_INFO}; ${BLOCK_VOL_NAME} (${BLOCK_VOL_SIZE}GB)"
                fi
            fi
        done

        # Extract shape configuration for vCPU and RAM
        SHAPE_CONFIG=$(echo "$INSTANCE_DATA" | jq -r '.["shape-config"] // {}')
        OCPU_COUNT=$(echo "$SHAPE_CONFIG" | jq -r '.ocpus // "0"')
        MEMORY_GB=$(echo "$SHAPE_CONFIG" | jq -r '.["memory-in-gbs"] // "0"')
        
        # If shape-config doesn't have values, try to get from instance directly
        if [[ "$OCPU_COUNT" == "0" || "$OCPU_COUNT" == "null" ]]; then
            OCPU_COUNT="N/A"
        fi
        
        if [[ "$MEMORY_GB" == "0" || "$MEMORY_GB" == "null" ]]; then
            MEMORY_GB="N/A"
        fi

        # Merge all collected data into instance data
        ENHANCED_DATA=$(echo "$INSTANCE_DATA" | jq \
            --arg ips "$PRIVATE_IPS" \
            --arg disks "$DISK_INFO" \
            --arg vcpu "$OCPU_COUNT" \
            --arg ram "$MEMORY_GB" \
            '. + {"private-ips": $ips, "attached-disks": $disks, "vcpu-count": $vcpu, "memory-gb": $ram}')

        # Write to JSON with proper comma separation
        if [[ $first -eq 0 ]]; then
            echo "," >> "$JSON_OUTPUT"
        fi
        echo "$ENHANCED_DATA" | jq -c '.' >> "$JSON_OUTPUT"
        first=0
    done
done

# Close JSON array
echo "]" >> "$JSON_OUTPUT"

echo "Resolving image metadata..."
# Extract unique image OCIDs from collected instance data
IMAGE_IDS=$(jq -r '.[] | .["image-id"] // ""' "$JSON_OUTPUT" | sort -u | grep -v '^$')

# Build image OCID to display name mapping
> "${TEMP_DIR}/image_map.tsv"
for IMAGE_ID in $IMAGE_IDS; do
    # Query OCI for image display name
    IMAGE_NAME=$(oci compute image get \
        --image-id "$IMAGE_ID" \
        --region "$REGION" \
        --query 'data."display-name"' \
        --raw-output 2>>"$LOG_FILE" || echo "Unknown")
    echo -e "${IMAGE_ID}\t${IMAGE_NAME}" >> "${TEMP_DIR}/image_map.tsv"
done

echo "Generating CSV report..."

# Prepare AWK associative arrays from mapping files
COMP_MAP_AWK=$(awk -F'\t' '{printf "comp[\"%s\"]=\"%s\"; ", $1, $2}' "${TEMP_DIR}/compartment_map.tsv")
IMAGE_MAP_AWK=$(awk -F'\t' '{printf "img[\"%s\"]=\"%s\"; ", $1, $2}' "${TEMP_DIR}/image_map.tsv")

# Convert JSON to CSV with all column headers
jq -r '
    (["VM Name","OCID","Availability Domain","Shape","vCPU","RAM (GB)","Compartment Name","Compartment OCID","Region","State","Time Created","Private IPs","Attached Disks","Image Name","Image OCID"]),
    (.[] | [
        .["display-name"],
        .id,
        .["availability-domain"],
        .shape,
        (.["vcpu-count"] // "N/A"),
        (.["memory-gb"] // "N/A"),
        .["compartment-id"],
        .["compartment-id"],
        .region,
        .["lifecycle-state"],
        .["time-created"],
        (.["private-ips"] // ""),
        (.["attached-disks"] // ""),
        .["image-id"],
        .["image-id"]
    ]) | @csv' "$JSON_OUTPUT" > "${TEMP_DIR}/vm_temp.csv"

# Replace OCIDs with human-readable names using mapping tables
awk -F',' -v OFS=',' '
    BEGIN {
        '"$COMP_MAP_AWK"'
        '"$IMAGE_MAP_AWK"'
    }
    NR==1 {print; next}
    {
        comp_ocid = $8
        gsub(/"/, "", comp_ocid)

        image_ocid = $15
        gsub(/"/, "", image_ocid)

        if (comp_ocid in comp) {
            $7 = "\"" comp[comp_ocid] "\""
        }

        if (image_ocid in img) {
            $14 = "\"" img[image_ocid] "\""
        }

        print
    }
' "${TEMP_DIR}/vm_temp.csv" > "$CSV_OUTPUT"

# Clean up temporary files
rm -rf "$TEMP_DIR"

# Calculate summary statistics
TOTAL_VMS=$(jq 'length' "$JSON_OUTPUT")

echo "-----------------------------------------------------------"
echo "Inventory export completed successfully"
echo "-----------------------------------------------------------"
echo "Total instances discovered: $TOTAL_VMS"
echo "JSON output: $JSON_OUTPUT"
echo "CSV output: $CSV_OUTPUT"
echo "Log file: $LOG_FILE"
echo "-----------------------------------------------------------"

# CSV Output Format:
# | VM Name   | OCID              | Availability Domain | Shape               | vCPU | RAM (GB)  | Compartment  | Compartment OCID (short) | Region      | State   | Time Created         | Private IP   | Attached Disks                   | Image Name     | Image OCID (short) |
# |-----------|-------------------|---------------------|---------------------|------|-----------|--------------|--------------------------|-------------|---------|----------------------|--------------|----------------------------------|----------------|--------------------|
# | OCI-VM-01 | ocid1.inst...qdwa | ME-JEDDAH-1-AD-1    | VM.Standard.E4.Flex | 4    | 8         | APP          | ocid1.comp...z3pa        | me-jeddah-1 | RUNNING | 2023-09-04T09:06:25Z | 10.103.1.115 | OCI-VM-01 (Boot Volume) (100GB)  | rhel-cis-image | ocid1.imag...qgea  |
