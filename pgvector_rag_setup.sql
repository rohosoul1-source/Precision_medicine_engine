-- ============================================================================
-- PRECISION MEDICINE ENGINE - PostgreSQL + pgvector RAG Setup
-- ============================================================================
-- Purpose: Initializes PostgreSQL with pgvector extension for the RAG
--          (Retrieval-Augmented Generation) system used by the main orchestrator.
--
-- Prerequisites:
--   - PostgreSQL 15+ installed locally
--   - pgvector extension available (apt install postgresql-15-pgvector)
--   - Run as superuser or a role with CREATE EXTENSION privileges
--
-- Embedding Model: Ollama nomic-embed-text (768 dimensions)
-- Connection: postgresql://precision_med:precision_med@localhost:5432/precision_medicine_rag
--
-- Tables:
--   1. query_embeddings   - Stores user query vectors for semantic search
--   2. document_chunks    - Stores chunked OpenClaw research data as vectors
--   3. rag_sessions       - Tracks RAG retrieval sessions for analytics
--   4. embedding_metadata - Relational metadata for sources, timestamps, etc.
-- ============================================================================

-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable pg_trgm for hybrid text+vector search
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================================
-- TABLE: query_embeddings
-- Stores embeddings of user queries for semantic similarity matching.
-- When a new query comes in, we search this table to find similar past queries
-- and retrieve their associated results as RAG context.
-- ============================================================================
CREATE TABLE IF NOT EXISTS query_embeddings (
    id              BIGSERIAL PRIMARY KEY,
    session_id      VARCHAR(255) NOT NULL,
    user_id         VARCHAR(255) DEFAULT 'anonymous',
    query_text      TEXT NOT NULL,
    query_embedding vector(768) NOT NULL,       -- nomic-embed-text outputs 768 dims
    result_summary  TEXT,                        -- summary of what was returned
    result_data     JSONB,                       -- full result payload for RAG retrieval
    source          VARCHAR(50) DEFAULT 'user',  -- 'user', 'system', 'openclaw'
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- TABLE: document_chunks
-- Stores chunked and embedded research documents from OpenClaw and other sources.
-- Each research result is split into semantically meaningful chunks, embedded,
-- and stored here for fine-grained vector retrieval.
-- ============================================================================
CREATE TABLE IF NOT EXISTS document_chunks (
    id              BIGSERIAL PRIMARY KEY,
    entity_name     VARCHAR(500),                -- gene/drug/condition name
    entity_type     VARCHAR(50),                 -- 'Gene', 'Drug', 'Condition', 'MedicalRecord'
    chunk_text      TEXT NOT NULL,                -- the actual text chunk
    chunk_embedding vector(768) NOT NULL,         -- nomic-embed-text embedding
    chunk_index     INTEGER DEFAULT 0,            -- position within parent document
    parent_doc_id   VARCHAR(255),                 -- reference to source document
    source          VARCHAR(100),                 -- 'pubmed', 'drugbank', 'clinicaltrials', etc.
    metadata        JSONB DEFAULT '{}',           -- flexible metadata (citations, IDs, etc.)
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- TABLE: rag_sessions
-- Tracks each RAG retrieval event for analytics and debugging.
-- Records what was retrieved, similarity scores, and whether the RAG context
-- was actually useful (based on downstream feedback).
-- ============================================================================
CREATE TABLE IF NOT EXISTS rag_sessions (
    id                  BIGSERIAL PRIMARY KEY,
    session_id          VARCHAR(255) NOT NULL,
    query_text          TEXT NOT NULL,
    retrieval_type      VARCHAR(50) NOT NULL,      -- 'query_similarity', 'document_chunk', 'hybrid'
    results_count       INTEGER DEFAULT 0,
    avg_similarity      REAL,
    top_similarity      REAL,
    retrieval_time_ms   INTEGER,
    context_used        BOOLEAN DEFAULT TRUE,       -- whether RAG context was included in response
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- TABLE: embedding_metadata
-- Relational metadata linking embeddings to their sources.
-- Enables joins between vector results and structured source data.
-- ============================================================================
CREATE TABLE IF NOT EXISTS embedding_metadata (
    id              BIGSERIAL PRIMARY KEY,
    embedding_type  VARCHAR(50) NOT NULL,          -- 'query' or 'document_chunk'
    embedding_id    BIGINT NOT NULL,               -- FK to query_embeddings.id or document_chunks.id
    source_type     VARCHAR(100),                  -- 'pubmed', 'drugbank', 'openclaw', etc.
    source_id       VARCHAR(255),                  -- external ID (PMID, DrugBank ID, etc.)
    source_url      TEXT,                          -- link to original source
    citation        TEXT,                          -- formatted citation
    tags            TEXT[] DEFAULT '{}',           -- searchable tags
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- INDEXES: Vector similarity search (IVFFlat for performance at scale)
-- IVFFlat is chosen over HNSW for lower memory usage on local deployments.
-- lists = 100 is suitable for up to ~100K vectors. Increase for larger datasets.
-- ============================================================================

-- Cosine similarity index on query embeddings
CREATE INDEX IF NOT EXISTS idx_query_embeddings_vector
    ON query_embeddings
    USING ivfflat (query_embedding vector_cosine_ops)
    WITH (lists = 100);

-- Cosine similarity index on document chunks
CREATE INDEX IF NOT EXISTS idx_document_chunks_vector
    ON document_chunks
    USING ivfflat (chunk_embedding vector_cosine_ops)
    WITH (lists = 100);

-- ============================================================================
-- INDEXES: Relational lookups (B-tree for exact matches, GIN for JSONB/text)
-- ============================================================================

-- Query embeddings
CREATE INDEX IF NOT EXISTS idx_query_embeddings_session
    ON query_embeddings (session_id);
CREATE INDEX IF NOT EXISTS idx_query_embeddings_created
    ON query_embeddings (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_query_embeddings_source
    ON query_embeddings (source);

-- Document chunks
CREATE INDEX IF NOT EXISTS idx_document_chunks_entity
    ON document_chunks (entity_name, entity_type);
CREATE INDEX IF NOT EXISTS idx_document_chunks_source
    ON document_chunks (source);
CREATE INDEX IF NOT EXISTS idx_document_chunks_created
    ON document_chunks (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_document_chunks_metadata
    ON document_chunks USING gin (metadata);

-- Trigram index for hybrid text+vector search on chunk_text
CREATE INDEX IF NOT EXISTS idx_document_chunks_text_trgm
    ON document_chunks USING gin (chunk_text gin_trgm_ops);

-- RAG sessions
CREATE INDEX IF NOT EXISTS idx_rag_sessions_session
    ON rag_sessions (session_id);
CREATE INDEX IF NOT EXISTS idx_rag_sessions_created
    ON rag_sessions (created_at DESC);

-- Embedding metadata
CREATE INDEX IF NOT EXISTS idx_embedding_metadata_type_id
    ON embedding_metadata (embedding_type, embedding_id);
CREATE INDEX IF NOT EXISTS idx_embedding_metadata_source
    ON embedding_metadata (source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_embedding_metadata_tags
    ON embedding_metadata USING gin (tags);

-- ============================================================================
-- FUNCTIONS: Utility functions for RAG operations
-- ============================================================================

-- Function: Search similar queries (used by n8n RAG retrieval node)
-- Returns top-K most similar past queries with their stored results.
-- Similarity threshold: 0.7 cosine similarity (configurable in n8n).
CREATE OR REPLACE FUNCTION search_similar_queries(
    query_vec vector(768),
    similarity_threshold REAL DEFAULT 0.7,
    max_results INTEGER DEFAULT 5
)
RETURNS TABLE (
    id BIGINT,
    query_text TEXT,
    result_summary TEXT,
    result_data JSONB,
    similarity REAL,
    source VARCHAR(50),
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        qe.id,
        qe.query_text,
        qe.result_summary,
        qe.result_data,
        (1 - (qe.query_embedding <=> query_vec))::REAL AS similarity,
        qe.source,
        qe.created_at
    FROM query_embeddings qe
    WHERE (1 - (qe.query_embedding <=> query_vec)) >= similarity_threshold
    ORDER BY qe.query_embedding <=> query_vec ASC
    LIMIT max_results;
END;
$$ LANGUAGE plpgsql;

-- Function: Search similar document chunks (semantic search over research data)
CREATE OR REPLACE FUNCTION search_similar_chunks(
    query_vec vector(768),
    similarity_threshold REAL DEFAULT 0.6,
    max_results INTEGER DEFAULT 10,
    filter_entity_type VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT,
    entity_name VARCHAR(500),
    entity_type VARCHAR(50),
    chunk_text TEXT,
    source VARCHAR(100),
    metadata JSONB,
    similarity REAL,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        dc.id,
        dc.entity_name,
        dc.entity_type,
        dc.chunk_text,
        dc.source,
        dc.metadata,
        (1 - (dc.chunk_embedding <=> query_vec))::REAL AS similarity,
        dc.created_at
    FROM document_chunks dc
    WHERE (1 - (dc.chunk_embedding <=> query_vec)) >= similarity_threshold
      AND (filter_entity_type IS NULL OR dc.entity_type = filter_entity_type)
    ORDER BY dc.chunk_embedding <=> query_vec ASC
    LIMIT max_results;
END;
$$ LANGUAGE plpgsql;

-- Function: Hybrid search combining text trigram + vector similarity
CREATE OR REPLACE FUNCTION hybrid_search(
    search_text TEXT,
    query_vec vector(768),
    text_weight REAL DEFAULT 0.3,
    vector_weight REAL DEFAULT 0.7,
    max_results INTEGER DEFAULT 10
)
RETURNS TABLE (
    id BIGINT,
    entity_name VARCHAR(500),
    entity_type VARCHAR(50),
    chunk_text TEXT,
    source VARCHAR(100),
    combined_score REAL,
    text_score REAL,
    vector_score REAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        dc.id,
        dc.entity_name,
        dc.entity_type,
        dc.chunk_text,
        dc.source,
        (text_weight * similarity(dc.chunk_text, search_text)
         + vector_weight * (1 - (dc.chunk_embedding <=> query_vec))::REAL)::REAL AS combined_score,
        similarity(dc.chunk_text, search_text)::REAL AS text_score,
        (1 - (dc.chunk_embedding <=> query_vec))::REAL AS vector_score
    FROM document_chunks dc
    WHERE dc.chunk_text % search_text
       OR (1 - (dc.chunk_embedding <=> query_vec)) >= 0.5
    ORDER BY combined_score DESC
    LIMIT max_results;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MAINTENANCE: Cleanup function for stale embeddings (called by n8n daily)
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_stale_embeddings(
    max_age_days INTEGER DEFAULT 90
)
RETURNS TABLE (
    queries_removed BIGINT,
    chunks_removed BIGINT,
    sessions_removed BIGINT
) AS $$
DECLARE
    q_count BIGINT;
    c_count BIGINT;
    s_count BIGINT;
BEGIN
    DELETE FROM query_embeddings
    WHERE created_at < NOW() - (max_age_days || ' days')::INTERVAL;
    GET DIAGNOSTICS q_count = ROW_COUNT;

    DELETE FROM document_chunks
    WHERE created_at < NOW() - (max_age_days || ' days')::INTERVAL;
    GET DIAGNOSTICS c_count = ROW_COUNT;

    DELETE FROM rag_sessions
    WHERE created_at < NOW() - (max_age_days || ' days')::INTERVAL;
    GET DIAGNOSTICS s_count = ROW_COUNT;

    RETURN QUERY SELECT q_count, c_count, s_count;
END;
$$ LANGUAGE plpgsql;
