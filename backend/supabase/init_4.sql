-- ARCHIVO: init.sql PARTE 4 - Tablas para RAG
-- Propósito: Crear tablas relacionadas con el sistema de Retrieval Augmented Generation

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS bots CASCADE;
DROP TABLE IF EXISTS document_collections CASCADE;
DROP TABLE IF EXISTS documents CASCADE;
DROP TABLE IF EXISTS document_chunks CASCADE;
DROP TABLE IF EXISTS bot_collections CASCADE;
DROP TABLE IF EXISTS conversations CASCADE;
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS bot_response_feedback CASCADE;
DROP TABLE IF EXISTS vector_analytics CASCADE;

-- Tabla para los bots personalizados de cada usuario
CREATE TABLE IF NOT EXISTS bots (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name VARCHAR(50) NOT NULL,
  description TEXT,
  avatar_url TEXT CHECK (avatar_url IS NULL OR avatar_url ~* '^https?://.*$'),
  system_prompt TEXT NOT NULL DEFAULT 'You are a helpful assistant.', -- Nuevo, valor por defecto
  temperature NUMERIC(3,2) CHECK (temperature BETWEEN 0 AND 2) DEFAULT 0.7, -- Nuevo, parámetro de modelo
  max_tokens INTEGER CHECK (max_tokens BETWEEN 10 AND 32000) DEFAULT 4096, -- Nuevo, parámetro de modelo
  model_config JSONB NOT NULL DEFAULT '{}',
  is_public BOOLEAN DEFAULT FALSE, -- Nuevo para community sharing
  category VARCHAR(50), -- Nuevo para categorización
  tags TEXT[], -- Nuevo para búsquedas
  version INTEGER DEFAULT 1, -- Nuevo para versionado
  popularity_score INTEGER DEFAULT 0, -- Nuevo para ranking
  is_active BOOLEAN DEFAULT TRUE,
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índice único para nombres de bots por usuario
CREATE UNIQUE INDEX idx_unique_user_bot_name ON bots(user_id, name) WHERE deleted_at IS NULL;
-- Nuevos índices para búsqueda y categorización
CREATE INDEX idx_bots_tags ON bots USING gin(tags);
CREATE INDEX idx_bots_category ON bots(category) WHERE deleted_at IS NULL;
CREATE INDEX idx_bots_public ON bots(is_public, popularity_score DESC) WHERE is_public = TRUE AND deleted_at IS NULL;

-- Tabla para las colecciones de documentos
CREATE TABLE IF NOT EXISTS document_collections (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name VARCHAR(50) NOT NULL,
  description TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  is_public BOOLEAN DEFAULT FALSE,
  category VARCHAR(50), -- Nuevo para categorización
  tags TEXT[], -- Nuevo para búsquedas
  embedding_model VARCHAR(50) DEFAULT 'default', -- Nuevo para especificar modelo de embeddings
  chunk_size INTEGER DEFAULT 1000, -- Nuevo para configuración de chunking
  chunk_overlap INTEGER DEFAULT 200, -- Nuevo para configuración de chunking
  metadata_schema JSONB DEFAULT '{}', -- Nuevo para definir esquema de metadatos
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índice único para nombres de colecciones por usuario
CREATE UNIQUE INDEX idx_unique_user_collection_name ON document_collections(user_id, name) WHERE deleted_at IS NULL;
-- Nuevos índices para búsqueda
CREATE INDEX idx_collections_tags ON document_collections USING gin(tags);
CREATE INDEX idx_collections_category ON document_collections(category) WHERE deleted_at IS NULL;
CREATE INDEX idx_collections_public ON document_collections(is_public) WHERE is_public = TRUE AND deleted_at IS NULL;

-- Tabla para documentos individuales
CREATE TABLE IF NOT EXISTS documents (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  collection_id UUID NOT NULL REFERENCES document_collections(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  content TEXT NOT NULL,
  content_hash TEXT, -- Nuevo para detectar duplicados
  file_type VARCHAR(20), -- Nuevo para tipo de archivo original
  file_size INTEGER, -- Nuevo para tamaño en bytes
  source_url TEXT, -- Nuevo para origen del documento
  language VARCHAR(10), -- Nuevo para idioma
  metadata JSONB DEFAULT '{}',
  version INTEGER DEFAULT 1,
  processing_status VARCHAR(20) DEFAULT 'pending' CHECK (processing_status IN ('pending', 'processing', 'completed', 'error')), -- Nuevo para estado
  error_message TEXT, -- Nuevo para errores
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Nuevos índices para documentos
CREATE INDEX idx_documents_collection ON documents(collection_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_title_trgm ON documents USING gin (title gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_content_hash ON documents(content_hash) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_status ON documents(processing_status) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_metadata ON documents USING gin(metadata);

-- Tabla para chunks de documentos (para RAG)
CREATE TABLE IF NOT EXISTS document_chunks (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  content_vector vector(1536), -- Usamos un valor constante inicialmente
  content_hash TEXT, -- Nuevo para detectar duplicados
  content_tokens INTEGER, -- Nuevo para contar tokens
  chunk_index INTEGER NOT NULL,
  page_number INTEGER, -- Nuevo para documentos largos
  metadata JSONB DEFAULT '{}',
  relevance_score FLOAT, -- Nuevo para calidad del chunk
  version INTEGER DEFAULT 1,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Mejores índices para búsqueda vectorial
CREATE INDEX idx_document_chunks_document ON document_chunks(document_id);
CREATE INDEX idx_document_chunks_content_trgm ON document_chunks USING gin (content gin_trgm_ops);
CREATE INDEX idx_document_chunks_metadata ON document_chunks USING gin(metadata);

-- Tabla para asociar bots con colecciones de documentos
CREATE TABLE IF NOT EXISTS bot_collections (
  bot_id UUID NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
  collection_id UUID NOT NULL REFERENCES document_collections(id) ON DELETE CASCADE,
  weight FLOAT DEFAULT 1.0, -- Nuevo para ponderación
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(), -- Nuevo campo
  PRIMARY KEY(bot_id, collection_id)
);

-- Índice para búsquedas por colección
CREATE INDEX idx_bot_collections_collection ON bot_collections(collection_id);

-- Tabla para conversaciones con bots
CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  bot_id UUID NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
  title TEXT DEFAULT 'New Conversation',
  summary TEXT, -- Nuevo para resumir la conversación
  is_public BOOLEAN DEFAULT FALSE,
  is_pinned BOOLEAN DEFAULT FALSE, -- Nuevo para conversaciones importantes
  language VARCHAR(10), -- Nuevo para idioma
  metadata JSONB DEFAULT '{}',
  last_activity_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(), -- Nuevo para ordenar por actividad
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para conversaciones
CREATE INDEX idx_conversations_user ON conversations(user_id, last_activity_at DESC);
CREATE INDEX idx_conversations_bot ON conversations(bot_id);
CREATE INDEX idx_conversations_public ON conversations(is_public) WHERE is_public = TRUE;
CREATE INDEX idx_conversations_pinned ON conversations(user_id, is_pinned) WHERE is_pinned = TRUE;

-- Tabla para mensajes en conversaciones
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  is_user BOOLEAN NOT NULL,
  content TEXT NOT NULL,
  embedding vector(1536), -- Usamos un valor constante inicialmente
  tokens_used INTEGER, -- Nuevo para contar tokens
  latency_ms INTEGER, -- Nuevo para medir rendimiento
  source_message_id UUID REFERENCES messages(id) ON DELETE SET NULL, -- Nuevo para respuestas a mensajes específicos
  citation_sources JSONB DEFAULT '[]', -- Nuevo para fuentes citadas
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() -- Nuevo campo
);

-- Índices para mensajes
CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at);
CREATE INDEX idx_messages_source ON messages(source_message_id) WHERE source_message_id IS NOT NULL;

-- Tabla para feedback de respuestas de bots
CREATE TABLE IF NOT EXISTS bot_response_feedback (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  feedback_text TEXT,
  feedback_categories TEXT[], -- Nuevo para categorizar problemas
  fixed_by_message_id UUID REFERENCES messages(id) ON DELETE SET NULL, -- Nuevo para seguimiento de correcciones
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() -- Nuevo campo
);

-- Índices para feedback
CREATE INDEX idx_feedback_message ON bot_response_feedback(message_id);
CREATE INDEX idx_feedback_user ON bot_response_feedback(user_id);
CREATE INDEX idx_feedback_categories ON bot_response_feedback USING gin(feedback_categories);

-- Tabla para registrar las interacciones con los vectores (analytics)
CREATE TABLE IF NOT EXISTS vector_analytics (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  bot_id UUID REFERENCES bots(id) ON DELETE SET NULL,
  query TEXT NOT NULL,
  query_vector vector(1536), -- Usamos un valor constante inicialmente
  result_count INTEGER,
  latency_ms INTEGER,
  successful BOOLEAN DEFAULT TRUE, -- Nuevo para tracking de errores
  error_message TEXT, -- Nuevo para mensajes de error
  search_strategy VARCHAR(50), -- Nuevo para estrategia de búsqueda
  filter_criteria JSONB, -- Nuevo para filtros aplicados
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() -- Nuevo campo
);

-- Índices para analíticas vectoriales
CREATE INDEX idx_vector_analytics_user ON vector_analytics(user_id, created_at DESC);
CREATE INDEX idx_vector_analytics_bot ON vector_analytics(bot_id);
CREATE INDEX idx_vector_analytics_query_trgm ON vector_analytics USING gin (query gin_trgm_ops);

-- Ahora creamos los índices vectoriales y actualizamos las dimensiones dinámicamente
DO $$
DECLARE
  current_dim INTEGER;
BEGIN
  -- Obtener dimensión actual
  SELECT get_vector_dimension() INTO current_dim;
  
  -- Actualizar esquemas de tablas para usar la dimensión correcta
  IF current_dim != 1536 THEN
    -- Cambiar dimensión de columnas vectoriales
    EXECUTE format('ALTER TABLE document_chunks ALTER COLUMN content_vector TYPE vector(%s)', current_dim);
    EXECUTE format('ALTER TABLE messages ALTER COLUMN embedding TYPE vector(%s)', current_dim);
    EXECUTE format('ALTER TABLE vector_analytics ALTER COLUMN query_vector TYPE vector(%s)', current_dim);
    
    RAISE NOTICE 'Dimensiones vectoriales actualizadas a %', current_dim;
  END IF;
  
  -- Crear índices vectoriales con la dimensión correcta
  -- Para document_chunks
  EXECUTE 'CREATE INDEX idx_document_chunks_vector ON document_chunks 
           USING ivfflat (content_vector vector_cosine_ops)
           WITH (lists = 100)';
  
  -- Para messages
  EXECUTE 'CREATE INDEX idx_messages_embedding ON messages 
           USING ivfflat (embedding vector_cosine_ops)
           WITH (lists = 100)';
  
  -- Para vector_analytics
  EXECUTE 'CREATE INDEX idx_vector_analytics_vector ON vector_analytics 
           USING ivfflat (query_vector vector_cosine_ops)
           WITH (lists = 100)';
END $$;

-- Función mejorada para actualizaciones de dimensión de vectores en tiempo real
CREATE OR REPLACE FUNCTION update_vector_fields_to_current_dimension() 
RETURNS VOID AS $$
DECLARE
  current_dim INTEGER;
BEGIN
  -- Obtener dimensión actual
  SELECT get_vector_dimension() INTO current_dim;
  
  -- Actualizar esquemas de tablas para usar la dimensión correcta
  EXECUTE format('ALTER TABLE document_chunks ALTER COLUMN content_vector TYPE vector(%s)', current_dim);
  EXECUTE format('ALTER TABLE messages ALTER COLUMN embedding TYPE vector(%s)', current_dim);
  EXECUTE format('ALTER TABLE vector_analytics ALTER COLUMN query_vector TYPE vector(%s)', current_dim);
  
  -- Recrear índices vectoriales con la nueva dimensión
  -- El DROP y CREATE deben manejarse por separado para evitar errores si los índices no existen
  BEGIN
    EXECUTE 'DROP INDEX IF EXISTS idx_document_chunks_vector';
    EXECUTE 'CREATE INDEX idx_document_chunks_vector ON document_chunks 
             USING ivfflat (content_vector vector_cosine_ops)
             WITH (lists = 100)';
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al recrear índice idx_document_chunks_vector: %', SQLERRM;
  END;
  
  BEGIN
    EXECUTE 'DROP INDEX IF EXISTS idx_messages_embedding';
    EXECUTE 'CREATE INDEX idx_messages_embedding ON messages 
             USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)';
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al recrear índice idx_messages_embedding: %', SQLERRM;
  END;
  
  BEGIN
    EXECUTE 'DROP INDEX IF EXISTS idx_vector_analytics_vector';
    EXECUTE 'CREATE INDEX idx_vector_analytics_vector ON vector_analytics 
             USING ivfflat (query_vector vector_cosine_ops)
             WITH (lists = 100)';
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al recrear índice idx_vector_analytics_vector: %', SQLERRM;
  END;
  
  RAISE NOTICE 'Dimensiones vectoriales actualizadas a %', current_dim;
END;
$$ LANGUAGE plpgsql;

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Tablas para RAG creadas correctamente con dimensión vectorial dinámica.';
END $$;