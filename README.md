# Azure Monitor Log Analytics - Management Scripts

Reusable scripts for managing Azure Monitor Log Analytics custom tables and Data Collection Rules (DCRs).

## Prerequisites

- Azure CLI (`az login`)
- `jq` JSON processor
- Bash shell

## Quick Start

1. **Clone and setup:**
   ```bash
   git clone https://github.com/nourdouf/azure-monitor-scripts.git
   cd azure-monitor-scripts

   # Copy example configs
   cp parameters/table/logs_CL_config.example.json parameters/table/logs_CL_config.json
   cp parameters/dcr/dcr-spire-config.example.json parameters/dcr/dcr-spire-config.json
   ```

2. **Edit configs** - Replace placeholders with your Azure values:
   - `YOUR_SUBSCRIPTION_ID`
   - `YOUR_RESOURCE_GROUP`
   - `YOUR_WORKSPACE_NAME`

3. **Create a table:**
   ```bash
   ./create-log-analytics-table.sh parameters/table/logs_CL_config.json
   ```

4. **Create a DCR:**
   ```bash
   ./create-dcr.sh parameters/dcr/dcr-spire-config.json
   ```

## Configuration Files

### Table Config (`parameters/table/*.json`)
```json
{
  "subscription_id": "YOUR_SUBSCRIPTION_ID",
  "resource_group": "YOUR_RESOURCE_GROUP",
  "workspace_name": "YOUR_WORKSPACE_NAME",
  "table_name": "logs_CL",
  "schema_file": "schemas/logs_CL_schema.json",
  "plan": "Analytics",
  "retention_in_days": 30,
  "total_retention_in_days": 90
}
```

**Plans:**
- `Analytics` - Standard plan with full query capabilities and dynamic columns
- `Auxiliary` - Low-cost archival plan (no dynamic columns)

### DCR Config (`parameters/dcr/*.json`)
```json
{
  "resource_group": "YOUR_RESOURCE_GROUP",
  "dcr_name": "dcr-name",
  "location": "eastus",
  "template_file": "templates/dcr-template.json",
  "workspace_resource_id": "/subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/YOUR_WORKSPACE_NAME"
}
```

### Schema File (`schemas/*.json`)
```json
{
  "columns": [
    {"name": "TimeGenerated", "type": "datetime"},
    {"name": "message", "type": "string"},
    {"name": "log", "type": "dynamic"}
  ]
}
```

**Column Types:** `datetime`, `string`, `int`, `long`, `real`, `boolean`, `guid`, `dynamic` (Analytics only)

## DCR Templates

DCR templates define data ingestion with KQL transformations:

```json
{
  "streamDeclarations": {
    "Custom-logs_CL": {
      "columns": [...]
    }
  },
  "destinations": {
    "logAnalytics": [{
      "workspaceResourceId": "/subscriptions/.../workspaces/...",
      "name": "workspace-name"
    }]
  },
  "dataFlows": [{
    "streams": ["Custom-logs_CL"],
    "destinations": ["workspace-name"],
    "transformKql": "source | extend field = tostring(FIELD) | project-away FIELD",
    "outputStream": "Custom-logs_CL"
  }]
}
```

## Important Notes

- Custom tables must end with `_CL`
- Table names cannot contain hyphens (use underscores)
- Column names: 2-45 characters, alphanumeric + underscores only
- DCR and destination workspaces must be in same region
- Plan (Analytics/Auxiliary) cannot be changed after table creation
