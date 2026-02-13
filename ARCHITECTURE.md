# Precision Medicine Engine -- Architecture & Workflow Coordination

## System Overview

The Precision Medicine Engine is a modular automation system composed of three n8n workflows that coordinate to deliver secure, HIPAA-compliant medical data retrieval and storage. Each workflow operates independently but communicates through shared infrastructure (Neo4j, Ollama) and can invoke each other via n8n's internal webhook calls.

```
                         ┌──────────────────────────────────┐
                         │          User / Client           │
                         └──────────────┬───────────────────┘
                                        │ POST /webhook/precision-medicine-query
                                        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│                    WORKFLOW 1: Main Orchestrator                              │
│                                                                              │
│  ┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐              │
│  │   Webhook    │───▶│ Sanitize & PHI   │───▶│  PHI Router     │              │
│  │   Intake     │    │ Classification   │    │  (IF node)      │              │
│  └─────────────┘    └──────────────────┘    └───────┬─────────┘              │
│                                              YES ▼       ▼ NO                │
│                                        ┌──────────┐                          │
│                         ┌──────────────│  Ollama   │                         │
│                         │   Redacted   │ llama3.1  │                         │
│                         │    Query     │ PHI Redact│                         │
│                         │              └──────────┘                          │
│                         ▼                    │                                │
│                    ┌─────────────────────────▼──────────┐                    │
│                    │  DeepSeek Coder v2                  │                    │
│                    │  Generates dynamic Cypher query     │                    │
│                    │  from natural language              │                    │
│                    └───────────────┬────────────────────┘                    │
│                                   ▼                                          │
│                    ┌─────────────────────────────────┐                       │
│                    │  Validate & Sanitize Cypher      │                       │
│                    │  - Strip write operations        │                       │
│                    │  - Enforce LIMIT                 │                       │
│                    │  - Fallback to safe query        │                       │
│                    └───────────────┬─────────────────┘                       │
│                                   ▼                                          │
│                    ┌─────────────────────────────────┐                       │
│                    │  Execute Dynamic Cypher          │                       │
│                    │  against Neo4j                   │                       │
│                    └───────────────┬─────────────────┘                       │
│                                   ▼                                          │
│                    ┌──────────────────────────────────┐                      │
│                    │  Cache Hit Router (IF node)       │                      │
│                    └──────┬───────────────┬───────────┘                      │
│                   HIT ▼              MISS ▼                                  │
│              ┌──────────────┐  ┌──────────────────┐                         │
│              │Format Cached  │  │ OpenClaw External │                         │
│              │Response       │  │ Research Fetch    │                         │
│              └──────┬───────┘  └────────┬─────────┘                         │
│                     │                   ▼                                     │
│                     │         ┌──────────────────┐                           │
│                     │         │ Process Results   │                           │
│                     │         └────────┬─────────┘                           │
│                     │                  ▼                                      │
│                     │         ┌──────────────────┐                           │
│                     │         │ Ollama Validate   │                           │
│                     │         │ (llama3.1:8b)     │                           │
│                     │         └────────┬─────────┘                           │
│                     │                  ▼                                      │
│                     │         ┌──────────────────┐                           │
│                     │         │ Store in Neo4j    │                           │
│                     │         │ (Entities + Rels) │                           │
│                     │         └────────┬─────────┘                           │
│                     │                  │                                      │
│                     ▼                  ▼                                      │
│              ┌───────────────────────────────────┐                           │
│              │  Audit Log Entry → Neo4j           │                           │
│              └───────────────┬───────────────────┘                           │
│                              ▼                                               │
│              ┌───────────────────────────────────┐                           │
│              │  Respond to User (webhook response)│                           │
│              └───────────────────────────────────┘                           │
│                                                                              │
│  ── Maintenance Lane (24h schedule) ──────────────────────────────────────── │
│  [Schedule Trigger] → [Cleanup Stale Data] → [Verify Indexes] →             │
│  [Ollama Health Check] → [Maintenance Report]                                │
│                                                                              │
└───────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────────────┐
│                    WORKFLOW 2: Ollama PHI Security Processor                  │
│                                                                              │
│  Endpoint: POST /webhook/phi-security-process                                │
│                                                                              │
│  ┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐              │
│  │   Webhook    │───▶│ Classify PHI     │───▶│  Operation      │              │
│  │   Intake     │    │ Input            │    │  Router         │              │
│  └─────────────┘    └──────────────────┘    └───────┬─────────┘              │
│                                          "redact" ▼    ▼ "classify"          │
│                                        ┌──────────┐  ┌──────────────┐        │
│                                        │  Ollama   │  │  Ollama      │        │
│                                        │  Redact   │  │  Classify    │        │
│                                        │  All 18   │  │  Sensitivity │        │
│                                        │  PHI types│  │  Level       │        │
│                                        └────┬─────┘  └──────┬───────┘        │
│                                             ▼               ▼                │
│                                        ┌────────────────────────────┐        │
│                                        │ PHI Audit Trail → Neo4j    │        │
│                                        └────────────┬───────────────┘        │
│                                                     ▼                        │
│                                        ┌────────────────────────────┐        │
│                                        │ Response (LOCAL_ONLY)      │        │
│                                        └────────────────────────────┘        │
│                                                                              │
└───────────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────────────┐
│                    WORKFLOW 3: Data Validation & Compliance                   │
│                                                                              │
│  Endpoint: POST /webhook/validate-medical-data                               │
│                                                                              │
│  ┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐              │
│  │   Webhook    │───▶│ Schema           │───▶│  Full Validation │              │
│  │   Intake     │    │ Validation       │    │  Router          │              │
│  └─────────────┘    └──────────────────┘    └───────┬──────────┘             │
│                                          "full" ▼     ▼ "schema"             │
│                                        ┌──────────┐  ┌──────────────┐        │
│                                        │  Ollama   │  │  Schema Only │        │
│                                        │  Deep     │  │  Result      │        │
│                                        │  Validate │  │              │        │
│                                        └────┬─────┘  └──────┬───────┘        │
│                                             ▼               ▼                │
│                                        ┌────────────────────────────┐        │
│                                        │ HIPAA Compliance Assessment │        │
│                                        │ + PHI Leak Detection        │        │
│                                        └────────────┬───────────────┘        │
│                                                     ▼                        │
│                                        ┌────────────────────────────┐        │
│                                        │ Store Report → Neo4j       │        │
│                                        └────────────┬───────────────┘        │
│                                                     ▼                        │
│                                        ┌────────────────────────────┐        │
│                                        │ Validation Response         │        │
│                                        └────────────────────────────┘        │
│                                                                              │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## Workflow Coordination Model

### Inter-Workflow Communication

The three workflows coordinate through two mechanisms:

1. **Shared Neo4j Graph Database** -- All workflows read from and write to the same Neo4j instance. Data stored by Workflow 1 (main orchestrator) is available to Workflow 3 (validation) and vice versa. Audit logs from all three workflows coexist in the same graph.

2. **Internal Webhook Calls** -- Workflow 1 can invoke Workflow 2 (PHI security) and Workflow 3 (validation) via their webhook endpoints when needed. This keeps each workflow focused on a single responsibility.

### Data Flow Sequence

```
1. User sends query → Workflow 1 (Main Orchestrator)
2. If PHI detected → Workflow 1 calls Ollama (llama3.1:8b) inline for redaction
                      OR calls Workflow 2 for advanced PHI operations
