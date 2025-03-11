-- ==============================================
-- ARCHIVO: init_8.sql - Políticas RLS (Row Level Security)
-- ==============================================
-- Propósito: Implementar políticas de seguridad a nivel de fila para todas las 
-- tablas del sistema, garantizando que los usuarios solo puedan acceder a los 
-- datos que les corresponden según sus permisos.
--
-- IMPORTANTE: Este archivo actualiza todas las políticas RLS para reflejar la nueva
-- estructura de esquemas, donde las tablas públicas permanecen en el esquema 'public'
-- y las tablas internas se han movido al esquema 'app'.
-- ==============================================

-- ---------- SECCIÓN 1: LIMPIEZA DE POLÍTICAS ANTIGUAS ----------

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
    WHERE n.nspname IN ('public', 'app')
  LOOP
    BEGIN
      EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', 
                    r.policy_name, r.schema_name, r.table_name);
      RAISE NOTICE 'Dropped policy % on %.%', r.policy_name, r.schema_name, r.table_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error dropping policy % on %.%: %', 
                  r.policy_name, r.schema_name, r.table_name, SQLERRM;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Eliminar todas las políticas existentes
SELECT drop_all_policies();

-- ---------- SECCIÓN 2: HABILITAR RLS EN TODAS LAS TABLAS ----------

-- Habilitar RLS en tablas del esquema 'public'
DO $$
DECLARE
  public_tables TEXT[] := ARRAY[
    'bots', 'conversations', 'messages', 'links', 'link_groups', 
    'link_group_items', 'themes', 'profiles'
  ];
BEGIN
  FOR i IN 1..array_length(public_tables, 1) LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', public_tables[i]);
      RAISE NOTICE 'Enabled RLS on public.%', public_tables[i];
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error enabling RLS on public.%: %', public_tables[i], SQLERRM;
    END;
  END LOOP;
END $$;

-- Habilitar RLS en tablas del esquema 'app'
DO $$
DECLARE
  app_tables TEXT[] := ARRAY[
    'users', 'user_config', 'subscription_plan_config', 
    'subscriptions', 'usage_metrics', 'system_config',
    'document_collections', 'documents', 'document_chunks', 
    'bot_collections', 'vector_analytics', 'bot_response_feedback',
    'system_errors', 'analytics', 'quota_notifications',
    'user_roles', 'user_role_history', 'subscription_history'
  ];
BEGIN
  FOR i IN 1..array_length(app_tables, 1) LOOP
    BEGIN
      EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', app_tables[i]);
      RAISE NOTICE 'Enabled RLS on app.%', app_tables[i];
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error enabling RLS on app.%: %', app_tables[i], SQLERRM;
    END;
  END LOOP;
END $$;

-- Habilitar RLS en tablas particionadas de analytics y vector_analytics
DO $$
DECLARE
  partition_table TEXT;
  partition_tables CURSOR FOR 
    SELECT tablename 
    FROM pg_tables 
    WHERE schemaname = 'app' AND (tablename LIKE 'analytics_y%m%' OR tablename LIKE 'vector_analytics_y%m%');
BEGIN
  OPEN partition_tables;
  LOOP
    FETCH partition_tables INTO partition_table;
    EXIT WHEN NOT FOUND;
    
    BEGIN
      EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', partition_table);
      RAISE NOTICE 'Enabled RLS on partition: app.%', partition_table;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error enabling RLS on partition app.%: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
END $$;

-- ---------- SECCIÓN 3: POLÍTICAS PARA TABLAS DE USUARIOS Y CONFIGURACIÓN ----------

-- Políticas para tabla users
CREATE POLICY user_select_policy ON app.users 
  FOR SELECT USING (
    auth.uid() = auth_id OR 
    (username IS NOT NULL AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_users')
  );

CREATE POLICY user_modify_policy ON app.users 
  FOR UPDATE USING (
    auth.uid() = auth_id OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_users')
  );

CREATE POLICY user_delete_policy ON app.users 
  FOR DELETE USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    auth.uid() = auth_id
  );

-- Políticas para tabla de configuraciones de usuario
CREATE POLICY user_config_select_policy ON app.user_config
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_user_configs')
  );

CREATE POLICY user_config_modify_policy ON app.user_config
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_user_configs')
  );

