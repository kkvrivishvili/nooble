-- Add this schema to the previous ones for the query service

-- Create query logs table for analytics
CREATE TABLE IF NOT EXISTS ai.query_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    query TEXT NOT NULL,
    collection TEXT,
    llm_model TEXT NOT NULL,
    tokens_estimated INTEGER,
    response_time_ms INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Create index for faster query log retrieval
CREATE INDEX IF NOT EXISTS idx_query_logs_tenant_created
ON ai.query_logs(tenant_id, created_at DESC);

-- Create table for favorite responses
CREATE TABLE IF NOT EXISTS ai.saved_responses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    user_id UUID, -- Optional link to a specific user if implemented
    query TEXT NOT NULL,
    response TEXT NOT NULL,
    sources JSONB,
    llm_model TEXT NOT NULL,
    collection_name TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    tags TEXT[]
);

-- Create index for faster saved response retrieval
CREATE INDEX IF NOT EXISTS idx_saved_responses_tenant
ON ai.saved_responses(tenant_id);

-- Create LLM model configurations table
CREATE TABLE IF NOT EXISTS ai.llm_models (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    provider TEXT NOT NULL,
    description TEXT,
    min_tier TEXT NOT NULL DEFAULT 'free',
    is_active BOOLEAN DEFAULT true,
    settings JSONB DEFAULT '{}'::jsonb
);

-- Insert default LLM models
INSERT INTO ai.llm_models 
(id, name, provider, description, min_tier) 
VALUES
('gpt-3.5-turbo', 'GPT-3.5 Turbo', 'openai', 'Fast and cost-effective model for most queries', 'free'),
('gpt-4-turbo', 'GPT-4 Turbo', 'openai', 'Advanced reasoning capabilities for complex queries', 'pro'),
('gpt-4-turbo-vision', 'GPT-4 Turbo Vision', 'openai', 'Vision capabilities for image analysis', 'business'),
('claude-3-5-sonnet', 'Claude 3.5 Sonnet', 'anthropic', 'Alternative model with excellent instruction following', 'business')
ON CONFLICT (id) DO NOTHING;

-- Add query rate limit fields
ALTER TABLE public.tenant_features
ADD COLUMN IF NOT EXISTS query_rate_limit_per_day INTEGER DEFAULT 100;

-- Create function for building default RAG prompts
CREATE OR REPLACE FUNCTION get_default_rag_prompt(
    p_tenant_id UUID
) RETURNS TEXT AS $$
DECLARE
    tenant_name TEXT;
    prompt_template TEXT;
BEGIN
    -- Get tenant name
    SELECT name INTO tenant_name
    FROM public.tenants
    WHERE tenant_id = p_tenant_id;
    
    -- Build default prompt template
    prompt_template := 'You are an AI assistant for ' || 
                      COALESCE(tenant_name, 'the organization') || 
                      '. Answer the following query based only on the provided context. ' ||
                      'If you cannot find the answer in the context, say "I don''t have enough information to answer this question." ' ||
                      'Don''t try to make up an answer. ' ||
                      'Always cite the source of your information from the provided context.\n\n' ||
                      'Context: {context}\n\n' ||
                      'Query: {query}\n\n' ||
                      'Answer: ';
    
    RETURN prompt_template;
END;
$$ LANGUAGE plpgsql;

-- Create prompt templates table for custom prompts
CREATE TABLE IF NOT EXISTS ai.prompt_templates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(tenant_id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    template TEXT NOT NULL,
    description TEXT,
    is_default BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Create unique index for default prompt templates per tenant
CREATE UNIQUE INDEX IF NOT EXISTS idx_default_prompt_template
ON ai.prompt_templates(tenant_id) WHERE is_default = true;

-- Enable Row-Level Security for query-related tables
ALTER TABLE ai.query_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai.saved_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai.prompt_templates ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY tenant_isolation_query_logs ON ai.query_logs
    FOR ALL
    USING (tenant_id = auth.uid()::uuid);

CREATE POLICY tenant_isolation_saved_responses ON ai.saved_responses
    FOR ALL
    USING (tenant_id = auth.uid()::uuid);

CREATE POLICY tenant_isolation_prompt_templates ON ai.prompt_templates
    FOR ALL
    USING (tenant_id = auth.uid()::uuid);