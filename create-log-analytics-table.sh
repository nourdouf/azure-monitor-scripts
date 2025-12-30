#!/bin/bash

# Script: create-log-analytics-table.sh
# Description: Creates or updates a Log Analytics workspace custom table
# Usage: ./create-log-analytics-table.sh <config-file.json>

set -e

# Check if config file is provided
if [ $# -eq 0 ]; then
    echo "Error: No configuration file provided"
    echo "Usage: $0 <config-file.json>"
    exit 1
fi

CONFIG_FILE="$1"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found"
    exit 1
fi

# Parse configuration
SUBSCRIPTION_ID=$(jq -r '.subscription_id' "$CONFIG_FILE")
RESOURCE_GROUP=$(jq -r '.resource_group' "$CONFIG_FILE")
WORKSPACE_NAME=$(jq -r '.workspace_name' "$CONFIG_FILE")
TABLE_NAME=$(jq -r '.table_name' "$CONFIG_FILE")
API_VERSION=$(jq -r '.api_version // "2025-07-01"' "$CONFIG_FILE")
SCHEMA_FILE=$(jq -r '.schema_file' "$CONFIG_FILE")
PLAN=$(jq -r '.plan // "null"' "$CONFIG_FILE")
RETENTION_IN_DAYS=$(jq -r '.retention_in_days // "null"' "$CONFIG_FILE")
TOTAL_RETENTION_IN_DAYS=$(jq -r '.total_retention_in_days // "null"' "$CONFIG_FILE")

# Validate required fields
if [ "$SUBSCRIPTION_ID" == "null" ] || [ "$RESOURCE_GROUP" == "null" ] || \
   [ "$WORKSPACE_NAME" == "null" ] || [ "$TABLE_NAME" == "null" ] || \
   [ "$SCHEMA_FILE" == "null" ] || [ "$PLAN" == "null" ]; then
    echo "Error: Missing required fields in configuration file"
    echo "Required: subscription_id, resource_group, workspace_name, table_name, schema_file, plan"
    exit 1
fi

# Validate plan value
if [ "$PLAN" != "Analytics" ] && [ "$PLAN" != "Auxiliary" ]; then
    echo "Error: Invalid plan value '$PLAN'. Must be 'Analytics' or 'Auxiliary'"
    exit 1
fi

# Check if schema file exists
if [ ! -f "$SCHEMA_FILE" ]; then
    echo "Error: Schema file '$SCHEMA_FILE' not found"
    exit 1
fi

# Create a temporary schema file with settings from config
TEMP_SCHEMA_FILE=$(mktemp)

# Read the schema columns from the schema file
COLUMNS=$(jq '.columns // .properties.schema.columns // .schema.columns' "$SCHEMA_FILE")

if [ "$COLUMNS" == "null" ]; then
    echo "Error: Could not find 'columns' array in schema file"
    echo "Expected format: { \"columns\": [...] }"
    exit 1
fi

# Build the complete schema with plan and retention settings
jq -n \
    --argjson columns "$COLUMNS" \
    --arg plan "$PLAN" \
    --arg tableName "$TABLE_NAME" \
    '{
        properties: {
            schema: {
                name: $tableName,
                columns: $columns
            },
            plan: $plan
        }
    }' > "$TEMP_SCHEMA_FILE"

# Add retention settings if provided
if [ "$PLAN" == "Analytics" ]; then
    # For Analytics plan, both retentionInDays and totalRetentionInDays can be set
    if [ "$RETENTION_IN_DAYS" != "null" ]; then
        jq --arg ret "$RETENTION_IN_DAYS" '.properties.retentionInDays = ($ret | tonumber)' "$TEMP_SCHEMA_FILE" > "$TEMP_SCHEMA_FILE.tmp" && mv "$TEMP_SCHEMA_FILE.tmp" "$TEMP_SCHEMA_FILE"
    fi
    if [ "$TOTAL_RETENTION_IN_DAYS" != "null" ]; then
        jq --arg ret "$TOTAL_RETENTION_IN_DAYS" '.properties.totalRetentionInDays = ($ret | tonumber)' "$TEMP_SCHEMA_FILE" > "$TEMP_SCHEMA_FILE.tmp" && mv "$TEMP_SCHEMA_FILE.tmp" "$TEMP_SCHEMA_FILE"
    fi
else
    # For Auxiliary plan, only totalRetentionInDays is applicable
    if [ "$TOTAL_RETENTION_IN_DAYS" != "null" ]; then
        jq --arg ret "$TOTAL_RETENTION_IN_DAYS" '.properties.totalRetentionInDays = ($ret | tonumber)' "$TEMP_SCHEMA_FILE" > "$TEMP_SCHEMA_FILE.tmp" && mv "$TEMP_SCHEMA_FILE.tmp" "$TEMP_SCHEMA_FILE"
    fi
    if [ "$RETENTION_IN_DAYS" != "null" ]; then
        echo "Warning: retentionInDays is not applicable for Auxiliary plan tables, ignoring..."
    fi
fi

# Trap to cleanup temp file on exit
trap "rm -f $TEMP_SCHEMA_FILE" EXIT

echo "=========================================="
echo "Log Analytics Table Creation/Update"
echo "=========================================="
echo "Subscription: $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Workspace: $WORKSPACE_NAME"
echo "Table: $TABLE_NAME"
echo "API Version: $API_VERSION"
echo "Schema File: $SCHEMA_FILE"
if [ "$PLAN" != "null" ]; then
    echo "Plan: $PLAN"
fi
if [ "$RETENTION_IN_DAYS" != "null" ]; then
    echo "Analytics Retention: $RETENTION_IN_DAYS days"
fi
if [ "$TOTAL_RETENTION_IN_DAYS" != "null" ]; then
    echo "Total Retention: $TOTAL_RETENTION_IN_DAYS days"
fi
echo "=========================================="
echo ""

# Check if table exists
echo "Checking if table exists..."
TABLE_EXISTS=$(az monitor log-analytics workspace table show \
    --resource-group "$RESOURCE_GROUP" \
    --workspace-name "$WORKSPACE_NAME" \
    --name "$TABLE_NAME" \
    --output json 2>/dev/null || echo "null")

if [ "$TABLE_EXISTS" != "null" ]; then
    echo "Table exists. Updating..."
    ACTION="update"
else
    echo "Table does not exist. Creating..."
    ACTION="create"
fi

# Build API endpoint
ENDPOINT="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${WORKSPACE_NAME}/tables/${TABLE_NAME}?api-version=${API_VERSION}"

# Execute REST API call
echo "Executing API call..."
az rest --method PUT --url "$ENDPOINT" --body @"$TEMP_SCHEMA_FILE"

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✅ Table ${ACTION}d successfully!"
    echo "=========================================="

    # Show table details
    echo ""
    echo "Table details:"
    az monitor log-analytics workspace table show \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$WORKSPACE_NAME" \
        --name "$TABLE_NAME" \
        --output table
else
    echo ""
    echo "=========================================="
    echo "❌ Failed to ${ACTION} table"
    echo "=========================================="
    exit 1
fi
