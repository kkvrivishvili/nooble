-- ARCHIVO: init.sql PARTE 7 - Creación de Triggers e Índices
-- Propósito: Aplicar triggers a tablas y crear índices para mejorar rendimiento

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
BEGIN
  FOR i IN 1..array_length(trigger_names, 1) LOOP
    BEGIN
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', 
                     trigger_names[i], table_names[i]);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Error dropping trigger %: %', trigger_names[i], SQLERRM;
    END;
  END LOOP;
END $$;

-- Triggers para actualizar timestamp
CREATE TRIGGER update_users_timestamp BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_profiles_timestamp BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_links_timestamp BEFORE UPDATE ON links
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_subscriptions_timestamp BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_bots_timestamp BEFORE UPDATE ON bots
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_document_collections_timestamp BEFORE UPDATE ON document_collections
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_documents_timestamp BEFORE UPDATE ON documents
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_document_chunks_timestamp BEFORE UPDATE ON document_chunks
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_conversations_timestamp BEFORE UPDATE ON conversations
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_themes_timestamp BEFORE UPDATE ON themes
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_system_config_timestamp BEFORE UPDATE ON system_config
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

CREATE TRIGGER update_usage_metrics_timestamp BEFORE UPDATE ON usage_metrics
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

-- Trigger para user_roles
CREATE TRIGGER update_user_roles_timestamp BEFORE UPDATE ON user_roles
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

-- Trigger para link_groups
CREATE TRIGGER update_link_groups_timestamp BEFORE UPDATE ON link_groups
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

-- Trigger para messages
CREATE TRIGGER update_messages_timestamp BEFORE UPDATE ON messages
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

-- Trigger para bot_response_feedback
CREATE TRIGGER update_bot_response_feedback_timestamp BEFORE UPDATE ON bot_response_feedback
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

-- Trigger para vector_analytics
CREATE TRIGGER update_vector_analytics_timestamp BEFORE UPDATE ON vector_analytics
  FOR EACH ROW EXECUTE PROCEDURE update_modified_column();

-- Trigger para incrementar contador de clics
CREATE TRIGGER increment_clicks_on_analytics
  AFTER INSERT ON analytics
  FOR EACH ROW
  WHEN (NEW.link_id IS NOT NULL)
  EXECUTE PROCEDURE increment_link_clicks();

-- Trigger para actualizar última actividad en conversaciones
CREATE TRIGGER update_conversation_activity
  AFTER INSERT ON messages
  FOR EACH ROW
  EXECUTE PROCEDURE update_conversation_last_activity();

-- Triggers para cuotas
CREATE TRIGGER check_bot_quota
  BEFORE INSERT ON bots
  FOR EACH ROW 
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_bot_quota();

CREATE TRIGGER check_collection_quota
  BEFORE INSERT ON document_collections
  FOR EACH ROW 
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_collection_quota();

CREATE TRIGGER check_document_quota
  BEFORE INSERT ON documents
  FOR EACH ROW
  WHEN (NEW.deleted_at IS NULL)
  EXECUTE PROCEDURE enforce_document_quota();

CREATE TRIGGER check_vector_search_quota
  BEFORE INSERT ON vector_analytics
  FOR EACH ROW EXECUTE PROCEDURE enforce_vector_search_quota();

-- Trigger para crear particiones de analytics automáticamente
CREATE TRIGGER create_analytics_partition_trigger
  BEFORE INSERT ON analytics
  FOR EACH ROW
  EXECUTE PROCEDURE create_analytics_partition();

-- Trigger para validar configuración del sistema
CREATE TRIGGER validate_system_config_changes
  BEFORE INSERT OR UPDATE ON system_config
  FOR EACH ROW
  EXECUTE PROCEDURE validate_config_changes();

-- Crear índices principales (verificando primero si ya existen)
DO $$
BEGIN
  -- Índices para tablas principales
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_auth_id') THEN
    CREATE INDEX idx_users_auth_id ON users(auth_id) WHERE deleted_at IS NULL;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_username_search') THEN
    CREATE INDEX idx_users_username_search ON users USING gin(username gin_trgm_ops) WHERE deleted_at IS NULL;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_users_email_search') THEN
    CREATE INDEX idx_users_email_search ON users USING gin(email gin_trgm_ops) WHERE deleted_at IS NULL;
  END IF;
  
  -- Índices para tablas de Linktree
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_links_user_position') THEN
    CREATE INDEX idx_links_user_position ON links(user_id, position);
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_links_bot_id') THEN
    CREATE INDEX idx_links_bot_id ON links(bot_id) WHERE bot_id IS NOT NULL;
  END IF;
  
  -- Índice para user_roles
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_user_roles_role') THEN
    CREATE INDEX idx_user_roles_role ON user_roles(role);
  END IF;
  
  -- Índices para eventos y análisis
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_system_errors_unresolved') THEN
    CREATE INDEX idx_system_errors_unresolved ON system_errors(created_at) WHERE is_resolved = FALSE;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_usage_metrics_user_date') THEN
    CREATE INDEX idx_usage_metrics_user_date ON usage_metrics(user_id, year_month);
  END IF;
  
  -- Índices para suscripciones
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_subscriptions_status') THEN
    CREATE INDEX idx_subscriptions_status ON subscriptions(status, current_period_end);
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_subscriptions_expiring') THEN
    CREATE INDEX idx_subscriptions_expiring ON subscriptions(current_period_end) 
    WHERE status = 'active' AND auto_renew = FALSE;
  END IF;
  
  -- Índices para conversaciones y mensajes
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_messages_content_search') THEN
    CREATE INDEX idx_messages_content_search ON messages USING gin(content gin_trgm_ops);
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_conversations_search') THEN
    CREATE INDEX idx_conversations_search ON conversations USING gin(title gin_trgm_ops);
  END IF;
  
  -- Índices para búsqueda de documentos por texto
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_documents_title_search') THEN
    CREATE INDEX idx_documents_title_search ON documents USING gin(title gin_trgm_ops) WHERE deleted_at IS NULL;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_documents_content_search') THEN
    CREATE INDEX idx_documents_content_search ON documents USING gin(content gin_trgm_ops) WHERE deleted_at IS NULL;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_document_chunks_content_search') THEN
    CREATE INDEX idx_document_chunks_content_search ON document_chunks USING gin(content gin_trgm_ops);
  END IF;
  
  -- Índices para perfiles
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_profiles_custom_domain') THEN
    CREATE INDEX idx_profiles_custom_domain ON profiles(custom_domain) WHERE custom_domain IS NOT NULL;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_profiles_social_handles') THEN
    CREATE INDEX idx_profiles_social_handles ON profiles USING gin(
      to_tsvector('english', COALESCE(social_twitter, '') || ' ' || 
                            COALESCE(social_instagram, '') || ' ' || 
                            COALESCE(social_tiktok, '') || ' ' ||
                            COALESCE(social_linkedin, '') || ' ' ||
                            COALESCE(social_github, ''))
    );
  END IF;
  
  RAISE NOTICE 'Índices creados correctamente.';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error creating indexes: %', SQLERRM;
END $$;

-- Actualizar estadísticas después de crear índices
ANALYZE;

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Triggers e índices creados correctamente.';
END $$;