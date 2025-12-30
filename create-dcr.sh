#!/bin/bash

# Script: create-dcr.sh
# Description: Creates or updates a Data Collection Rule (DCR)
# Usage: ./create-dcr.sh <config-file.json>

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
RESOURCE_GROUP=$(jq -r '.resource_group' "$CONFIG_FILE")
TEMPLATE_FILE=$(jq -r '.template_file' "$CONFIG_FILE")
DCR_NAME=$(jq -r '.dcr_name' "$CONFIG_FILE")
LOCATION=$(jq -r '.location' "$CONFIG_FILE")
WORKSPACE_RESOURCE_ID=$(jq -r '.workspace_resource_id // "null"' "$CONFIG_FILE")
SPIRE_WORKSPACE_RESOURCE_ID=$(jq -r '.spire_workspace_resource_id // "null"' "$CONFIG_FILE")
GITRPCD_WORKSPACE_RESOURCE_ID=$(jq -r '.gitrpcd_workspace_resource_id // "null"' "$CONFIG_FILE")
TRANSFORM_KQL=$(jq -r '.transform_kql // "null"' "$CONFIG_FILE")

# Validate required fields
if [ "$RESOURCE_GROUP" == "null" ] || [ "$TEMPLATE_FILE" == "null" ] || \
   [ "$DCR_NAME" == "null" ] || [ "$LOCATION" == "null" ]; then
    echo "Error: Missing required fields in configuration file"
    echo "Required: resource_group, template_file, dcr_name, location"
    exit 1
fi

# Check if template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file '$TEMPLATE_FILE' not found"
    exit 1
fi

# Build parameters JSON based on what's in the config
PARAMS_JSON=$(jq -n \
    --arg dcr_name "$DCR_NAME" \
    --arg location "$LOCATION" \
    '{
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "dataCollectionRuleName": {"value": $dcr_name},
            "location": {"value": $location}
        }
    }')

# Add workspace parameters if present
if [ "$WORKSPACE_RESOURCE_ID" != "null" ]; then
    PARAMS_JSON=$(echo "$PARAMS_JSON" | jq --arg wrid "$WORKSPACE_RESOURCE_ID" \
        '.parameters.workspaceResourceId = {"value": $wrid}')
fi

if [ "$SPIRE_WORKSPACE_RESOURCE_ID" != "null" ]; then
    PARAMS_JSON=$(echo "$PARAMS_JSON" | jq --arg wrid "$SPIRE_WORKSPACE_RESOURCE_ID" \
        '.parameters.spireWorkspaceResourceId = {"value": $wrid}')
fi

if [ "$GITRPCD_WORKSPACE_RESOURCE_ID" != "null" ]; then
    PARAMS_JSON=$(echo "$PARAMS_JSON" | jq --arg wrid "$GITRPCD_WORKSPACE_RESOURCE_ID" \
        '.parameters.gitrpcdWorkspaceResourceId = {"value": $wrid}')
fi

# Create temporary files
TEMP_TEMPLATE_FILE=$(mktemp)
TEMP_PARAMS_FILE=$(mktemp)

cp "$TEMPLATE_FILE" "$TEMP_TEMPLATE_FILE"
echo "$PARAMS_JSON" > "$TEMP_PARAMS_FILE"

if [ "$TRANSFORM_KQL" != "null" ]; then
    echo "Applying custom KQL transformation..."
    # Update the transformKql in all dataFlows
    jq --arg kql "$TRANSFORM_KQL" \
        '(.resources[0].properties.dataFlows[] | select(.transformKql) | .transformKql) = $kql' \
        "$TEMP_TEMPLATE_FILE" > "$TEMP_TEMPLATE_FILE.tmp" && mv "$TEMP_TEMPLATE_FILE.tmp" "$TEMP_TEMPLATE_FILE"
fi

# Trap to cleanup temp files on exit
trap "rm -f $TEMP_TEMPLATE_FILE $TEMP_PARAMS_FILE" EXIT

echo "=========================================="
echo "Data Collection Rule Deployment"
echo "=========================================="
echo "Resource Group: $RESOURCE_GROUP"
echo "DCR Name: $DCR_NAME"
echo "Location: $LOCATION"
echo "Template File: $TEMPLATE_FILE"
if [ "$TRANSFORM_KQL" != "null" ]; then
    echo "Custom Transformation: Yes"
fi
echo "=========================================="
echo ""

# Check if DCR exists
echo "Checking if DCR exists..."
DCR_EXISTS=$(az monitor data-collection rule show \
    --name "$DCR_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || echo "null")

if [ "$DCR_EXISTS" != "null" ]; then
    echo "DCR exists. Updating..."
    ACTION="update"
else
    echo "DCR does not exist. Creating..."
    ACTION="create"
fi

# Deploy ARM template
echo "Deploying ARM template..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$TEMP_TEMPLATE_FILE" \
    --parameters @"$TEMP_PARAMS_FILE" \
    --output json)

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✅ DCR ${ACTION}d successfully!"
    echo "=========================================="

    # Extract DCR ID from deployment output
    DCR_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.dataCollectionRuleId.value')
    echo ""
    echo "DCR Resource ID:"
    echo "$DCR_ID"

    # Show DCR details
    echo ""
    echo "DCR details:"
    az monitor data-collection rule show \
        --name "$DCR_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --output json | jq '{
            name: .name,
            location: .location,
            immutableId: .immutableId,
            streams: .streamDeclarations | keys,
            destinations: .destinations.logAnalytics[].name,
            provisioningState: .provisioningState
        }'

    # Get DCE endpoint if it exists
    echo ""
    echo "Data Collection Endpoint:"
    DCE_ID=$(az monitor data-collection rule show \
        --name "$DCR_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query dataCollectionEndpointId -o tsv 2>/dev/null || echo "")

    if [ -n "$DCE_ID" ] && [ "$DCE_ID" != "None" ]; then
        DCE_NAME=$(echo "$DCE_ID" | awk -F'/' '{print $NF}')
        DCE_ENDPOINT=$(az monitor data-collection endpoint show \
            --name "$DCE_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --query logsIngestion.endpoint -o tsv 2>/dev/null || echo "Direct ingestion (no DCE)")
        echo "$DCE_ENDPOINT"
    else
        echo "Direct ingestion (no DCE required)"
    fi

else
    echo ""
    echo "=========================================="
    echo "❌ Failed to ${ACTION} DCR"
    echo "=========================================="
    exit 1
fi
