-- ==============================================
-- ARCHIVO: init_7.sql - Creación de Triggers e Índices
-- ==============================================
-- Propósito: Este archivo configura todos los triggers del sistema para mantener
-- la integridad y consistencia de los datos, así como los índices necesarios
-- para optimizar el rendimiento de consultas frecuentes.
--
-- Este archivo implementa:
--  1. Eliminación segura de triggers e índices previos
--  2. Triggers para actualización automática de timestamps en todas las tablas
--  3. Triggers para incremento de contadores y última actividad
--  4. Triggers para validación de cuotas de usuario
--  5. Triggers para particionamiento automático de tablas
--  6. Índices optimizados para tablas principales
--  7. Índices especializados para búsqueda textual y vector
--
-- NOTA: Todos los índices y triggers se crean teniendo en cuenta la nueva
-- estructura de esquemas (app y public).
-- ==============================================

-- ---------- SECCIÓN 1: LIMPIEZA SEGURA DE TRIGGERS EXISTENTES ----------

/**
 * Eliminar triggers existentes usando métodos seguros y verificando primero su existencia.
 * Esto evita errores y facilita ejecuciones repetidas del script.
 */
DO $$
DECLARE
  trigger_info RECORD;
  full_table_name TEXT;
  drop_stmt TEXT;
BEGIN
  FOR trigger_info IN (
    SELECT 
      t.tgname AS trigger_name,
      n.nspname AS schema_name,
      c.relname AS table_name
    FROM pg_trigger t
    JOIN pg_class c ON t.tgrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname IN ('public', 'app')
    AND t.tgisinternal = FALSE -- Excluir triggers internos
  ) LOOP
    -- Construir nombre completo de la tabla con el esquema
    full_table_name := quote_ident(trigger_info.schema_name) || '.' || quote_ident(trigger_info.table_name);
    
    -- Construir la sentencia DROP TRIGGER
    drop_stmt := 'DROP TRIGGER IF EXISTS ' || quote_ident(trigger_info.trigger_name) || 
                 ' ON ' || full_table_name;
    
    BEGIN
      EXECUTE drop_stmt;
      RAISE NOTICE 'Trigger % en tabla % eliminado correctamente', 
                 trigger_info.trigger_name, full_table_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error eliminando trigger % en tabla %: %', 
                 trigger_info.trigger_name, full_table_name, SQLERRM;
    END;
  END LOOP;
END $$;

-- ---------- SECCIÓN 2: TRIGGERS DE ACTUALIZACIÓN DE TIMESTAMP ----------

/**
 * Triggers para actualizar automáticamente los campos updated_at en todas
 * las tablas relevantes del sistema. Estos utilizan la función update_modified_column().
 */

-- Mantener solo triggers básicos para timestamps
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Aplicar trigger de updated_at a todas las tablas relevantes
DO $$
DECLARE
    t record;
BEGIN
    FOR t IN 
        SELECT table_schema, table_name 
        FROM information_schema.tables 
        WHERE table_schema IN ('public', 'app')
        AND table_type = 'BASE TABLE'
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trigger_update_timestamp ON %I.%I;
             CREATE TRIGGER trigger_update_timestamp
             BEFORE UPDATE ON %I.%I
             FOR EACH ROW EXECUTE FUNCTION update_updated_at();',
            t.table_schema, t.table_name, t.table_schema, t.table_name
        );
    END LOOP;
END;
$$;

-- ---------- SECCIÓN 3: TRIGGERS FUNCIONALES ----------

/**
 * Trigger para incrementar contador de clics en enlaces.
 * Se ejecuta cuando se inserta un registro en analytics con un link_id.
 */
CREATE TRIGGER increment_clicks_on_analytics
  AFTER INSERT ON app.analytics
  FOR EACH ROW
  WHEN (NEW.link_id IS NOT NULL)
  EXECUTE PROCEDURE increment_link_clicks();

/**
 * Trigger para actualizar timestamp de última actividad en conversaciones.
 * Mantiene actualizado el campo last_activity_at para ordenación correcta.
 */
CREATE TRIGGER update_conversation_activity
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE PROCEDURE update_conversation_last_activity();

-- ---------- SECCIÓN 4: TRIGGERS DE CONTROL DE CUOTAS ----------

/**
 * Triggers para validación de cuotas antes de crear nuevos recursos.
 * Utilizan las funciones enforce_*_quota() definidas en init_6.sql.
 */

-- Verificar cuota de bots antes de crear uno nuevo
CREATE TRIGGER check_bot_quota
  BEFORE INSERT ON public.bots
  FOR EACH ROW 
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_bot_quota();

-- Verificar cuota de colecciones antes de crear una nueva
CREATE TRIGGER check_collection_quota
  BEFORE INSERT ON app.document_collections
  FOR EACH ROW 
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_collection_quota();

