-- Add this schema to the previous one for the embeddings service

-- Token usage tracking function
CREATE OR REPLACE FUNCTION increment_token_usage(
    p_tenant_id UUID,
    p_tokens INTEGER
) RETURNS VOID AS $$
BEGIN
    INSERT INTO public.tenant_stats (tenant_id, tokens_used, updated_at)
    VALUES (p_tenant_id, p_tokens, now())
    ON CONFLICT (tenant_id)
    DO UPDATE SET
        tokens_used = tenant_stats.tokens_used + p_tokens,
        updated_at = now();
END;
$$ LANGUAGE plpgsql;

-- Add embedding model preferences to tenant settings
ALTER TABLE public.tenant_features
ADD COLUMN IF NOT EXISTS preferred_embedding_model TEXT DEFAULT 'text-embedding-3-small';

-- Create embeddings cache metrics table (optional, for monitoring)
CREATE TABLE IF NOT EXISTS ai.embedding_metrics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    date_bucket DATE NOT NULL,
    model TEXT NOT NULL,
    total_requests INTEGER DEFAULT 0,
    cache_hits INTEGER DEFAULT 0,
    tokens_processed INTEGER DEFAULT 0,
    processing_time_ms INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Create index for faster metrics queries
CREATE INDEX IF NOT EXISTS idx_embedding_metrics_tenant
ON ai.embedding_metrics(tenant_id, date_bucket);

-- Add rate limiting fields to tenant features
ALTER TABLE public.tenant_features
ADD COLUMN IF NOT EXISTS rate_limit_per_min INTEGER DEFAULT 600;

-- Create rate limit exceptions table for special tenants
CREATE TABLE IF NOT EXISTS public.tenant_rate_limits (
    tenant_id UUID PRIMARY KEY REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    rate_limit_per_min INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    reason TEXT
);

-- Update the tokens_used column in tenant_stats to bigint for large usage
ALTER TABLE public.tenant_stats 
ALTER COLUMN tokens_used TYPE BIGINT;

-- Create embedding model options table
CREATE TABLE IF NOT EXISTS ai.embedding_models (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    provider TEXT NOT NULL,
    description TEXT,
    min_tier TEXT NOT NULL DEFAULT 'free',
    is_active BOOLEAN DEFAULT true
);

-- Insert default embedding models
INSERT INTO ai.embedding_models 
(id, name, dimensions, provider, description, min_tier) 
VALUES
('text-embedding-3-small', 'OpenAI Embedding Small', 1536, 'openai', 'Fast and efficient general purpose embedding model', 'free'),
('text-embedding-3-large', 'OpenAI Embedding Large', 3072, 'openai', 'High performance embedding model with better retrieval quality', 'pro')
ON CONFLICT (id) DO NOTHING;