-- Políticas para configuración por plan de suscripción
CREATE POLICY subscription_plan_config_select_policy ON app.subscription_plan_config
  FOR SELECT USING (TRUE);  -- Todos pueden ver

CREATE POLICY subscription_plan_config_modify_policy ON app.subscription_plan_config
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_subscription_configs')
  );

-- Políticas para configuración global del sistema
CREATE POLICY system_config_select_policy ON app.system_config
  FOR SELECT USING (TRUE);  -- Todos pueden ver la configuración

CREATE POLICY system_config_modify_policy ON app.system_config
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id))
  );

-- ---------- SECCIÓN 4: POLÍTICAS PARA ROLES Y SUSCRIPCIONES ----------

-- Políticas para tabla user_roles
CREATE POLICY user_roles_select_policy ON app.user_roles
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_users')
  );

CREATE POLICY user_roles_modify_policy ON app.user_roles
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_users')
  );

-- Políticas para historial de roles
CREATE POLICY user_role_history_select_policy ON app.user_role_history
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_user_history')
  );

-- Políticas para tabla de suscripciones
CREATE POLICY subscriptions_select_policy ON app.subscriptions
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_subscriptions')
  );

CREATE POLICY subscriptions_modify_policy ON app.subscriptions
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_subscriptions')
  );

-- Políticas para historial de suscripciones
CREATE POLICY subscription_history_select_policy ON app.subscription_history
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_subscription_history')
  );

-- ---------- SECCIÓN 5: POLÍTICAS PARA PERFILES Y TEMAS ----------

-- Política para tabla profiles (pública)
CREATE POLICY profile_select_policy ON public.profiles 
  FOR SELECT USING (
    id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id OR (username IS NOT NULL AND deleted_at IS NULL)) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_profiles')
  );

CREATE POLICY profile_modify_policy ON public.profiles 
  FOR ALL USING (
    id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_profiles')
  );

-- Políticas para temas (públicos)
CREATE POLICY themes_select_policy ON public.themes
  FOR SELECT USING (TRUE);  -- Todos pueden ver los temas

CREATE POLICY themes_modify_policy ON public.themes
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_themes')
  );

-- ---------- SECCIÓN 6: POLÍTICAS PARA ENLACES Y GRUPOS ----------

-- Política para tabla links (pública)
CREATE POLICY link_select_policy ON public.links 
  FOR SELECT USING (
    is_active = TRUE OR 
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id))
  );

CREATE POLICY link_modify_policy ON public.links 
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_links')
  );

-- Políticas para grupos de enlaces (públicos)
CREATE POLICY link_groups_select_policy ON public.link_groups
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id))
  );

CREATE POLICY link_groups_modify_policy ON public.link_groups
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_links')
  );

CREATE POLICY link_group_items_select_policy ON public.link_group_items
  FOR SELECT USING (
    group_id IN (
      SELECT id FROM public.link_groups 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id)
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id))
  );

CREATE POLICY link_group_items_modify_policy ON public.link_group_items
  FOR ALL USING (
    group_id IN (
      SELECT id FROM public.link_groups 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id)
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_links')
  );

-- ---------- SECCIÓN 7: POLÍTICAS PARA TABLAS RAG ----------

-- Políticas para bots (públicos)
CREATE POLICY bots_select_policy ON public.bots
  FOR SELECT USING (
    (user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL) OR 
    (id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE) AND deleted_at IS NULL) OR
    (is_public = TRUE AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_bots')
  );

CREATE POLICY bots_modify_policy ON public.bots
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_bots')
  );

-- Políticas para colecciones de documentos (internas)
CREATE POLICY collections_select_policy ON app.document_collections
  FOR SELECT USING (
    (user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL) OR
    (is_public = TRUE AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_collections')
  );

CREATE POLICY collections_modify_policy ON app.document_collections
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_collections')
  );

-- Políticas para documentos (internos)
CREATE POLICY documents_select_policy ON app.documents
  FOR SELECT USING (
    (collection_id IN (
      SELECT id FROM app.document_collections 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) AND deleted_at IS NULL) OR
    (collection_id IN (
      SELECT id FROM app.document_collections WHERE is_public = TRUE AND deleted_at IS NULL
    ) AND deleted_at IS NULL) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_documents')
  );