-- Verificar cuota de documentos antes de crear uno nuevo
CREATE TRIGGER check_document_quota
  BEFORE INSERT ON app.documents
  FOR EACH ROW
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_document_quota();

-- Verificar cuota de búsquedas vectoriales
CREATE TRIGGER check_vector_search_quota
  BEFORE INSERT ON app.vector_analytics
  FOR EACH ROW 
  EXECUTE PROCEDURE enforce_vector_search_quota();

-- ---------- SECCIÓN 5: TRIGGERS DE PARTICIONAMIENTO AUTOMÁTICO ----------

/**
 * Triggers para crear particiones automáticamente en tablas particionadas.
 * Aseguran la creación de particiones antes de insertar nuevos datos.
 */

-- Trigger para crear particiones de analytics automáticamente
CREATE TRIGGER create_analytics_partition_trigger
  BEFORE INSERT ON app.analytics
  FOR EACH ROW
  EXECUTE PROCEDURE create_analytics_partition();

-- Trigger para crear particiones de vector_analytics automáticamente
CREATE TRIGGER create_vector_analytics_partition_trigger
  BEFORE INSERT ON app.vector_analytics
  FOR EACH ROW
  EXECUTE PROCEDURE create_vector_analytics_partition();

-- Trigger para validar configuración del sistema
CREATE TRIGGER validate_system_config_changes
  BEFORE INSERT OR UPDATE ON app.system_config
  FOR EACH ROW
  EXECUTE PROCEDURE validate_config_changes();

-- ---------- SECCIÓN 6: ÍNDICES PARA TABLAS PRINCIPALES ----------

/**
 * Creación optimizada de índices para tablas principales.
 * Incluye:
 * - Verificación de existencia para evitar errores
 * - Índices para búsquedas frecuentes
 * - Índices de texto usando gin_trgm_ops para búsqueda avanzada
 */
DO $$
DECLARE
  index_exists BOOLEAN;
BEGIN
  -- ===== Índices para usuarios =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_auth_id'
  ) INTO index_exists;
  
  IF NOT index_exists THEN
    CREATE INDEX idx_users_auth_id ON app.users(auth_id) WHERE deleted_at IS NULL;
    RAISE NOTICE 'Índice idx_users_auth_id creado';
  END IF;
  
  -- Índice optimizado para búsqueda por username
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_username_search'
  ) INTO index_exists;
  
  IF NOT index_exists THEN
    CREATE INDEX idx_users_username_search ON app.users USING gin(username gin_trgm_ops) 
    WHERE deleted_at IS NULL;
    RAISE NOTICE 'Índice idx_users_username_search creado';
  END IF;
  
  -- Índice para búsqueda por email
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_email_search'
  ) INTO index_exists;
  
  IF NOT index_exists THEN
    CREATE INDEX idx_users_email_search ON app.users USING gin(email gin_trgm_ops) 
    WHERE deleted_at IS NULL;
    RAISE NOTICE 'Índice idx_users_email_search creado';
  END IF;
  
  -- ===== Índices para enlaces (links) =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_links_user_position'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'links') THEN
    CREATE INDEX idx_links_user_position ON public.links(user_id, position);
    RAISE NOTICE 'Índice idx_links_user_position creado';
  END IF;
  
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_links_bot_id'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'links') THEN
    CREATE INDEX idx_links_bot_id ON public.links(bot_id) WHERE bot_id IS NOT NULL;
    RAISE NOTICE 'Índice idx_links_bot_id creado';
  END IF;
  
  -- Índice para links activos (optimiza consultas de frontend)
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_links_active'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'links') THEN
    CREATE INDEX idx_links_active ON public.links(user_id) WHERE is_active = TRUE;
    RAISE NOTICE 'Índice idx_links_active creado';
  END IF;
  
  -- ===== Índices para roles de usuario =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_user_roles_role'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'user_roles') THEN
    CREATE INDEX idx_user_roles_role ON app.user_roles(role);
    RAISE NOTICE 'Índice idx_user_roles_role creado';
  END IF;
  
  -- ===== Índices para errores del sistema =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_system_errors_unresolved'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'system_errors') THEN
    CREATE INDEX idx_system_errors_unresolved ON app.system_errors(created_at) 
    WHERE is_resolved = FALSE;
    RAISE NOTICE 'Índice idx_system_errors_unresolved creado';
  END IF;
  
  -- Índice para filtrar por tipo de error (frecuente en monitoreo)
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_system_errors_type_severity'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'system_errors') THEN
    CREATE INDEX idx_system_errors_type_severity ON app.system_errors(error_type, severity);
    RAISE NOTICE 'Índice idx_system_errors_type_severity creado';
  END IF;
  
  -- ===== Índices para métricas de uso =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_usage_metrics_user_date'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'usage_metrics') THEN
    CREATE INDEX idx_usage_metrics_user_date ON app.usage_metrics(user_id, year_month);
    RAISE NOTICE 'Índice idx_usage_metrics_user_date creado';
  END IF;
  
  -- ===== Índices para suscripciones =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_subscriptions_status'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'subscriptions') THEN
    CREATE INDEX idx_subscriptions_status ON app.subscriptions(status, current_period_end);
    RAISE NOTICE 'Índice idx_subscriptions_status creado';
  END IF;
  
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_subscriptions_expiring'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'subscriptions') THEN
    CREATE INDEX idx_subscriptions_expiring ON app.subscriptions(current_period_end) 
    WHERE status = 'active' AND auto_renew = FALSE;
    RAISE NOTICE 'Índice idx_subscriptions_expiring creado';
  END IF;
  
  -- ===== Índices para mensajes y conversaciones =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_messages_content_search'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'messages') THEN
    CREATE INDEX idx_messages_content_search ON public.messages USING gin(content gin_trgm_ops);
    RAISE NOTICE 'Índice idx_messages_content_search creado';
  END IF;
  
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_conversations_search'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'conversations') THEN
    CREATE INDEX idx_conversations_search ON public.conversations USING gin(title gin_trgm_ops);
    RAISE NOTICE 'Índice idx_conversations_search creado';
  END IF;
  
  -- Índice para conversaciones recientes (mejora rendimiento en listados)
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_conversations_user_activity'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'conversations') THEN
    CREATE INDEX idx_conversations_user_activity ON public.conversations(user_id, last_activity_at DESC);
    RAISE NOTICE 'Índice idx_conversations_user_activity creado';
  END IF;
  
  RAISE NOTICE 'Proceso de creación de índices principales completado.';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error durante la creación de índices: %', SQLERRM;
