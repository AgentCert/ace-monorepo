# Capabilities Vocabulary Reference

Summary of all capability keys from spec §10. Full YAML content goes in `catalog/capabilities/*.yaml`.

---

## common.yaml

| Key | Category | Description |
|-----|----------|-------------|
| `http-probe` | observe | Issue HTTP requests to check endpoint health |
| `generic-api-query` | observe | Query any REST or GraphQL API |
| `webhook-notify` | act | Send notifications via webhook (Slack, PagerDuty, Teams) |
| `email-notify` | act | Send email notifications to on-call teams |

---

## cloud-native.yaml

| Key | Category | Description |
|-----|----------|-------------|
| `prometheus-query` | observe | Issue PromQL queries to Prometheus |
| `kubernetes-get-pods` | observe | List and describe pods in a namespace |
| `kubernetes-get-events` | observe | List Kubernetes events |
| `kubernetes-describe` | observe | Describe any Kubernetes resource |
| `log-query` | observe | Query container/application logs |
| `service-mesh-aware` | observe | Query Istio/Envoy metrics and policies |
| `kubernetes-patch` | act | Patch K8s resources |
| `kubernetes-delete` | act | Delete K8s resources |
| `kubernetes-restart` | act | Rollout restart deployments/statefulsets |
| `kubernetes-resource-quota` | act | Manage ResourceQuota objects |
| `kubernetes-scale` | act | Scale Deployment/StatefulSet replicas |

---

## telecom.yaml

| Key | Category | Description |
|-----|----------|-------------|
| `snmp-query` | observe | Query network device OIDs via SNMP v2c/v3 |
| `netconf-get` | observe | Fetch device config via NETCONF/YANG |
| `alarm-query` | observe | Query network alarm management system |
| `topology-traverse` | observe | Navigate network topology graph |
| `syslog-query` | observe | Query syslog servers for device errors |
| `pm-counter-query` | observe | Query 3GPP PM counters |
| `netconf-edit-config` | act | Push config changes via NETCONF |
| `config-rollback` | act | Rollback device/NF configuration |
| `interface-admin-state` | act | Administratively enable/disable interface |
| `route-policy-update` | act | Update routing policies (BGP, OSPF, SR-MPLS) |
| `nf-restart` | act | Trigger restart of containerized network function |

---

## health-it.yaml

| Key | Category | Description |
|-----|----------|-------------|
| `fhir-read` | observe | Read FHIR R4 resources from a FHIR server |
| `hl7-parse` | observe | Parse HL7 v2.x messages |
| `patient-monitor-query` | observe | Query patient monitoring for vital sign anomalies |
| `clinical-alert-query` | observe | Query clinical decision support alert queue |
| `audit-log-query` | observe | Query HIPAA audit logs for access anomalies |
| `fhir-write` | act | Create or update FHIR resources |
| `adt-trigger` | act | Trigger Admit/Discharge/Transfer workflow |
| `alert-acknowledge` | act | Acknowledge or escalate a clinical alert |

---

## finops.yaml

| Key | Category | Description |
|-----|----------|-------------|
| `cost-api-query` | observe | Query cloud provider cost APIs or OpenCost |
| `budget-alert-query` | observe | Query budget thresholds and forecasts |
| `resource-inventory-query` | observe | Enumerate cloud resources for rightsizing |
| `tag-compliance-check` | observe | Identify untagged/mis-tagged cloud resources |
| `rightsizing-apply` | act | Apply resource rightsizing recommendations |
| `resource-tag-update` | act | Update cost allocation tags on cloud resources |
| `idle-resource-stop` | act | Stop or terminate idle cloud resources |

---

## itops.yaml

| Key | Category | Description |
|-----|----------|-------------|
| `cmdb-query` | observe | Query a CMDB for asset records and relationships |
| `monitoring-alert-query` | observe | Query monitoring system for active alerts |
| `log-aggregator-query` | observe | Query centralized log systems for error patterns |
| `change-calendar-query` | observe | Query change management calendar |
| `ticket-create` | act | Create incident/problem ticket in ITSM system |
| `ticket-update` | act | Update existing incident ticket |
| `runbook-execute` | act | Trigger automated runbook |
| `cmdb-update` | act | Update CMDB configuration item attributes |

---

**Total capability keys: 40**

**Last Updated:** 2026-07-07
