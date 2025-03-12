-- ==============================================
-- ARCHIVO: init_4.sql - Tablas para RAG (Retrieval Augmented Generation)
-- ==============================================
-- Propósito: Crear y configurar las tablas necesarias para el sistema RAG,
-- incluyendo bots, colecciones de documentos, chunks vectoriales, conversaciones,
-- mensajes y análisis vectorial.
-- ==============================================

-- Verificar que la extensión vector está instalada
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'vector'
    ) THEN
        RAISE EXCEPTION 'La extensión "vector" no está instalada. Por favor, ejecute init_1.sql primero.';
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables WHERE table_schema = 'app' AND table_name = 'users'
    ) THEN
        RAISE EXCEPTION 'La tabla app.users no existe. Por favor, ejecute init_2.sql primero.';
    END IF;
END $$;

-- Obtener la dimensión vectorial configurada
DO $$
DECLARE
    vector_dim INTEGER;
BEGIN
    -- Intentar obtener la dimensión del vector desde system_config
    BEGIN
        SELECT COALESCE(
            (SELECT value::INTEGER FROM app.system_config WHERE key = 'vector_dimension'),
            1536 -- Valor por defecto si no existe la configuración
        ) INTO vector_dim;
    EXCEPTION WHEN OTHERS THEN
        -- Si hay algún error, usar el valor por defecto
        vector_dim := 1536;
        RAISE NOTICE 'No se pudo obtener la dimensión vectorial desde system_config. Usando valor por defecto: %', vector_dim;
    END;
    
    -- Guardar el valor para usarlo más adelante
    PERFORM set_config('my.vector_dimension', vector_dim::text, false);
    RAISE NOTICE 'Dimensión vectorial configurada: %', vector_dim;
END $$;

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS public.bots CASCADE;
DROP TABLE IF EXISTS app.document_collections CASCADE;
DROP TABLE IF EXISTS app.documents CASCADE;
DROP TABLE IF EXISTS app.document_chunks CASCADE;
DROP TABLE IF EXISTS app.bot_collections CASCADE;
DROP TABLE IF EXISTS public.conversations CASCADE;
DROP TABLE IF EXISTS public.messages CASCADE;
DROP TABLE IF EXISTS app.bot_response_feedback CASCADE;
DROP TABLE IF EXISTS app.vector_analytics CASCADE;

-- ---------- SECCIÓN 1: TABLAS PRINCIPALES DE RAG ----------

