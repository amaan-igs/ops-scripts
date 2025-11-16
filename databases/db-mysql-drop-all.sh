#!/bin/bash

###############################################################################
# Script Name : db-mysql-drop-all.sh
# Author      : Amaan Ul Haq Siddiqui - DevSecOps Engineer
# Purpose     : Drops all non-system MySQL databases from a given RDS instance
# Usage       : ./db-mysql-drop-all.sh
###############################################################################

# === Configuration ===
DB_USER="*******"
DB_HOST="*****************************"
DB_PORT="****"

# === Logging Colors (Optional) ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === Prompt for Password ===
read -s -p "Enter password for MySQL user '${DB_USER}': " DB_PASS
echo ""

# === Fetch Databases ===
echo -e "${YELLOW}Retrieving list of user-created databases from ${DB_HOST}:${DB_PORT}...${NC}"
USER_DBS=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -N -e \
  "SHOW DATABASES;" 2>/dev/null | grep -vE "^(mysql|information_schema|performance_schema|sys)$")

if [[ -z "$USER_DBS" ]]; then
  echo -e "${RED}No user-created databases found. Exiting.${NC}"
  exit 1
fi

echo -e "${GREEN}Databases identified for drop:${NC}"
echo "$USER_DBS"
echo ""

# === Confirmation ===
read -p "Are you sure you want to drop all of the above databases? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Operation cancelled by user.${NC}"
  exit 0
fi

# === Drop Databases ===
for DB in $USER_DBS; do
  echo -e "${YELLOW}Dropping database: ${DB}${NC}"
  mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "DROP DATABASE \`$DB\`;" 2>/dev/null

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Successfully dropped: ${DB}${NC}"
  else
    echo -e "${RED}Failed to drop: ${DB}${NC}"
  fi
done

echo -e "\n${GREEN}All non-system databases processed.${NC}"
