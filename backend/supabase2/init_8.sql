-- ARCHIVO: init.sql PARTE 8 - Políticas RLS
-- Propósito: Implementar Row Level Security para todas las tablas

-- Función para eliminar políticas existentes
CREATE OR REPLACE FUNCTION drop_all_policies()
RETURNS VOID AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN 
    SELECT 
      n.nspname AS schema_name,
      c.relname AS table_name,
      p.polname AS policy_name
    FROM pg_policy p
    JOIN pg_class c ON p.polrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE n.nspname = 'public'
  LOOP
    BEGIN
      EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', 
                    r.policy_name, r.schema_name, r.table_name);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Error dropping policy % on %.%: %', 
                  r.policy_name, r.schema_name, r.table_name, SQLERRM;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Eliminar todas las políticas existentes
SELECT drop_all_policies();

-- Habilitar RLS en todas las tablas
DO $$
DECLARE
  tables TEXT[] := ARRAY[
    'users', 'profiles', 'themes', 'subscriptions', 'links', 'analytics',
    'bots', 'document_collections', 'documents', 'document_chunks', 
    'bot_collections', 'conversations', 'messages', 'bot_response_feedback',
    'vector_analytics', 'system_errors', 'usage_metrics', 
    'system_config', 'user_config', 'subscription_plan_config',
    'user_roles', 'user_role_history', 'subscription_history',
    'link_groups', 'link_group_items', 'quota_notifications'
  ];
BEGIN
  FOR i IN 1..array_length(tables, 1) LOOP
    BEGIN
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tables[i]);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Error enabling RLS on table %: %', tables[i], SQLERRM;
    END;
  END LOOP;
END $$;

-- Habilitar RLS en tablas particionadas de analytics
DO $$
DECLARE
  partition_table TEXT;
  partition_tables CURSOR FOR 
    SELECT tablename 
    FROM pg_tables 
    WHERE schemaname = 'public' AND tablename LIKE 'analytics_y%m%';
BEGIN
  OPEN partition_tables;
  LOOP
    FETCH partition_tables INTO partition_table;
    EXIT WHEN NOT FOUND;
    
    BEGIN
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', partition_table);
      RAISE NOTICE 'Habilitado RLS en partición: %', partition_table;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Error enabling RLS on partition %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
END $$;

-- Políticas para tablas de configuración
CREATE POLICY user_config_select_policy ON user_config
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_user_configs')
  );

CREATE POLICY user_config_modify_policy ON user_config
  FOR ALL USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_user_configs')
  );

CREATE POLICY subscription_plan_config_select_policy ON subscription_plan_config
  FOR SELECT USING (TRUE);  -- Todos pueden ver

CREATE POLICY subscription_plan_config_modify_policy ON subscription_plan_config
  FOR ALL USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_subscription_configs')
  );

-- Políticas para tabla user_roles
CREATE POLICY user_roles_select_policy ON user_roles
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_users')
  );

CREATE POLICY user_roles_modify_policy ON user_roles
  FOR ALL USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_users')
  );

-- Políticas para historial de roles
CREATE POLICY user_role_history_select_policy ON user_role_history
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_user_history')
  );

-- Políticas para historial de suscripciones
CREATE POLICY subscription_history_select_policy ON subscription_history
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_subscription_history')
  );

-- Políticas para notificaciones
CREATE POLICY quota_notifications_select_policy ON quota_notifications
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id))
  );

CREATE POLICY quota_notifications_modify_policy ON quota_notifications
  FOR UPDATE USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id))
  );

-- Políticas para tabla users
CREATE POLICY user_select_policy ON users 
  FOR SELECT USING (
    auth.uid() = auth_id OR 
    (username IS NOT NULL AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_users')
  );

CREATE POLICY user_modify_policy ON users 
  FOR UPDATE USING (
    auth.uid() = auth_id OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_users')
  );

CREATE POLICY user_delete_policy ON users 
  FOR DELETE USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    auth.uid() = auth_id
  );

-- Política para tabla profiles
CREATE POLICY profile_select_policy ON profiles 
  FOR SELECT USING (
    id IN (SELECT id FROM users WHERE auth.uid() = auth_id OR (username IS NOT NULL AND deleted_at IS NULL)) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_profiles')
  );

CREATE POLICY profile_modify_policy ON profiles 
  FOR ALL USING (
    id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_profiles')
  );

-- Política para tabla links
CREATE POLICY link_select_policy ON links 
  FOR SELECT USING (
    is_active = TRUE OR 
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id))
  );

CREATE POLICY link_modify_policy ON links 
  FOR ALL USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_links')
  );

-- Políticas para grupos de enlaces
CREATE POLICY link_groups_select_policy ON link_groups
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id))
  );