CREATE POLICY documents_modify_policy ON app.documents
  FOR ALL USING (
    collection_id IN (
      SELECT id FROM app.document_collections 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_documents')
  );

-- Políticas para chunks de documentos (internos)
CREATE POLICY chunks_select_policy ON app.document_chunks
  FOR SELECT USING (
    document_id IN (
      SELECT id FROM app.documents 
      WHERE 
        (collection_id IN (
          SELECT id FROM app.document_collections 
          WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
        ) AND deleted_at IS NULL) OR
        (collection_id IN (
          SELECT id FROM app.document_collections WHERE is_public = TRUE AND deleted_at IS NULL
        ) AND deleted_at IS NULL)
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_document_chunks')
  );

CREATE POLICY chunks_modify_policy ON app.document_chunks
  FOR ALL USING (
    document_id IN (
      SELECT id FROM app.documents 
      WHERE collection_id IN (
        SELECT id FROM app.document_collections 
        WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
      ) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_document_chunks')
  );

-- Políticas para relaciones bot-colección (internas)
CREATE POLICY bot_collections_select_policy ON app.bot_collections
  FOR SELECT USING (
    bot_id IN (
      SELECT id FROM public.bots 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    collection_id IN (
      SELECT id FROM app.document_collections 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_bot_collections')
  );

CREATE POLICY bot_collections_modify_policy ON app.bot_collections
  FOR ALL USING (
    bot_id IN (
      SELECT id FROM public.bots 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_bot_collections')
  );

-- ---------- SECCIÓN 8: POLÍTICAS PARA CONVERSACIONES Y MENSAJES ----------

-- Políticas para conversaciones (públicas) - permitiendo acceso público a bots públicos
CREATE POLICY conversations_select_policy ON public.conversations
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_public = TRUE OR
    bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR -- Permitir acceso a conversaciones con bots públicos
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_conversations')
  );

-- Política para que visitantes puedan crear conversaciones con bots públicos
CREATE POLICY conversations_insert_policy ON public.conversations
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR
    bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE)
  );

CREATE POLICY conversations_update_policy ON public.conversations
  FOR UPDATE USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_conversations')
  );

-- Políticas para mensajes (públicos)
CREATE POLICY messages_select_policy ON public.messages
  FOR SELECT USING (
    conversation_id IN (
      SELECT id FROM public.conversations 
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR 
            is_public = TRUE OR 
            bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE)
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_messages')
  );

-- Política para que visitantes puedan enviar mensajes a bots públicos
CREATE POLICY messages_insert_policy ON public.messages
  FOR INSERT WITH CHECK (
    conversation_id IN (
      SELECT id FROM public.conversations
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
            bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR
            bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE)
    )
  );

-- Políticas para feedback de respuestas (interno)
CREATE POLICY feedback_select_policy ON app.bot_response_feedback
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    message_id IN (
      SELECT id FROM public.messages
      WHERE conversation_id IN (
        SELECT id FROM public.conversations
        WHERE bot_id IN (
          SELECT id FROM public.bots
          WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
        )
      )
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_feedback')
  );

-- Permitir a visitantes dar feedback sobre respuestas de bots públicos
CREATE POLICY feedback_insert_policy ON app.bot_response_feedback
  FOR INSERT WITH CHECK (
    message_id IN (
      SELECT id FROM public.messages
      WHERE conversation_id IN (
        SELECT id FROM public.conversations
        WHERE bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR
              bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE)
      )
    ) OR 
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id)
  );

-- ---------- SECCIÓN 9: POLÍTICAS PARA ANALYTICS Y MONITOREO ----------

-- Políticas para analytics (interna)
CREATE POLICY analytics_select_policy ON app.analytics 
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_analytics')
  );

CREATE POLICY analytics_insert_policy ON app.analytics 
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM app.users) -- Permitir inserción para usuarios reales
  );

-- Políticas para vector_analytics (interna)
CREATE POLICY vector_analytics_select_policy ON app.vector_analytics
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    bot_id IN (
      SELECT id FROM public.bots
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_analytics')
  );

CREATE POLICY vector_analytics_insert_policy ON app.vector_analytics
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR
    bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE)
  );

-- Políticas para tablas de sistema y métricas (internas)
CREATE POLICY system_errors_select_policy ON app.system_errors
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_system_logs')
  );