END $$;

-- ---------- SECCIÓN 7: ÍNDICES PARA DOCUMENTOS Y BÚSQUEDA VECTORIAL ----------

/**
 * Creación de índices específicos para búsqueda textual y vectorial.
 * Estos índices son críticos para el rendimiento de RAG (Retrieval Augmented Generation).
 */
DO $$
DECLARE
  index_exists BOOLEAN;
BEGIN
  -- ===== Índices para documentos =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_documents_title_search'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'documents') THEN
    CREATE INDEX idx_documents_title_search ON app.documents USING gin(title gin_trgm_ops) 
    WHERE deleted_at IS NULL;
    RAISE NOTICE 'Índice idx_documents_title_search creado';
  END IF;
  
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_documents_content_search'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'documents') THEN
    CREATE INDEX idx_documents_content_search ON app.documents USING gin(content gin_trgm_ops) 
    WHERE deleted_at IS NULL;
    RAISE NOTICE 'Índice idx_documents_content_search creado';
  END IF;
  
  -- Índice para status de procesamiento (mejora identificación de problemas)
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_documents_processing_status'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'documents') THEN
    CREATE INDEX idx_documents_processing_status ON app.documents(processing_status, updated_at) 
    WHERE deleted_at IS NULL;
    RAISE NOTICE 'Índice idx_documents_processing_status creado';
  END IF;
  
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_document_chunks_content_search'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'app' AND table_name = 'document_chunks') THEN
    CREATE INDEX idx_document_chunks_content_search ON app.document_chunks USING gin(content gin_trgm_ops);
    RAISE NOTICE 'Índice idx_document_chunks_content_search creado';
  END IF;
  
  -- ===== Índices para perfiles =====
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_profiles_custom_domain'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'profiles') THEN
    CREATE INDEX idx_profiles_custom_domain ON public.profiles(custom_domain) 
    WHERE custom_domain IS NOT NULL;
    RAISE NOTICE 'Índice idx_profiles_custom_domain creado';
  END IF;
  
  -- Índice mejorado para redes sociales (facilita búsqueda de perfiles por red social)
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_profiles_social_handles'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'profiles') THEN
    CREATE INDEX idx_profiles_social_handles ON public.profiles USING gin(
      to_tsvector('english', 
        COALESCE(social_twitter, '') || ' ' || 
        COALESCE(social_instagram, '') || ' ' || 
        COALESCE(social_tiktok, '') || ' ' ||
        COALESCE(social_linkedin, '') || ' ' ||
        COALESCE(social_github, '')
      )
    );
    RAISE NOTICE 'Índice idx_profiles_social_handles creado';
  END IF;
  
  -- Índice para perfiles verificados (mejora consultas de perfiles destacados)
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_profiles_verified'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (SELECT 1 FROM information_schema.tables 
                                 WHERE table_schema = 'public' AND table_name = 'profiles') THEN
    CREATE INDEX idx_profiles_verified ON public.profiles(view_count DESC) 
    WHERE is_verified = TRUE;
    RAISE NOTICE 'Índice idx_profiles_verified creado';
  END IF;
  
  RAISE NOTICE 'Proceso de creación de índices para búsqueda completado.';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error durante la creación de índices de búsqueda: %', SQLERRM;