3. DeepSeek Coder v2 generates context-aware Cypher query from natural language
4. Cypher query is validated/sanitized (write ops blocked, LIMIT enforced)
5. Dynamic Cypher executes against Neo4j
6. If cache HIT → return cached data immediately
7. If cache MISS → OpenClaw fetches from external sources
8. Ollama validates fetched data for medical accuracy
9. Validated data stored in Neo4j as graph (entities + relationships)
10. Audit log written → response returned to user
```

---

## Local LLM Allocation (Ollama)

The system uses two distinct local models, each with a specific role:

| Model | Purpose | Used In | Temperature |
|-------|---------|---------|-------------|
| **llama3.1:8b** | PHI redaction, data validation, sensitivity classification | Workflows 1, 2, 3 | 0.0 - 0.1 |
| **deepseek-coder-v2** | Dynamic Cypher query generation from natural language | Workflow 1 | 0.1 |

### Why Two Models?

- **llama3.1:8b** excels at natural language understanding, privacy-sensitive text processing, and medical terminology -- ideal for PHI handling and clinical data validation.
- **deepseek-coder-v2** is specialized for code generation tasks -- it produces syntactically correct Cypher queries that precisely match the graph schema, with fewer hallucinated properties or invalid syntax compared to general-purpose models.

### Cypher Generation Safety

The DeepSeek-generated Cypher passes through a mandatory sanitization layer:

1. **Write operation blocking** -- Any query containing `CREATE`, `MERGE`, `DELETE`, `SET`, `REMOVE`, `DROP`, or `CALL {}` is rejected and replaced with a safe fallback query.
2. **LIMIT enforcement** -- If the generated query lacks a `LIMIT` clause, one is appended automatically.
3. **Structure validation** -- Queries must begin with `MATCH`, `OPTIONAL`, or `CALL` to be accepted.
4. **Fallback query** -- On any validation failure, a generic safe search across all node names and descriptions is used instead.

---

## Neo4j Graph Schema

```
(:Gene {name, symbol, chromosome, description, source, ncbi_id, data})
(:Drug {name, generic_name, brand_name, mechanism, indications, drugbank_id, source, data})
(:Condition {name, icd10_code, description, category, omim_id, source, data})
(:MedicalRecord {name, description, source, data, type})
(:AuditLog {event_type, session_id, timestamp, source, cache_status, result_count, phi_detected})
(:PHIAuditLog {audit_id, operation, timestamp, processing_location, model_used, data_egress, session_id})
(:ValidationReport {session_id, timestamp, overall_valid, total_records, quality_score, hipaa_compliant})