CREATE POLICY system_errors_update_policy ON app.system_errors
  FOR UPDATE USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_system_logs')
  );

CREATE POLICY usage_metrics_select_policy ON app.usage_metrics
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_usage_metrics')
  );

-- Políticas para notificaciones (internas)
CREATE POLICY quota_notifications_select_policy ON app.quota_notifications
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id))
  );

CREATE POLICY quota_notifications_modify_policy ON app.quota_notifications
  FOR UPDATE USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id))
  );

-- ---------- SECCIÓN 10: POLÍTICAS PARA PARTICIONES DE ANALYTICS ----------

-- Aplicar políticas RLS a particiones de analytics
DO $$
DECLARE
  partition_table TEXT;
  partition_tables CURSOR FOR 
    SELECT tablename 
    FROM pg_tables 
    WHERE schemaname = 'app' AND tablename LIKE 'analytics_y%m%';
BEGIN
  OPEN partition_tables;
  LOOP
    FETCH partition_tables INTO partition_table;
    EXIT WHEN NOT FOUND;
    
    BEGIN
      -- Política de selección
      EXECUTE format(
        'CREATE POLICY analytics_partition_select_policy ON app.%I
         FOR SELECT USING (
           user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
           is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
           has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), ''view_analytics'')
         )', 
        partition_table
      );
      
      -- Política de inserción
      EXECUTE format(
        'CREATE POLICY analytics_partition_insert_policy ON app.%I
         FOR INSERT WITH CHECK (
           user_id IN (SELECT id FROM app.users) -- Permitir inserción para usuarios reales
         )', 
        partition_table
      );
      
      RAISE NOTICE 'Creadas políticas RLS para partición analytics: %', partition_table;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando políticas RLS en partición %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
END $$;

-- Aplicar políticas RLS a particiones de vector_analytics
DO $$
DECLARE
  partition_table TEXT;
  partition_tables CURSOR FOR 
    SELECT tablename 
    FROM pg_tables 
    WHERE schemaname = 'app' AND tablename LIKE 'vector_analytics_y%m%';
BEGIN
  OPEN partition_tables;
  LOOP
    FETCH partition_tables INTO partition_table;
    EXIT WHEN NOT FOUND;
    
    BEGIN
      -- Política de selección
      EXECUTE format(
        'CREATE POLICY vector_analytics_partition_select_policy ON app.%I
         FOR SELECT USING (
           user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
           bot_id IN (
             SELECT id FROM public.bots
             WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
           ) OR
           is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
           has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), ''view_analytics'')
         )', 
        partition_table
      );
      
      -- Política de inserción
      EXECUTE format(
        'CREATE POLICY vector_analytics_partition_insert_policy ON app.%I
         FOR INSERT WITH CHECK (
           user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
           bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR
           bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE)
         )', 
        partition_table
      );
      
      RAISE NOTICE 'Creadas políticas RLS para partición vector_analytics: %', partition_table;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando políticas RLS en partición %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
END $$;

-- ---------- SECCIÓN 11: CREACIÓN DE ADMIN INICIAL ----------

-- Crear un usuario administrador para pruebas si no existe ninguno
DO $$
DECLARE
  admin_exists BOOLEAN;
BEGIN
  -- Verificar si existe algún admin
  SELECT EXISTS (
    SELECT 1 FROM app.user_roles WHERE role = 'admin'
  ) INTO admin_exists;
  
  -- Si no existe, crear uno a partir del primer usuario
  IF NOT admin_exists THEN
    DECLARE
      first_user_id UUID;
    BEGIN
      -- Buscar primer usuario
      SELECT id INTO first_user_id FROM app.users LIMIT 1;
      
      IF first_user_id IS NOT NULL THEN
        -- Insertar rol de admin
        INSERT INTO app.user_roles (user_id, role, notes)
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

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  RAISE NOTICE 'Políticas RLS creadas correctamente para la nueva estructura de esquemas';
  RAISE NOTICE 'Tablas públicas (esquema public): bots, conversations, messages, links, link_groups, link_group_items, themes, profiles';
  RAISE NOTICE 'Tablas internas (esquema app): users, user_config, subscription_plan_config, subscriptions, etc.';
END $$;