CREATE POLICY link_groups_modify_policy ON link_groups
  FOR ALL USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_links')
  );

CREATE POLICY link_group_items_select_policy ON link_group_items
  FOR SELECT USING (
    group_id IN (
      SELECT id FROM link_groups 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id)
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id))
  );

CREATE POLICY link_group_items_modify_policy ON link_group_items
  FOR ALL USING (
    group_id IN (
      SELECT id FROM link_groups 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id)
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_links')
  );

-- Política para tabla analytics
CREATE POLICY analytics_select_policy ON analytics 
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_analytics')
  );

CREATE POLICY analytics_insert_policy ON analytics 
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM users) -- Permitir inserción para usuarios reales
  );

-- Políticas para tablas de RAG
CREATE POLICY bots_select_policy ON bots
  FOR SELECT USING (
    (user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL) OR 
    (id IN (SELECT bot_id FROM links WHERE is_active = TRUE) AND deleted_at IS NULL) OR
    (is_public = TRUE AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_bots')
  );

CREATE POLICY bots_modify_policy ON bots
  FOR ALL USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_bots')
  );

CREATE POLICY collections_select_policy ON document_collections
  FOR SELECT USING (
    (user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL) OR
    (is_public = TRUE AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_collections')
  );

CREATE POLICY collections_modify_policy ON document_collections
  FOR ALL USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_collections')
  );

CREATE POLICY documents_select_policy ON documents
  FOR SELECT USING (
    (collection_id IN (
      SELECT id FROM document_collections 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) AND deleted_at IS NULL) OR
    (collection_id IN (
      SELECT id FROM document_collections WHERE is_public = TRUE AND deleted_at IS NULL
    ) AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_documents')
  );

CREATE POLICY documents_modify_policy ON documents
  FOR ALL USING (
    collection_id IN (
      SELECT id FROM document_collections 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_documents')
  );

CREATE POLICY chunks_select_policy ON document_chunks
  FOR SELECT USING (
    document_id IN (
      SELECT id FROM documents 
      WHERE 
        (collection_id IN (
          SELECT id FROM document_collections 
          WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
        ) AND deleted_at IS NULL) OR
        (collection_id IN (
          SELECT id FROM document_collections WHERE is_public = TRUE AND deleted_at IS NULL
        ) AND deleted_at IS NULL)
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_document_chunks')
  );

CREATE POLICY chunks_modify_policy ON document_chunks
  FOR ALL USING (
    document_id IN (
      SELECT id FROM documents 
      WHERE collection_id IN (
        SELECT id FROM document_collections 
        WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
      ) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_document_chunks')
  );

CREATE POLICY bot_collections_select_policy ON bot_collections
  FOR SELECT USING (
    bot_id IN (
      SELECT id FROM bots 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    collection_id IN (
      SELECT id FROM document_collections 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_bot_collections')
  );

CREATE POLICY bot_collections_modify_policy ON bot_collections
  FOR ALL USING (
    bot_id IN (
      SELECT id FROM bots 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_bot_collections')
  );

-- Políticas para conversaciones y mensajes - permitiendo acceso público a bots públicos
CREATE POLICY conversations_select_policy ON conversations
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_public = TRUE OR
    bot_id IN (SELECT id FROM bots WHERE is_public = TRUE) OR -- Permitir acceso a conversaciones con bots públicos
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_conversations')
  );

-- Política para que visitantes puedan crear conversaciones con bots públicos
CREATE POLICY conversations_insert_policy ON conversations
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    bot_id IN (SELECT id FROM bots WHERE is_public = TRUE) OR
    bot_id IN (SELECT bot_id FROM links WHERE is_active = TRUE)
  );

CREATE POLICY conversations_update_policy ON conversations
  FOR UPDATE USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_conversations')
  );

CREATE POLICY messages_select_policy ON messages
  FOR SELECT USING (
    conversation_id IN (
      SELECT id FROM conversations 
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR 
            is_public = TRUE OR 
            bot_id IN (SELECT id FROM bots WHERE is_public = TRUE)
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_messages')
  );

-- Política para que visitantes puedan enviar mensajes a bots públicos
CREATE POLICY messages_insert_policy ON messages
  FOR INSERT WITH CHECK (
    conversation_id IN (
      SELECT id FROM conversations
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
            bot_id IN (SELECT id FROM bots WHERE is_public = TRUE) OR
            bot_id IN (SELECT bot_id FROM links WHERE is_active = TRUE)
    )
  );

CREATE POLICY feedback_select_policy ON bot_response_feedback
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    message_id IN (
      SELECT id FROM messages
      WHERE conversation_id IN (
        SELECT id FROM conversations
        WHERE bot_id IN (
          SELECT id FROM bots
          WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
        )
      )
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_feedback')
  );

-- Permitir a visitantes dar feedback sobre respuestas de bots públicos
CREATE POLICY feedback_insert_policy ON bot_response_feedback
  FOR INSERT WITH CHECK (
    message_id IN (
      SELECT id FROM messages
      WHERE conversation_id IN (
        SELECT id FROM conversations
        WHERE bot_id IN (SELECT id FROM bots WHERE is_public = TRUE) OR
              bot_id IN (SELECT bot_id FROM links WHERE is_active = TRUE)
      )
    ) OR 
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id)
  );

CREATE POLICY vector_analytics_select_policy ON vector_analytics
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    bot_id IN (
      SELECT id FROM bots
      WHERE user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_analytics')
  );

CREATE POLICY vector_analytics_insert_policy ON vector_analytics
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    bot_id IN (SELECT id FROM bots WHERE is_public = TRUE) OR
    bot_id IN (SELECT bot_id FROM links WHERE is_active = TRUE)
  );

-- Políticas para tablas de sistema y métricas
CREATE POLICY system_errors_select_policy ON system_errors
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_system_logs')
  );

CREATE POLICY system_errors_update_policy ON system_errors
  FOR UPDATE USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_system_logs')
  );

CREATE POLICY usage_metrics_select_policy ON usage_metrics
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_usage_metrics')
  );

