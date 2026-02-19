#!/usr/bin/env bash
set -euo pipefail

FRAGMENT=$1
CONFIG=$2

while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  KEY=${line%%=*}

  if grep -q "^# ${KEY} is not set$" "$CONFIG"; then
    sed -i "s/^# ${KEY} is not set$/${line}/" "$CONFIG"
  elif grep -q "^${KEY}=" "$CONFIG"; then
    sed -i "s/^${KEY}=.*$/${line}/" "$CONFIG"
  else
    echo "$line" >> "$CONFIG"
  fi
done < "$FRAGMENT"
