#!/bin/bash

# -----------------------------------------
# Schema-Only Dump Script
# Author: Amaan Ul Haq Siddiqui - DevSecOps Engineer
# Description: Dumps schema (DDL only) for all non-system MySQL databases.
# -----------------------------------------

# Database connection details
USER="****"
HOST="************************************"
PORT="*****"
SSL_MODE="REQUIRED"

# Prompt for password securely
read -s -p "Enter MySQL password for user '$USER': " MYSQL_PWD
echo ""

# Timestamp for output filenames
TS=$(date +"%Y-%m-%d_%H-%M-%S")
OUTFILE="schema_only_dump_$TS.sql"
ERROR_LOG="schema_dump_errors_$TS.log"

# Clear output files if they exist
: > "$OUTFILE"
: > "$ERROR_LOG"

# Fetch list of user-created databases
echo "Retrieving database list..."
DBS=$(mysql -h "$HOST" -P "$PORT" -u "$USER" -p"$MYSQL_PWD" --ssl-mode="$SSL_MODE" -N -e \
"SHOW DATABASES;" | grep -v -E "^(mysql|information_schema|performance_schema|sys)$")

if [ -z "$DBS" ]; then
  echo "No user-created databases found. Exiting."
  exit 1
fi

echo "Beginning schema-only export..."

# Iterate and export schema for each database (with CREATE DATABASE + USE)
for DB in $DBS; do
  echo "Processing database: $DB"

  mysqldump -h "$HOST" -P "$PORT" -u "$USER" -p"$MYSQL_PWD" \
    --ssl-mode="$SSL_MODE" \
    --no-data \
    --single-transaction \
    --skip-lock-tables \
    --set-gtid-purged=OFF \
    --column-statistics=0 \
    --databases "$DB" >> "$OUTFILE" 2>>"$ERROR_LOG"

  if [ $? -ne 0 ]; then
    echo "Error exporting schema for database: $DB" | tee -a "$ERROR_LOG"
  else
    echo "Successfully exported: $DB"
    echo -e "\n\n" >> "$OUTFILE"
  fi
done

echo ""
echo "Schema export complete."
echo "Output file: $OUTFILE"
echo "Error log (if any): $ERROR_LOG"