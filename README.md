# Precision Medicine Engine

Precision Medicine Automation system built with n8n workflows, Neo4j graph database, Ollama local LLM, and OpenClaw for data aggregation.

## Architecture

```
User Query → n8n Webhook
                ↓
         Input Sanitization & PHI Detection
                ↓
        ┌───────┴────────┐
   PHI Detected?    No PHI
        ↓                ↓
  Ollama Redaction   ────┘
        ↓
  Neo4j Cache Check
        ↓
  ┌─────┴──────┐
 HIT         MISS
  ↓             ↓
Return      OpenClaw Fetch
Cached         ↓
Data      Ollama Validation
              ↓
         Store in Neo4j
              ↓
         ┌────┴────┐
     Entities  Relationships
         └────┬────┘
              ↓
         Audit Log → Neo4j
              ↓
         Return Response
```

## Workflows

### 1. Main Orchestrator (`precision_medicine_main_workflow.json`)
- Webhook intake for user queries
- Input sanitization and PHI detection
- Neo4j cache-first lookup
- OpenClaw external research (cache miss)
- Ollama-based data validation
- Neo4j entity and relationship storage
- Audit logging and compliance headers
- Scheduled daily maintenance (stale data cleanup, index verification, Ollama health check)

### 2. PHI Security Processor (`ollama_phi_security_workflow.json`)
- Dedicated sub-workflow for PHI operations
- Ollama-powered PHI redaction (all 18 HIPAA identifier types)
- Sensitivity classification
- Full audit trail stored in Neo4j
- Guaranteed local-only processing

### 3. Data Validation & Compliance (`data_validation_compliance_workflow.json`)
- Schema validation for Gene, Drug, Condition, and MedicalRecord types
- Ollama deep validation for medical accuracy assessment
- HIPAA compliance assessment with PHI leak detection
- Validation reports stored in Neo4j

## Prerequisites

- **n8n** (self-hosted)
- **Neo4j** with APOC plugin
- **Ollama** with `llama3.1:8b` model pulled
- **OpenClaw** API access

## Setup

1. Copy `.env.example` to `.env` and configure your credentials
2. Start Neo4j, Ollama, and n8n
3. Pull the Ollama model: `ollama pull llama3.1:8b`
4. Import the three workflow JSON files into n8n
5. Configure the Neo4j credential in n8n (id: `neo4j-cred-1`)
6. Activate the workflows

## API Usage

### Query the engine
```bash
curl -X POST http://localhost:5678/webhook/precision-medicine-query \
  -H "Content-Type: application/json" \
  -d '{"query": "BRCA1 gene therapy options", "user_id": "researcher-1"}'
```

### PHI redaction
```bash
curl -X POST http://localhost:5678/webhook/phi-security-process \
  -H "Content-Type: application/json" \
  -d '{"data": "Patient John Doe, DOB 01/15/1980, MRN AB123456", "operation": "redact"}'
```

### Data validation
```bash
curl -X POST http://localhost:5678/webhook/validate-medical-data \
  -H "Content-Type: application/json" \
  -d '{"records": [{"type": "Gene", "name": "BRCA1", "source": "pubmed"}], "validation_type": "full"}'
```

## Security

- All PHI processing uses Ollama locally -- no data leaves the environment
- HIPAA compliance checks run on every validation
- Full audit trail stored in Neo4j
- Input sanitization on all webhook endpoints
- Compliance headers on all responses