-- Tabla para los bots personalizados de cada usuario (accesible públicamente)
CREATE TABLE IF NOT EXISTS public.bots (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  name VARCHAR(50) NOT NULL,
  description TEXT,
  avatar_url TEXT CHECK (avatar_url IS NULL OR avatar_url ~* '^https?://[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_\+.~#?&//=]*)$'),
  system_prompt TEXT NOT NULL DEFAULT 'You are a helpful assistant.',
  temperature NUMERIC(3,2) CHECK (temperature BETWEEN 0 AND 2) DEFAULT 0.7,
  max_tokens INTEGER CHECK (max_tokens BETWEEN 10 AND 32000) DEFAULT 4096,
  model_config JSONB NOT NULL DEFAULT '{}',
  is_public BOOLEAN DEFAULT FALSE,
  category VARCHAR(50),
  tags TEXT[],
  version INTEGER DEFAULT 1,
  popularity_score INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para bots
CREATE UNIQUE INDEX idx_unique_user_bot_name ON public.bots(user_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_bots_tags ON public.bots USING gin(tags);
CREATE INDEX idx_bots_category ON public.bots(category) WHERE deleted_at IS NULL;
CREATE INDEX idx_bots_public ON public.bots(is_public, popularity_score DESC) WHERE is_public = TRUE AND deleted_at IS NULL;
CREATE INDEX idx_bots_active ON public.bots(is_active) WHERE is_active = TRUE AND deleted_at IS NULL;

-- Tabla para las colecciones de documentos (interna)
CREATE TABLE IF NOT EXISTS app.document_collections (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  name VARCHAR(50) NOT NULL,
  description TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  is_public BOOLEAN DEFAULT FALSE,
  category VARCHAR(50),
  tags TEXT[],
  embedding_model VARCHAR(50) DEFAULT 'text-embedding-ada-002',
  chunk_size INTEGER DEFAULT 1000,
  chunk_overlap INTEGER DEFAULT 200,
  metadata_schema JSONB DEFAULT '{}',
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para colecciones
CREATE UNIQUE INDEX idx_unique_user_collection_name ON app.document_collections(user_id, name) WHERE deleted_at IS NULL;
CREATE INDEX idx_collections_tags ON app.document_collections USING gin(tags);
CREATE INDEX idx_collections_category ON app.document_collections(category) WHERE deleted_at IS NULL;
CREATE INDEX idx_collections_public ON app.document_collections(is_public) WHERE is_public = TRUE AND deleted_at IS NULL;
CREATE INDEX idx_collections_user ON app.document_collections(user_id) WHERE deleted_at IS NULL;

-- Tabla para documentos individuales (interna)
CREATE TABLE IF NOT EXISTS app.documents (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  collection_id UUID NOT NULL REFERENCES app.document_collections(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  content TEXT NOT NULL,
  content_hash TEXT,
  file_type VARCHAR(20),
  file_size INTEGER,
  source_url TEXT CHECK (source_url IS NULL OR source_url ~* '^https?://[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_\+.~#?&//=]*)$'),
  language VARCHAR(10),
  metadata JSONB DEFAULT '{}',
  version INTEGER DEFAULT 1,
  processing_status VARCHAR(20) DEFAULT 'pending' CHECK (processing_status IN ('pending', 'processing', 'completed', 'error')),
  error_message TEXT,
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Mejores índices para documentos
CREATE INDEX idx_documents_collection ON app.documents(collection_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_title_trgm ON app.documents USING gin (title gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_content_hash ON app.documents(content_hash) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_status ON app.documents(processing_status) WHERE deleted_at IS NULL;
CREATE INDEX idx_documents_metadata ON app.documents USING gin(metadata);
CREATE INDEX idx_documents_language ON app.documents(language) WHERE deleted_at IS NULL;

-- Obtener la dimensión vectorial para usarla en la definición de tablas
DO $$
DECLARE
    vector_dim INTEGER;
BEGIN
    -- Recuperar la dimensión vectorial establecida anteriormente
    vector_dim := current_setting('my.vector_dimension')::INTEGER;
    
    -- Crear la tabla document_chunks con la dimensión correcta
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS app.document_chunks (
          id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
          document_id UUID NOT NULL REFERENCES app.documents(id) ON DELETE CASCADE,
          content TEXT NOT NULL,
          content_vector vector(%s), -- Dimensión dinámica
          content_hash TEXT,
          content_tokens INTEGER,
          chunk_index INTEGER NOT NULL,
          page_number INTEGER,
          metadata JSONB DEFAULT ''{}''::jsonb,
          relevance_score FLOAT,
          version INTEGER DEFAULT 1,
          created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
          updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        )', vector_dim);
END $$;

-- Índices optimizados para chunks
CREATE INDEX idx_document_chunks_document ON app.document_chunks(document_id);
CREATE INDEX idx_document_chunks_content_trgm ON app.document_chunks USING gin (content gin_trgm_ops);
CREATE INDEX idx_document_chunks_metadata ON app.document_chunks USING gin(metadata);
CREATE INDEX idx_document_chunks_relevance ON app.document_chunks(relevance_score) WHERE relevance_score > 0.5;

-- Tabla para asociar bots con colecciones de documentos (interna)
CREATE TABLE IF NOT EXISTS app.bot_collections (
  bot_id UUID NOT NULL REFERENCES public.bots(id) ON DELETE CASCADE,
  collection_id UUID NOT NULL REFERENCES app.document_collections(id) ON DELETE CASCADE,
  weight FLOAT DEFAULT 1.0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  PRIMARY KEY(bot_id, collection_id)
);

-- Índices para relaciones bot-colección
CREATE INDEX idx_bot_collections_collection ON app.bot_collections(collection_id);
CREATE INDEX idx_bot_collections_bot ON app.bot_collections(bot_id);

-- ---------- SECCIÓN 2: TABLAS DE INTERACCIÓN ----------

-- Tabla para conversaciones con bots (accesible públicamente)
CREATE TABLE IF NOT EXISTS public.conversations (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  bot_id UUID NOT NULL REFERENCES public.bots(id) ON DELETE CASCADE,
  title TEXT DEFAULT 'New Conversation',
  summary TEXT,
  is_public BOOLEAN DEFAULT FALSE,
  is_pinned BOOLEAN DEFAULT FALSE,
  language VARCHAR(10),
  metadata JSONB DEFAULT '{}',
  last_activity_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para conversaciones
CREATE INDEX idx_conversations_user ON public.conversations(user_id, last_activity_at DESC);
CREATE INDEX idx_conversations_bot ON public.conversations(bot_id);
CREATE INDEX idx_conversations_public ON public.conversations(is_public) WHERE is_public = TRUE;
CREATE INDEX idx_conversations_pinned ON public.conversations(user_id, is_pinned) WHERE is_pinned = TRUE;
CREATE INDEX idx_conversations_recent ON public.conversations(last_activity_at DESC);

-- Tabla para mensajes en conversaciones (accesible públicamente)
-- Usar la dimensión vectorial configurada
DO $$
DECLARE
    vector_dim INTEGER;
BEGIN
    -- Recuperar la dimensión vectorial establecida anteriormente
    vector_dim := current_setting('my.vector_dimension')::INTEGER;
    
    -- Crear la tabla messages con la dimensión correcta
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS public.messages (
          id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
          conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
          is_user BOOLEAN NOT NULL,
          content TEXT NOT NULL,
          embedding vector(%s), -- Dimensión dinámica
          tokens_used INTEGER,
          latency_ms INTEGER,
          source_message_id UUID REFERENCES public.messages(id) ON DELETE SET NULL,
          citation_sources JSONB DEFAULT ''[]''::jsonb,
          metadata JSONB DEFAULT ''{}''::jsonb,
          created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
          updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        )', vector_dim);
END $$;

-- Índices para mensajes
CREATE INDEX idx_messages_conversation ON public.messages(conversation_id, created_at);
CREATE INDEX idx_messages_source ON public.messages(source_message_id) WHERE source_message_id IS NOT NULL;
CREATE INDEX idx_messages_user_type ON public.messages(conversation_id, is_user);
CREATE INDEX idx_messages_content_search ON public.messages USING gin(content gin_trgm_ops);

-- Tabla para feedback de respuestas de bots (interna)
CREATE TABLE IF NOT EXISTS app.bot_response_feedback (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  message_id UUID NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  feedback_text TEXT,
  feedback_categories TEXT[],
  fixed_by_message_id UUID REFERENCES public.messages(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para feedback
CREATE INDEX idx_feedback_message ON app.bot_response_feedback(message_id);
CREATE INDEX idx_feedback_user ON app.bot_response_feedback(user_id);
CREATE INDEX idx_feedback_categories ON app.bot_response_feedback USING gin(feedback_categories);
CREATE INDEX idx_feedback_rating ON app.bot_response_feedback(rating);

-- ---------- SECCIÓN 3: ANALÍTICA VECTORIAL PARTICIONADA ----------

-- Tabla particionada para análisis vectorial (interna)
-- Usar la dimensión vectorial configurada
DO $$
DECLARE
    vector_dim INTEGER;
BEGIN
    -- Recuperar la dimensión vectorial establecida anteriormente
    vector_dim := current_setting('my.vector_dimension')::INTEGER;
    
    -- Crear la tabla vector_analytics con la dimensión correcta
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS app.vector_analytics (
          id UUID NOT NULL DEFAULT extensions.uuid_generate_v4(),
          user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
          bot_id UUID REFERENCES public.bots(id) ON DELETE SET NULL,
          query TEXT NOT NULL,
          query_vector vector(%s), -- Dimensión dinámica
          result_count INTEGER,
          latency_ms INTEGER,
          successful BOOLEAN DEFAULT TRUE,
          error_message TEXT,
          search_strategy VARCHAR(50),
          filter_criteria JSONB,
          metadata JSONB DEFAULT ''{}''::jsonb,
          created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
          updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
          PRIMARY KEY (id, created_at)
        ) PARTITION BY RANGE (created_at)', vector_dim);
END $$;

-- Función para crear particiones automáticamente para vector_analytics
CREATE OR REPLACE FUNCTION create_vector_analytics_partition()
RETURNS TRIGGER AS $$
DECLARE
  partition_date DATE;
  partition_name TEXT;
  start_date TEXT;
  end_date TEXT;
  next_month_date DATE;
  next_next_month_date DATE;
  unique_suffix TEXT;
  current_vector_dim INTEGER;
BEGIN
  -- Obtener la dimensión vectorial actual
  BEGIN
    current_vector_dim := current_setting('my.vector_dimension')::INTEGER;
  EXCEPTION WHEN OTHERS THEN
    -- Si hay algún error, usar el valor por defecto
    current_vector_dim := 1536;
  END;

  -- Determinar el mes del dato a insertar
  partition_date := date_trunc('month', NEW.created_at)::DATE;
  partition_name := 'vector_analytics_y' || 
                    EXTRACT(YEAR FROM partition_date)::TEXT || 
                    'm' || 
                    LPAD(EXTRACT(MONTH FROM partition_date)::TEXT, 2, '0');
  start_date := partition_date::TEXT;
  end_date := (partition_date + INTERVAL '1 month')::TEXT;
  
  -- Generar sufijo único basado en timestamp para evitar colisiones
  unique_suffix := '_' || EXTRACT(EPOCH FROM NOW())::BIGINT;
  
  -- Verificar y crear partición para el mes actual
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'app'
  ) THEN
    BEGIN
      -- Crear la partición con la dimensión vectorial correcta
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.vector_analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      -- Crear índices con nombres únicos
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (user_id, created_at)',
        partition_name || '_user_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (created_at)',
        partition_name || '_date_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (bot_id, created_at) WHERE bot_id IS NOT NULL',
        partition_name || '_bot_idx' || unique_suffix, 
        partition_name
      );

      -- Crear índice vectorial para la partición
      EXECUTE format(
        'CREATE INDEX %I ON app.%I USING ivfflat (query_vector vector_cosine_ops) WITH (lists = 100)',
        partition_name || '_vector_idx' || unique_suffix,
        partition_name
      );

      RAISE NOTICE 'Creada partición % para datos de vector_analytics con dimensión %', 
                  partition_name, current_vector_dim;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  -- Crear particiones anticipadas para los próximos dos meses (proactivo)
  next_month_date := partition_date + INTERVAL '1 month';
  next_next_month_date := partition_date + INTERVAL '2 month';
  
  -- Próximo mes
  partition_name := 'vector_analytics_y' || 
                    EXTRACT(YEAR FROM next_month_date)::TEXT || 
                    'm' || 
                    LPAD(EXTRACT(MONTH FROM next_month_date)::TEXT, 2, '0');
  start_date := next_month_date::TEXT;
  end_date := (next_month_date + INTERVAL '1 month')::TEXT;
  
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'app'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.vector_analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      RAISE NOTICE 'Creada partición anticipada % con dimensión %', partition_name, current_vector_dim;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición anticipada %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  -- Siguiente mes
  partition_name := 'vector_analytics_y' || 
                    EXTRACT(YEAR FROM next_next_month_date)::TEXT || 
                    'm' || 
                    LPAD(EXTRACT(MONTH FROM next_next_month_date)::TEXT, 2, '0');
  start_date := next_next_month_date::TEXT;
  end_date := (next_next_month_date + INTERVAL '1 month')::TEXT;
  
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'app'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.vector_analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      RAISE NOTICE 'Creada partición anticipada % con dimensión %', partition_name, current_vector_dim;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición anticipada %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Crear particiones iniciales para vector_analytics
DO $$
DECLARE
  current_date DATE := CURRENT_DATE;
  start_month DATE;
  partition_name TEXT;
  start_date TEXT;
  end_date TEXT;
  current_vector_dim INTEGER;
BEGIN
  -- Obtener la dimensión vectorial configurada
  BEGIN
    current_vector_dim := current_setting('my.vector_dimension')::INTEGER;
  EXCEPTION WHEN OTHERS THEN
    -- Si hay algún error, usar el valor por defecto
    current_vector_dim := 1536;
  END;

  -- Crear particiones para 3 meses pasados, mes actual y 2 meses futuros
  FOR i IN -3..2 LOOP
    start_month := date_trunc('month', current_date + (i * INTERVAL '1 month'))::DATE;
    
    partition_name := 'vector_analytics_y' || 
                      EXTRACT(YEAR FROM start_month)::TEXT || 
                      'm' || 
                      LPAD(EXTRACT(MONTH FROM start_month)::TEXT, 2, '0');
    start_date := start_month::TEXT;
    end_date := (start_month + INTERVAL '1 month')::TEXT;
    
    -- Verificar si la partición ya existe
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = partition_name AND n.nspname = 'app'
    ) THEN
      BEGIN
        EXECUTE format(
          'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.vector_analytics
           FOR VALUES FROM (%L) TO (%L)',
          partition_name, start_date, end_date
        );
        
        -- Índices básicos para particiones
        EXECUTE format(
          'CREATE INDEX %I ON app.%I (user_id, created_at)',
          partition_name || '_user_idx', 
          partition_name
        );
        
        EXECUTE format(
          'CREATE INDEX %I ON app.%I (created_at)',
          partition_name || '_date_idx', 
          partition_name
        );
        
        EXECUTE format(
          'CREATE INDEX %I ON app.%I (bot_id, created_at) WHERE bot_id IS NOT NULL',
          partition_name || '_bot_idx', 
          partition_name
        );

        -- Índice vectorial para la partición
        EXECUTE format(
          'CREATE INDEX %I ON app.%I USING ivfflat (query_vector vector_cosine_ops) WITH (lists = 100)',
          partition_name || '_vector_idx',
          partition_name
        );
        
        RAISE NOTICE 'Creada partición % para datos de vector_analytics con dimensión %', 
                    partition_name, current_vector_dim;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Error creando partición %: %', partition_name, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;

-- Trigger para crear particiones automáticamente
CREATE TRIGGER create_vector_analytics_partition_trigger
BEFORE INSERT ON app.vector_analytics
FOR EACH ROW
EXECUTE FUNCTION create_vector_analytics_partition();

-- ---------- SECCIÓN 4: ÍNDICES VECTORIALES Y ACTUALIZACIONES DINÁMICAS ----------

-- Ahora creamos los índices vectoriales
DO $$
DECLARE
  current_dim INTEGER;
BEGIN
  -- Obtener dimensión actual
  BEGIN
    current_dim := current_setting('my.vector_dimension')::INTEGER;
  EXCEPTION WHEN OTHERS THEN
    -- Si hay algún error, usar el valor por defecto
    current_dim := 1536;
  END;
  
  -- Crear índices vectoriales con la dimensión correcta
  -- Para document_chunks
  BEGIN
    EXECUTE 'CREATE INDEX idx_document_chunks_vector ON app.document_chunks 
             USING ivfflat (content_vector vector_cosine_ops)
             WITH (lists = 100)';
    RAISE NOTICE 'Creado índice idx_document_chunks_vector con dimensión %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al crear índice idx_document_chunks_vector: %', SQLERRM;
  END;
  
  -- Para messages
  BEGIN
    EXECUTE 'CREATE INDEX idx_messages_embedding ON public.messages 
             USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)';
    RAISE NOTICE 'Creado índice idx_messages_embedding con dimensión %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al crear índice idx_messages_embedding: %', SQLERRM;
  END;
  
  -- Para vector_analytics, crear índice maestro (además de los índices por partición)
  BEGIN
    EXECUTE 'CREATE INDEX idx_vector_analytics_vector ON app.vector_analytics 
             USING ivfflat (query_vector vector_cosine_ops)
             WITH (lists = 100)';
    RAISE NOTICE 'Creado índice idx_vector_analytics_vector con dimensión %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al crear índice idx_vector_analytics_vector: %', SQLERRM;
  END;
END $$;

-- Función mejorada para actualizaciones de dimensión de vectores en tiempo real
CREATE OR REPLACE FUNCTION update_vector_fields_to_current_dimension() 
RETURNS VOID AS $$
DECLARE
  current_dim INTEGER;
  partition_table TEXT;
  partition_tables CURSOR FOR 
      SELECT tablename 
      FROM pg_tables 
      WHERE schemaname = 'app' AND tablename LIKE 'vector_analytics_y%m%';
BEGIN
  -- Obtener dimensión actual
  BEGIN
    -- Obtener la dimensión de system_config
    SELECT value::INTEGER INTO current_dim FROM app.system_config WHERE key = 'vector_dimension';
    
    -- Si no se encontró, usar el valor por defecto
    IF current_dim IS NULL THEN
      current_dim := 1536;
      RAISE WARNING 'No se pudo obtener la dimensión vectorial. Usando valor por defecto: %', current_dim;
    END IF;
    
    -- Guardar la dimensión para uso posterior
    PERFORM set_config('my.vector_dimension', current_dim::text, false);
  EXCEPTION WHEN OTHERS THEN
    current_dim := 1536;
    RAISE WARNING 'Error al obtener dimensión vectorial: %. Usando valor por defecto: %', SQLERRM, current_dim;
  END;
  
  -- Actualizar esquemas de tablas para usar la dimensión correcta
  BEGIN
    EXECUTE format('ALTER TABLE app.document_chunks ALTER COLUMN content_vector TYPE vector(%s)', current_dim);
    RAISE NOTICE 'Actualizada dimensión vectorial en document_chunks a %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al actualizar document_chunks: %', SQLERRM;
  END;
  
  BEGIN
    EXECUTE format('ALTER TABLE public.messages ALTER COLUMN embedding TYPE vector(%s)', current_dim);
    RAISE NOTICE 'Actualizada dimensión vectorial en messages a %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al actualizar messages: %', SQLERRM;
  END;
  
  BEGIN
    EXECUTE format('ALTER TABLE app.vector_analytics ALTER COLUMN query_vector TYPE vector(%s)', current_dim);
    RAISE NOTICE 'Actualizada dimensión vectorial en vector_analytics a %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al actualizar vector_analytics: %', SQLERRM;
  END;
  
  -- Recrear índices vectoriales con la nueva dimensión
  -- El DROP y CREATE deben manejarse por separado para evitar errores
  BEGIN
    EXECUTE 'DROP INDEX IF EXISTS idx_document_chunks_vector';
    EXECUTE 'CREATE INDEX idx_document_chunks_vector ON app.document_chunks 
             USING ivfflat (content_vector vector_cosine_ops)
             WITH (lists = 100)';
    RAISE NOTICE 'Recreado índice idx_document_chunks_vector con dimensión %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al recrear índice idx_document_chunks_vector: %', SQLERRM;
  END;
  
  BEGIN
    EXECUTE 'DROP INDEX IF EXISTS idx_messages_embedding';
    EXECUTE 'CREATE INDEX idx_messages_embedding ON public.messages 
             USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)';
    RAISE NOTICE 'Recreado índice idx_messages_embedding con dimensión %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al recrear índice idx_messages_embedding: %', SQLERRM;
  END;
  
  BEGIN
    EXECUTE 'DROP INDEX IF EXISTS idx_vector_analytics_vector';
    EXECUTE 'CREATE INDEX idx_vector_analytics_vector ON app.vector_analytics 
             USING ivfflat (query_vector vector_cosine_ops)
             WITH (lists = 100)';
    RAISE NOTICE 'Recreado índice idx_vector_analytics_vector con dimensión %', current_dim;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error al recrear índice idx_vector_analytics_vector: %', SQLERRM;
  END;
  
  -- Actualizar índices en particiones de vector_analytics
  OPEN partition_tables;
  LOOP
    FETCH partition_tables INTO partition_table;
    EXIT WHEN NOT FOUND;
    
    BEGIN
      -- Buscar y eliminar índices vectoriales existentes para esta partición
      EXECUTE format(
        'DROP INDEX IF EXISTS app.%I_vector_idx',
        partition_table
      );
      
      -- Crear nuevo índice vectorial para la partición
      EXECUTE format(
        'CREATE INDEX %I_vector_idx ON app.%I USING ivfflat (query_vector vector_cosine_ops) WITH (lists = 100)',
        partition_table,
        partition_table
      );
      
      RAISE NOTICE 'Actualizado índice vectorial para partición % con dimensión %', partition_table, current_dim;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error al actualizar índice para partición %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
  
  RAISE NOTICE 'Dimensiones vectoriales actualizadas a %', current_dim;
END;
$$ LANGUAGE plpgsql;

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  RAISE NOTICE 'Tablas para RAG creadas correctamente con dimensión vectorial dinámica y particionamiento.';
  RAISE NOTICE 'Tablas públicas: bots, conversations, messages';
  RAISE NOTICE 'Tablas internas: document_collections, documents, document_chunks, bot_collections, vector_analytics, bot_response_feedback';
  
  -- Mostrar la dimensión vectorial configurada
  BEGIN
    RAISE NOTICE 'Dimensión vectorial configurada: %', current_setting('my.vector_dimension');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Dimensión vectorial configurada: 1536 (valor por defecto)';
  END;
END $$;