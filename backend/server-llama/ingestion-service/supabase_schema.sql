-- Schema: public
-- Tables for tenant management

-- Tenants table
CREATE TABLE public.tenants (
    tenant_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    is_active BOOLEAN DEFAULT true
);

-- Tenant subscriptions
CREATE TABLE public.tenant_subscriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    subscription_tier TEXT NOT NULL CHECK (subscription_tier IN ('free', 'pro', 'business')),
    is_active BOOLEAN DEFAULT true,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    expires_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Tenant features and limits
CREATE TABLE public.tenant_features (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tier TEXT UNIQUE NOT NULL CHECK (tier IN ('free', 'pro', 'business')),
    max_docs INTEGER NOT NULL,
    max_knowledge_bases INTEGER NOT NULL,
    has_advanced_rag BOOLEAN DEFAULT false,
    max_tokens_per_month INTEGER,
    settings JSONB DEFAULT '{}'::jsonb
);

-- Tenant usage statistics
CREATE TABLE public.tenant_stats (
    tenant_id UUID PRIMARY KEY REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    document_count INTEGER DEFAULT 0,
    tokens_used INTEGER DEFAULT 0,
    last_activity TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Schema: ai
-- Tables for AI functionality

-- Document chunks table with vector support
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE ai.document_chunks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    embedding VECTOR(1536),  -- For OpenAI embeddings
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Create index for faster vector similarity search
CREATE INDEX ON ai.document_chunks USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- Create index for tenant filtering
CREATE INDEX document_chunks_tenant_id_idx ON ai.document_chunks(tenant_id);

-- Functions for tenant statistics
CREATE OR REPLACE FUNCTION increment_document_count(
    p_tenant_id UUID,
    p_count INTEGER DEFAULT 1
) RETURNS VOID AS $$
BEGIN
    INSERT INTO public.tenant_stats (tenant_id, document_count, updated_at)
    VALUES (p_tenant_id, p_count, now())
    ON CONFLICT (tenant_id)
    DO UPDATE SET
        document_count = tenant_stats.document_count + p_count,
        updated_at = now();
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION decrement_document_count(
    p_tenant_id UUID,
    p_count INTEGER DEFAULT 1
) RETURNS VOID AS $$
BEGIN
    UPDATE public.tenant_stats
    SET document_count = GREATEST(0, document_count - p_count),
        updated_at = now()
    WHERE tenant_id = p_tenant_id;
END;
$$ LANGUAGE plpgsql;

-- Row-level security policies
-- Ensure tenants can only access their own data

-- Enable RLS on tables
ALTER TABLE ai.document_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_stats ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY tenant_isolation_policy ON ai.document_chunks
    FOR ALL
    USING (tenant_id = auth.uid()::uuid);

CREATE POLICY tenant_stats_policy ON public.tenant_stats
    FOR ALL
    USING (tenant_id = auth.uid()::uuid);

-- Initial data for tenant features
INSERT INTO public.tenant_features (tier, max_docs, max_knowledge_bases, has_advanced_rag, max_tokens_per_month)
VALUES 
    ('free', 20, 1, false, 100000),
    ('pro', 100, 5, true, 1000000),
    ('business', 500, 20, true, NULL);