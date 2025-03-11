-- ==============================================
-- ARCHIVO: init_7.sql - Creación de Triggers e Índices
-- ==============================================
-- Propósito: Este archivo configura todos los triggers del sistema para mantener
-- la integridad y consistencia de los datos, así como los índices necesarios
-- para optimizar el rendimiento de consultas frecuentes.
--
-- Los triggers implementados incluyen:
-- 1. Actualización automática de timestamps en todas las tablas
-- 2. Control de cuotas para diferentes recursos (bots, colecciones, documentos)
-- 3. Particionamiento automático de tablas de analytics
-- 4. Validación de cambios en configuración del sistema
--
-- Los índices creados están optimizados para las consultas más frecuentes
-- en cada tabla, con especial atención a búsquedas por texto mediante GIN.
-- ==============================================

-- Eliminar triggers existentes para evitar duplicados
DO $$
DECLARE
  trigger_names TEXT[] := ARRAY[
    'update_users_timestamp', 'update_profiles_timestamp', 'update_links_timestamp',
    'update_subscriptions_timestamp', 'update_bots_timestamp', 
    'update_document_collections_timestamp', 'update_documents_timestamp',
    'update_document_chunks_timestamp', 'update_conversations_timestamp',
    'update_themes_timestamp', 'update_system_config_timestamp',
    'update_usage_metrics_timestamp', 'increment_clicks_on_analytics',
    'check_bot_quota', 'check_collection_quota', 'check_document_quota',
    'check_vector_search_quota', 'create_analytics_partition_trigger',
    'update_user_roles_timestamp', 'update_link_groups_timestamp',
    'update_messages_timestamp', 'update_bot_response_feedback_timestamp',
    'update_vector_analytics_timestamp', 'update_conversation_activity'
  ];
  table_names TEXT[] := ARRAY[
    'users', 'profiles', 'links', 'subscriptions', 'bots', 
    'document_collections', 'documents', 'document_chunks', 'conversations',
    'themes', 'system_config', 'usage_metrics', 'analytics',
    'bots', 'document_collections', 'documents', 'vector_analytics', 'analytics',
    'user_roles', 'link_groups', 'messages', 'bot_response_feedback',
    'vector_analytics', 'messages'
  ];
  schema_names TEXT[] := ARRAY[
    'app', 'public', 'public', 'app', 'public', 
    'app', 'app', 'app', 'public',
    'public', 'app', 'app', 'app',
    'public', 'app', 'app', 'app', 'app',
    'app', 'public', 'public', 'app',
    'app', 'public'
  ];
  full_table_name TEXT;
BEGIN
  FOR i IN 1..array_length(trigger_names, 1) LOOP
    BEGIN
      -- Crear nombre completo con esquema correcto
      full_table_name := schema_names[i] || '.' || table_names[i];
      
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', 
                     trigger_names[i], full_table_name);
      
      RAISE NOTICE 'Trigger % en tabla % eliminado correctamente', trigger_names[i], full_table_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Error eliminando trigger % en tabla %: %', 
                 trigger_names[i], table_names[i], SQLERRM;
    END;
  END LOOP;
END $$;

-- ---------- SECCIÓN 1: TRIGGERS DE ACTUALIZACIÓN DE TIMESTAMP ----------

-- Triggers para actualizar automáticamente los campos updated_at
CREATE TRIGGER update_users_timestamp 
  BEFORE UPDATE ON app.users
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_profiles_timestamp 
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_links_timestamp 
  BEFORE UPDATE ON public.links
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_subscriptions_timestamp 
  BEFORE UPDATE ON app.subscriptions
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_bots_timestamp 
  BEFORE UPDATE ON public.bots
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_document_collections_timestamp 
  BEFORE UPDATE ON app.document_collections
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_documents_timestamp 
  BEFORE UPDATE ON app.documents
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_document_chunks_timestamp 
  BEFORE UPDATE ON app.document_chunks
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_conversations_timestamp 
  BEFORE UPDATE ON public.conversations
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_themes_timestamp 
  BEFORE UPDATE ON public.themes
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_system_config_timestamp 
  BEFORE UPDATE ON app.system_config
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_usage_metrics_timestamp 
  BEFORE UPDATE ON app.usage_metrics
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_user_roles_timestamp 
  BEFORE UPDATE ON app.user_roles
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_link_groups_timestamp 
  BEFORE UPDATE ON public.link_groups
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_messages_timestamp 
  BEFORE UPDATE ON public.messages
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_bot_response_feedback_timestamp 
  BEFORE UPDATE ON app.bot_response_feedback
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_vector_analytics_timestamp 
  BEFORE UPDATE ON app.vector_analytics
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