-- Políticas para tablas de configuración con verificación de admin
CREATE POLICY system_config_select_policy ON system_config
  FOR SELECT USING (TRUE);  -- Todos pueden ver la configuración

CREATE POLICY system_config_modify_policy ON system_config
  FOR ALL USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id))
  );

CREATE POLICY themes_select_policy ON themes
  FOR SELECT USING (TRUE);  -- Todos pueden ver los temas

CREATE POLICY themes_modify_policy ON themes
  FOR ALL USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_themes')
  );

-- Políticas para suscripciones
CREATE POLICY subscriptions_select_policy ON subscriptions
  FOR SELECT USING (
    user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'view_subscriptions')
  );

CREATE POLICY subscriptions_modify_policy ON subscriptions
  FOR ALL USING (
    is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), 'manage_subscriptions')
  );

-- Aplicar políticas RLS a particiones de analytics
DO $$
DECLARE
  partition_table TEXT;
  partition_tables CURSOR FOR 
    SELECT tablename 
    FROM pg_tables 
    WHERE schemaname = 'public' AND tablename LIKE 'analytics_y%m%';
BEGIN
  OPEN partition_tables;
  LOOP
    FETCH partition_tables INTO partition_table;
    EXIT WHEN NOT FOUND;
    
    BEGIN
      -- Política de selección
      EXECUTE format(
        'CREATE POLICY analytics_partition_select_policy ON %I
         FOR SELECT USING (
           user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
           is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
           has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), ''view_analytics'')
         )', 
        partition_table
      );
      
      -- Política de inserción
      EXECUTE format(
        'CREATE POLICY analytics_partition_insert_policy ON %I
         FOR INSERT WITH CHECK (
           user_id IN (SELECT id FROM users) -- Permitir inserción para usuarios reales
         )', 
        partition_table
      );
      
      RAISE NOTICE 'Creadas políticas RLS para partición: %', partition_table;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Error creando políticas RLS en partición %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
END $$;

-- Crear un usuario administrador para pruebas si no existe ninguno
DO $$
DECLARE
  admin_exists BOOLEAN;
BEGIN
  -- Verificar si existe algún admin
  SELECT EXISTS (
    SELECT 1 FROM user_roles WHERE role = 'admin'
  ) INTO admin_exists;
  
  -- Si no existe, crear uno a partir del primer usuario
  IF NOT admin_exists THEN
    DECLARE
      first_user_id UUID;
    BEGIN
      -- Buscar primer usuario
      SELECT id INTO first_user_id FROM users LIMIT 1;
      
      IF first_user_id IS NOT NULL THEN
        -- Insertar rol de admin
        INSERT INTO user_roles (user_id, role, notes)
        VALUES (first_user_id, 'admin', 'Admin inicial creado por sistema');
        
        RAISE NOTICE 'Creado administrador inicial con ID %', first_user_id;
      ELSE
        RAISE NOTICE 'No se encontraron usuarios para crear administrador inicial';
      END IF;
    END;
  ELSE
    RAISE NOTICE 'Ya existen administradores en el sistema';
  END IF;
END $$;

-- Limpiar la función temporal
DROP FUNCTION IF EXISTS drop_all_policies();

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Políticas RLS creadas correctamente.';
END $$;