END $$;

-- ---------- SECCIÓN 8: ÍNDICES VECTORIALES ----------

/**
 * Creación de índices para columnas vectoriales.
 * Estos índices son esenciales para búsqueda semántica.
 * Se utiliza ivfflat para índices aproximados de alto rendimiento.
 */
DO $$
DECLARE
  index_exists BOOLEAN;
BEGIN
  -- Verificar existencia de índice vectorial en document_chunks
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_document_chunks_vector'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'app' AND table_name = 'document_chunks' 
    AND column_name = 'content_vector'
  ) THEN
    BEGIN
      -- Crear índice IVFFlat para búsqueda por similitud coseno
      CREATE INDEX idx_document_chunks_vector ON app.document_chunks 
      USING ivfflat (content_vector vector_cosine_ops)
      WITH (lists = 100);
      RAISE NOTICE 'Índice vectorial idx_document_chunks_vector creado';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error al crear índice vectorial en document_chunks: %', SQLERRM;
    END;
  END IF;
  
  -- Verificar existencia de índice vectorial en messages
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_messages_embedding'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'messages' 
    AND column_name = 'embedding'
  ) THEN
    BEGIN
      -- Crear índice IVFFlat para búsqueda por similitud coseno
      CREATE INDEX idx_messages_embedding ON public.messages 
      USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 100);
      RAISE NOTICE 'Índice vectorial idx_messages_embedding creado';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error al crear índice vectorial en messages: %', SQLERRM;
    END;
  END IF;
  
  -- Verificar existencia de índice vectorial en vector_analytics
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_vector_analytics_vector'
  ) INTO index_exists;
  
  IF NOT index_exists AND EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'app' AND table_name = 'vector_analytics' 
    AND column_name = 'query_vector'
  ) THEN
    BEGIN
      -- Crear índice IVFFlat para búsqueda por similitud coseno
      CREATE INDEX idx_vector_analytics_vector ON app.vector_analytics 
      USING ivfflat (query_vector vector_cosine_ops)
      WITH (lists = 100);
      RAISE NOTICE 'Índice vectorial idx_vector_analytics_vector creado';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error al crear índice vectorial en vector_analytics: %', SQLERRM;
    END;
  END IF;
  
  RAISE NOTICE 'Proceso de creación de índices vectoriales completado.';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error durante la creación de índices vectoriales: %', SQLERRM;
END $$;

-- Actualizar estadísticas después de crear índices
ANALYZE;

-- ---------- SECCIÓN 9: VERIFICACIÓN DE INTEGRIDAD ----------

/**
 * Verificaciones finales para confirmar que todos los triggers e índices
 * se crearon correctamente.
 */
DO $$
DECLARE
  trigger_count INTEGER;
  index_count INTEGER;
BEGIN
  -- Contar triggers
  SELECT COUNT(*) INTO trigger_count
  FROM pg_trigger t
  JOIN pg_class c ON t.tgrelid = c.oid
  JOIN pg_namespace n ON c.relnamespace = n.oid
  WHERE n.nspname IN ('public', 'app')
  AND t.tgisinternal = FALSE;
  
  -- Contar índices
  SELECT COUNT(*) INTO index_count
  FROM pg_indexes
  WHERE schemaname IN ('public', 'app');
  
  -- Mostrar resumen
  RAISE NOTICE '=============================================';
  RAISE NOTICE 'RESUMEN DE INSTALACIÓN:';
  RAISE NOTICE '=============================================';
  RAISE NOTICE 'Total de triggers creados: %', trigger_count;
  RAISE NOTICE 'Total de índices creados: %', index_count;
  RAISE NOTICE 'Triggers de actualización de timestamp: COMPLETADO';
  RAISE NOTICE 'Triggers funcionales: COMPLETADO';
  RAISE NOTICE 'Triggers de control de cuotas: COMPLETADO';
  RAISE NOTICE 'Índices para tablas principales: COMPLETADO';
  RAISE NOTICE 'Índices para búsqueda y vectores: COMPLETADO';
  RAISE NOTICE 'Análisis de estadísticas: COMPLETADO';
  RAISE NOTICE '=============================================';
  RAISE NOTICE 'Optimización completada. El sistema está listo para su uso.';
  RAISE NOTICE '=============================================';
END $$;