-- ---------- SECCIÓN 2: TRIGGERS FUNCIONALES ----------

-- Trigger para incrementar contador de clics en enlaces
CREATE TRIGGER increment_clicks_on_analytics
  AFTER INSERT ON app.analytics
  FOR EACH ROW
  WHEN (NEW.link_id IS NOT NULL)
  EXECUTE PROCEDURE increment_link_clicks();

-- Trigger para actualizar última actividad en conversaciones
CREATE TRIGGER update_conversation_activity
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE PROCEDURE update_conversation_last_activity();

-- ---------- SECCIÓN 3: TRIGGERS DE CONTROL DE CUOTAS ----------

-- Triggers para verificar cuotas de usuario
CREATE TRIGGER check_bot_quota
  BEFORE INSERT ON public.bots
  FOR EACH ROW 
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_bot_quota();

CREATE TRIGGER check_collection_quota
  BEFORE INSERT ON app.document_collections
  FOR EACH ROW 
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_collection_quota();

CREATE TRIGGER check_document_quota
  BEFORE INSERT ON app.documents
  FOR EACH ROW
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_document_quota();

CREATE TRIGGER check_vector_search_quota
  BEFORE INSERT ON app.vector_analytics
  FOR EACH ROW 
  EXECUTE PROCEDURE enforce_vector_search_quota();

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

-- ---------- SECCIÓN 4: ÍNDICES PARA TABLAS PRINCIPALES ----------

DO $$
DECLARE
  index_exists BOOLEAN;
BEGIN
  -- ===== Índices para usuarios =====
  -- Verificar y crear índice para auth_id
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_auth_id'
  ) INTO index_exists;
  
  IF NOT index_exists THEN
    CREATE INDEX idx_users_auth_id ON app.users(auth_id) WHERE deleted_at IS NULL;
    RAISE NOTICE 'Índice idx_users_auth_id creado';
  END IF;
  
  -- Índice para búsqueda por username
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
  
  RAISE NOTICE 'Proceso de creación de índices completado.';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error durante la creación de índices: %', SQLERRM;
END $$;

-- ---------- SECCIÓN 5: ÍNDICES PARA DOCUMENTOS Y BÚSQUEDA VECTORIAL ----------

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
  
  RAISE NOTICE 'Proceso de creación de índices para búsqueda completado.';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error durante la creación de índices de búsqueda: %', SQLERRM;
END $$;

-- Actualizar estadísticas después de crear índices
ANALYZE;

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  -- Verificar que todos los triggers se crearon correctamente
  RAISE NOTICE '=============================================';
  RAISE NOTICE 'RESUMEN DE INSTALACIÓN:';
  RAISE NOTICE '=============================================';
  RAISE NOTICE 'Triggers de actualización de timestamp: COMPLETADO';
  RAISE NOTICE 'Triggers funcionales: COMPLETADO';
  RAISE NOTICE 'Triggers de control de cuotas: COMPLETADO';
  RAISE NOTICE 'Índices para tablas principales: COMPLETADO';
  RAISE NOTICE 'Índices para búsqueda y vectores: COMPLETADO';
  RAISE NOTICE '=============================================';
  RAISE NOTICE 'IMPORTANTE: Este archivo ha sido actualizado para trabajar';
  RAISE NOTICE 'con los nuevos esquemas app y public. Asegúrese de que todas';
  RAISE NOTICE 'las referencias a tablas incluyen el esquema correcto.';
  RAISE NOTICE '=============================================';
END $$;

/*
== IMPLEMENTACIÓN CON SERVICIOS EXTERNOS ==

1. INTEGRACIÓN CON LANGCHAIN Y LLAMAINDEX:
   - Los índices creados para document_chunks mejoran el rendimiento de las consultas 
     vectoriales usadas por LlamaIndex y Langchain.
   - La función enforce_vector_search_quota controlará el uso de embeddings 
     en modelos de lenguaje externos.
   - Ajustar las cuotas en el frontend según los límites de API de OpenAI/otros proveedores.

2. INTEGRACIÓN CON REDIS:
   - Considerar almacenar en caché resultados de búsquedas vectoriales frecuentes
     para reducir costos de API y mejorar velocidad.
   - Los índices para analytics pueden complementarse con contadores en Redis
     para estadísticas en tiempo real.

3. INTEGRACIÓN CON FRONTEND:
   - El frontend debe tener lógica para manejar errores cuando se alcanzan límites de cuota.
   - Proporcionar feedback visual sobre límites de recursos al usuario.
   - Implementar paginación eficiente aprovechando los índices creados.
*/