Relationships:
  -[:RELATES_TO]->
  -[:TREATS]->        (Drug → Condition)
  -[:TARGETS]->       (Drug → Gene)
  -[:ASSOCIATED_WITH]->
  -[:INTERACTS_WITH]-> (Drug → Drug)
  -[:CAUSES]->
  -[:PREVENTS]->       (Drug → Condition)
```

All entity nodes carry `created_at` and `updated_at` timestamps. Stale data (older than 30 days, excluding audit logs) is purged by the daily maintenance schedule.

---

## Security Architecture

### Data Classification & Routing

```
Incoming Query
      │
      ▼
PHI Pattern Detection (regex-based)
      │
  ┌───┴───┐
  │ PHI   │ No PHI
  ▼       ▼
Ollama    Direct to
Redaction DeepSeek/Neo4j
(local)
  │
  ▼
Redacted query continues through pipeline
(original PHI never leaves local environment)
```

### Security Guarantees

| Guarantee | Implementation |
|-----------|----------------|
| PHI never leaves local env | All Ollama calls target `localhost:11434` |
| No cloud LLM for sensitive data | llama3.1:8b and deepseek-coder-v2 both run locally |
| Read-only graph queries | DeepSeek output sanitized; write ops blocked |
| Full audit trail | Every query, PHI operation, and validation logged to Neo4j |
| Input sanitization | XSS/injection chars stripped; max 2000 char limit |
| Compliance headers | Every response includes `X-Compliance`, `X-Cache-Status`, `X-Session-Id` |

### HIPAA Compliance Checklist

- [x] PHI identified and redacted before external processing
- [x] All 18 HIPAA identifier types covered in redaction
- [x] Local-only processing for sensitive data
- [x] Audit trail for every PHI operation
- [x] Data retention policy (30-day auto-cleanup)
- [x] PHI leak detection in validation output
- [x] Sensitivity classification available

---

## Scalability & Modularity

### Adding a New Workflow

Each workflow is a standalone JSON file that can be imported independently into n8n. To add a new capability:

1. Create a new workflow JSON with a webhook trigger
2. Define its Neo4j node types (if any) in the graph schema
3. Register its indexes in the daily maintenance cleanup
4. Connect it to existing workflows via webhook calls or shared Neo4j data

### Scaling Components Independently

| Component | Scaling Strategy |
|-----------|-----------------|
| n8n | Multiple workers with shared database backend |
| Neo4j | Causal clustering for read replicas |
| Ollama | Multiple instances behind a load balancer; GPU acceleration |
| OpenClaw | Configurable via `OPENCLAW_API_URL`; swap or add providers |

### Maintenance Automation

The daily maintenance lane in Workflow 1 handles:
- Stale data cleanup (configurable retention via `DATA_RETENTION_DAYS`)
- Neo4j index verification and creation
- Ollama health monitoring with alerting on failure
