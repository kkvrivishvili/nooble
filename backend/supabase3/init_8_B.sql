-- ==============================================
-- ARCHIVO: init_8.sql - Políticas RLS (Row Level Security)
-- ==============================================
-- Propósito: Implementar políticas de seguridad a nivel de fila para todas las
-- tablas del sistema, garantizando que los usuarios solo puedan acceder a los
-- datos que les corresponden según sus permisos.
--
-- Este archivo:
--   1. Limpia todas las políticas RLS existentes
--   2. Habilita RLS en todas las tablas relevantes
--   3. Implementa políticas para tablas principales (usuarios, perfiles)
--   4. Implementa políticas para tablas de contenido (bots, colecciones)
--   5. Implementa políticas para tablas de interacción (conversaciones, mensajes)
--   6. Implementa políticas para tablas de analítica y métricas
--   7. Configura políticas específicas para particiones
--   8. Crea un usuario administrador inicial si no existe
--
-- IMPORTANTE: Las políticas respetan la estructura de esquemas, donde las tablas
-- públicas están en el esquema 'public' y las tablas internas en el esquema 'app'.
-- ==============================================

-- ---------- SECCIÓN 1: LIMPIEZA DE POLÍTICAS ANTIGUAS ----------

/**
 * Función para eliminar todas las políticas de seguridad existentes en los
 * esquemas 'public' y 'app'. Esto evita conflictos al recrear las políticas.
 */
CREATE OR REPLACE FUNCTION drop_all_policies()
RETURNS VOID AS $$
DECLARE
  r RECORD;
  policy_count INTEGER := 0;
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
    ORDER BY n.nspname, c.relname, p.polname
  LOOP
    BEGIN
      EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I',
                    r.policy_name, r.schema_name, r.table_name);
      policy_count := policy_count + 1;
      RAISE NOTICE 'Eliminada política % en %.%', r.policy_name, r.schema_name, r.table_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error eliminando política % en %.%: %',
                  r.policy_name, r.schema_name, r.table_name, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Total de políticas eliminadas: %', policy_count;
END;
$$ LANGUAGE plpgsql;

-- Eliminar todas las políticas existentes
SELECT drop_all_policies();

-- ---------- SECCIÓN 2: HABILITAR RLS EN TODAS LAS TABLAS ----------

/**
 * Habilitar RLS en tablas del esquema 'public'
 * Estas tablas contienen datos accesibles públicamente, pero con restricciones
 */
CREATE OR REPLACE FUNCTION enable_rls_public_tables()
RETURNS VOID AS $$
DECLARE
  public_tables TEXT[] := ARRAY[
    'bots', 'conversations', 'messages', 'links', 'link_groups',
    'link_group_items', 'themes', 'profiles'
  ];
  table_exists BOOLEAN;
BEGIN
  FOR i IN 1..array_length(public_tables, 1) LOOP
    -- Verificar primero que la tabla existe
    SELECT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = public_tables[i]
    ) INTO table_exists;

    IF table_exists THEN
      BEGIN
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', public_tables[i]);
        RAISE NOTICE 'Habilitado RLS en public.%', public_tables[i];
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Error habilitando RLS en public.%: %', public_tables[i], SQLERRM;
      END;
    ELSE
      RAISE WARNING 'Tabla public.% no existe, saltando habilitación de RLS', public_tables[i];
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

SELECT enable_rls_public_tables();


/**
 * Habilitar RLS en tablas del esquema 'app'
 * Estas tablas contienen datos internos con mayor nivel de seguridad
 */
CREATE OR REPLACE FUNCTION enable_rls_app_tables()
RETURNS VOID AS $$
DECLARE
  app_tables TEXT[] := ARRAY[
    'users', 'user_config', 'subscription_plan_config',
    'subscriptions', 'usage_metrics', 'system_config',
    'document_collections', 'documents', 'document_chunks',
    'bot_collections', 'vector_analytics', 'bot_response_feedback',
    'system_errors', 'analytics', 'quota_notifications',
    'user_roles', 'user_role_history', 'subscription_history'
  ];
  table_exists BOOLEAN;
BEGIN
  FOR i IN 1..array_length(app_tables, 1) LOOP
    -- Verificar primero que la tabla existe
    SELECT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'app' AND table_name = app_tables[i]
    ) INTO table_exists;

    IF table_exists THEN
      BEGIN
        EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', app_tables[i]);
        RAISE NOTICE 'Habilitado RLS en app.%', app_tables[i];
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Error habilitando RLS en app.%: %', app_tables[i], SQLERRM;
      END;
    ELSE
      RAISE WARNING 'Tabla app.% no existe, saltando habilitación de RLS', app_tables[i];
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

SELECT enable_rls_app_tables();


/**
 * Habilitar RLS en tablas particionadas de analytics y vector_analytics
 */
CREATE OR REPLACE FUNCTION enable_rls_partitioned_tables()
RETURNS VOID AS $$
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
      RAISE NOTICE 'Habilitado RLS en partición: app.%', partition_table;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error habilitando RLS en partición app.%: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
END;
$$ LANGUAGE plpgsql;

SELECT enable_rls_partitioned_tables();

-- ---------- SECCIÓN 3: POLÍTICAS PARA TABLAS DE USUARIOS Y CONFIGURACIÓN ----------

/**
 * Políticas para tabla users
 * Control de acceso a datos de usuario basado en propiedad y roles
 */
CREATE POLICY user_select_policy ON app.users
  FOR SELECT USING (
    auth.uid() = auth_id OR -- Usuario propio
    (username IS NOT NULL AND deleted_at IS NULL) OR -- Usuarios públicos activos
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_users') -- Usuarios con permiso específico
  );

CREATE POLICY user_modify_policy ON app.users
  FOR UPDATE USING (
    auth.uid() = auth_id OR -- Usuario modifica sus propios datos
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_users') -- Usuarios con permiso específico
  );

CREATE POLICY user_delete_policy ON app.users
  FOR DELETE USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    auth.uid() = auth_id -- Usuario elimina su propia cuenta
  );

/**
 * Políticas para tabla de configuraciones de usuario
 * Permite a usuarios ver solo sus propias configuraciones, y a admins ver todas
 */
CREATE POLICY user_config_select_policy ON app.user_config
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Configuración propia
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_user_configs') -- Usuarios con permiso específico
  );

CREATE POLICY user_config_modify_policy ON app.user_config
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_user_configs') -- Usuarios con permiso específico
  );

/**
 * Políticas para configuración por plan de suscripción
 */
CREATE POLICY subscription_plan_config_select_policy ON app.subscription_plan_config
  FOR SELECT USING (TRUE);  -- Todos pueden ver información de planes

CREATE POLICY subscription_plan_config_modify_policy ON app.subscription_plan_config
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_subscription_configs') -- Usuarios con permiso específico
  );

/**
 * Políticas para configuración global del sistema
 */
CREATE POLICY system_config_select_policy ON app.system_config
  FOR SELECT USING (TRUE);  -- Todos pueden ver la configuración

CREATE POLICY system_config_modify_policy ON app.system_config
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) -- Solo administradores
  );

-- ---------- SECCIÓN 4: POLÍTICAS PARA ROLES Y SUSCRIPCIONES ----------

/**
 * Políticas para tabla user_roles
 * Control de acceso a roles de usuario
 */
CREATE POLICY user_roles_select_policy ON app.user_roles
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Roles propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_users') -- Usuarios con permiso específico
  );

CREATE POLICY user_roles_modify_policy ON app.user_roles
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_users') -- Usuarios con permiso específico
  );

/**
 * Políticas para historial de roles
 * Control de acceso a historial de cambios de roles
 */
CREATE POLICY user_role_history_select_policy ON app.user_role_history
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Historial propio
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_user_history') -- Usuarios con permiso específico
  );

/**
 * Políticas para tabla de suscripciones
 * Control de acceso a suscripciones de usuario
 */
CREATE POLICY subscriptions_select_policy ON app.subscriptions
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Suscripción propia
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_subscriptions') -- Usuarios con permiso específico
  );

CREATE POLICY subscriptions_modify_policy ON app.subscriptions
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_subscriptions') -- Usuarios con permiso específico
  );

/**
 * Políticas para historial de suscripciones
 * Control de acceso a historial de cambios de suscripciones
 */
CREATE POLICY subscription_history_select_policy ON app.subscription_history
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Historial propio
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_subscription_history') -- Usuarios con permiso específico
  );

-- ---------- SECCIÓN 5: POLÍTICAS PARA PERFILES Y TEMAS ----------

/**
 * Políticas para tabla profiles
 * Control de acceso a perfiles de usuario
 */
CREATE POLICY profile_select_policy ON public.profiles
  FOR SELECT USING (
    id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id OR (username IS NOT NULL AND deleted_at IS NULL)) OR -- Perfil propio o público
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_profiles') -- Usuarios con permiso específico
  );

CREATE POLICY profile_modify_policy ON public.profiles
  FOR ALL USING (
    id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Perfil propio
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_profiles') -- Usuarios con permiso específico
  );

/**
 * Políticas para temas visuales (públicos)
 */
CREATE POLICY themes_select_policy ON public.themes
  FOR SELECT USING (TRUE);  -- Todos pueden ver los temas

CREATE POLICY themes_modify_policy ON public.themes
  FOR ALL USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_themes') -- Usuarios con permiso específico
  );

-- ---------- SECCIÓN 6: POLÍTICAS PARA ENLACES Y GRUPOS ----------

/**
 * Políticas para tabla links
 * Control de acceso a enlaces Linktree
 */
CREATE POLICY link_select_policy ON public.links
  FOR SELECT USING (
    is_active = TRUE OR -- Enlaces públicos activos
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Enlaces propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) -- Administradores
  );

CREATE POLICY link_modify_policy ON public.links
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Enlaces propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_links') -- Usuarios con permiso específico
  );

/**
 * Políticas para grupos de enlaces
 */
CREATE POLICY link_groups_select_policy ON public.link_groups
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Grupos propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) -- Administradores
  );

CREATE POLICY link_groups_modify_policy ON public.link_groups
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Grupos propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_links') -- Usuarios con permiso específico
  );

/**
 * Políticas para elementos dentro de grupos de enlaces
 */
CREATE POLICY link_group_items_select_policy ON public.link_group_items
  FOR SELECT USING (
    group_id IN (
      SELECT id FROM public.link_groups
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id)
    ) OR -- Elementos en grupos propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) -- Administradores
  );

CREATE POLICY link_group_items_modify_policy ON public.link_group_items
  FOR ALL USING (
    group_id IN (
      SELECT id FROM public.link_groups
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id)
    ) OR -- Elementos en grupos propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id from app.users WHERE auth.uid() = auth_id), 'manage_links') -- Usuarios con permiso específico
  );

-- ---------- SECCIÓN 7: POLÍTICAS PARA TABLAS RAG ----------

/**
 * Políticas para bots (públicos)
 * Control de acceso a chatbots
 */
CREATE POLICY bots_select_policy ON public.bots
  FOR SELECT USING (
    (user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL) OR -- Bots propios
    (id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE) AND deleted_at IS NULL) OR -- Bots enlazados activos
    (is_public = TRUE AND deleted_at IS NULL) OR -- Bots públicos
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_bots') -- Usuarios con permiso específico
  );

CREATE POLICY bots_modify_policy ON public.bots
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Bots propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_bots') -- Usuarios con permiso específico
  );

/**
 * Políticas para colecciones de documentos
 * Control de acceso a colecciones
 */
CREATE POLICY collections_select_policy ON app.document_collections
  FOR SELECT USING (
    (user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL) OR -- Colecciones propias
    (is_public = TRUE AND deleted_at IS NULL) OR -- Colecciones públicas
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_collections') -- Usuarios con permiso específico
  );

CREATE POLICY collections_modify_policy ON app.document_collections
  FOR ALL USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Colecciones propias
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_collections') -- Usuarios con permiso específico
  );

/**
 * Políticas para documentos
 * Control de acceso a documentos individuales
 */
CREATE POLICY documents_select_policy ON app.documents
  FOR SELECT USING (
    (collection_id IN (
      SELECT id FROM app.document_collections
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) AND deleted_at IS NULL) OR -- Documentos en colecciones propias
    (collection_id IN (
      SELECT id FROM app.document_collections WHERE is_public = TRUE AND deleted_at IS NULL
    ) AND deleted_at IS NULL) OR -- Documentos en colecciones públicas
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_documents') -- Usuarios con permiso específico
  );

CREATE POLICY documents_modify_policy ON app.documents
  FOR ALL USING (
    collection_id IN (
      SELECT id FROM app.document_collections
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR -- Documentos en colecciones propias
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_documents') -- Usuarios con permiso específico
  );

/**
 * Políticas para chunks de documentos
 * Control de acceso a fragmentos vectorizados
 */
CREATE POLICY chunks_select_policy ON app.document_chunks
  FOR SELECT USING (
    document_id IN (
      SELECT id FROM app.documents
      WHERE
        (collection_id IN (
          SELECT id FROM app.document_collections
          WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
        ) AND deleted_at IS NULL) OR -- Chunks en documentos propios
        (collection_id IN (
          SELECT id FROM app.document_collections WHERE is_public = TRUE AND deleted_at IS NULL
        ) AND deleted_at IS NULL) -- Chunks en documentos públicos
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_document_chunks') -- Usuarios con permiso específico
  );

CREATE POLICY chunks_modify_policy ON app.document_chunks
  FOR ALL USING (
    document_id IN (
      SELECT id FROM app.documents
      WHERE collection_id IN (
        SELECT id FROM app.document_collections
        WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
      ) AND deleted_at IS NULL
    ) OR -- Chunks en documentos propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_document_chunks') -- Usuarios con permiso específico
  );

/**
 * Políticas para relaciones bot-colección
 * Control de acceso a las asociaciones entre bots y colecciones
 */
CREATE POLICY bot_collections_select_policy ON app.bot_collections
  FOR SELECT USING (
    bot_id IN (
      SELECT id FROM public.bots
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR -- Relaciones con bots propios
    collection_id IN (
      SELECT id FROM app.document_collections
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR -- Relaciones con colecciones propias
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_bot_collections') -- Usuarios con permiso específico
  );

CREATE POLICY bot_collections_modify_policy ON app.bot_collections
  FOR ALL USING (
    bot_id IN (
      SELECT id FROM public.bots
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR -- Relaciones con bots propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_bot_collections') -- Usuarios con permiso específico
  );

-- ---------- SECCIÓN 8: POLÍTICAS PARA CONVERSACIONES Y MENSAJES ----------

/**
 * Políticas para conversaciones
 * Control de acceso a conversaciones, permitiendo acceso público a bots públicos
 */
CREATE POLICY conversations_select_policy ON public.conversations
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Conversaciones propias
    is_public = TRUE OR -- Conversaciones públicas
    bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR -- Conversaciones con bots públicos
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_conversations') -- Usuarios con permiso específico
  );

/**
 * Política para que visitantes puedan crear conversaciones con bots públicos
 */
CREATE POLICY conversations_insert_policy ON public.conversations
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Conversaciones propias
    bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR -- Conversaciones con bots públicos
    bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE) -- Conversaciones con bots enlazados
  );

CREATE POLICY conversations_update_policy ON public.conversations
  FOR UPDATE USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Conversaciones propias
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_conversations') -- Usuarios con permiso específico
  );

/**
 * Políticas para mensajes
 * Control de acceso a mensajes dentro de conversaciones
 */
CREATE POLICY messages_select_policy ON public.messages
  FOR SELECT USING (
    conversation_id IN (
      SELECT id FROM public.conversations
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Mensajes en conversaciones propias
            is_public = TRUE OR -- Mensajes en conversaciones públicas
            bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) -- Mensajes con bots públicos
    ) OR
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_messages') -- Usuarios con permiso específico
  );

/**
 * Política para que visitantes puedan enviar mensajes a bots públicos
 */
CREATE POLICY messages_insert_policy ON public.messages
  FOR INSERT WITH CHECK (
    conversation_id IN (
      SELECT id FROM public.conversations
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Mensajes en conversaciones propias
            bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR -- Mensajes con bots públicos
            bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE) -- Mensajes con bots enlazados
    )
  );

/**
 * Políticas para feedback de respuestas de bots
 * Control de acceso a comentarios y calificaciones de respuestas
 */
CREATE POLICY feedback_select_policy ON app.bot_response_feedback
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Feedback propio
    message_id IN (
      SELECT id FROM public.messages
      WHERE conversation_id IN (
        SELECT id FROM public.conversations
        WHERE bot_id IN (
          SELECT id FROM public.bots
          WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
        )
      )
    ) OR -- Feedback sobre respuestas de bots propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_feedback') -- Usuarios con permiso específico
  );

/**
 * Permitir a visitantes dar feedback sobre respuestas de bots públicos
 */
CREATE POLICY feedback_insert_policy ON app.bot_response_feedback
  FOR INSERT WITH CHECK (
    message_id IN (
      SELECT id FROM public.messages
      WHERE conversation_id IN (
        SELECT id FROM public.conversations
        WHERE bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR -- Feedback sobre bots públicos
              bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE) -- Feedback sobre bots enlazados
      )
    ) OR
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) -- Feedback de usuario autenticado
  );

-- ---------- SECCIÓN 9: POLÍTICAS PARA ANALYTICS Y MONITOREO ----------

/**
 * Políticas para analytics
 * Control de acceso a datos de análisis
 */
CREATE POLICY analytics_select_policy ON app.analytics
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Analytics propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_analytics') -- Usuarios con permiso específico
  );

CREATE POLICY analytics_insert_policy ON app.analytics
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM app.users) -- Permitir inserción para usuarios reales
  );

/**
 * Políticas para vector_analytics
 * Control de acceso a datos de búsquedas vectoriales
 */
CREATE POLICY vector_analytics_select_policy ON app.vector_analytics
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Analytics propios
    bot_id IN (
      SELECT id FROM public.bots
      WHERE user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) AND deleted_at IS NULL
    ) OR -- Analytics de bots propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_analytics') -- Usuarios con permiso específico
  );

CREATE POLICY vector_analytics_insert_policy ON app.vector_analytics
  FOR INSERT WITH CHECK (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Analytics propios
    bot_id IN (SELECT id FROM public.bots WHERE is_public = TRUE) OR -- Analytics de bots públicos
    bot_id IN (SELECT bot_id FROM public.links WHERE is_active = TRUE) -- Analytics de bots enlazados
  );

/**
 * Políticas para tablas de sistema y métricas
 */
CREATE POLICY system_errors_select_policy ON app.system_errors
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Errores propios
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_system_logs') -- Usuarios con permiso específico
  );

CREATE POLICY system_errors_update_policy ON app.system_errors
  FOR UPDATE USING (
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'manage_system_logs') -- Usuarios con permiso específico
  );

CREATE POLICY usage_metrics_select_policy ON app.usage_metrics
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Métricas propias
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR -- Administradores
    has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), 'view_usage_metrics') -- Usuarios con permiso específico
  );

/**
 * Políticas para notificaciones
 */
CREATE POLICY quota_notifications_select_policy ON app.quota_notifications
  FOR SELECT USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Notificaciones propias
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) -- Administradores
  );

CREATE POLICY quota_notifications_modify_policy ON app.quota_notifications
  FOR UPDATE USING (
    user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR -- Notificaciones propias
    is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) -- Administradores
  );

-- ---------- SECCIÓN 10: POLÍTICAS PARA PARTICIONES DE ANALYTICS ----------

/**
 * Aplicar políticas RLS a particiones de analytics
 * Esta función crea políticas específicas para cada partición mensual
 */
CREATE OR REPLACE FUNCTION apply_analytics_partition_policies()
RETURNS VOID AS $$
DECLARE
  partition_table TEXT;
  partition_tables CURSOR FOR
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'app' AND tablename LIKE 'analytics_y%m%';
  policy_exists BOOLEAN;
BEGIN
  OPEN partition_tables;
  LOOP
    FETCH partition_tables INTO partition_table;
    EXIT WHEN NOT FOUND;

    BEGIN
      -- Verificar si la política de selección ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'app' AND tablename = partition_table
        AND policyname = 'analytics_partition_select_policy'
      ) INTO policy_exists;

      -- Política de selección
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_select_policy ON app.%I
           FOR SELECT USING (
             user_id IN (SELECT id FROM app.users WHERE auth.uid() = auth_id) OR
             is_admin((SELECT id FROM app.users WHERE auth.uid() = auth_id)) OR
             has_permission((SELECT id FROM app.users WHERE auth.uid() = auth_id), ''view_analytics'')
           )',
          partition_table
        );
      END IF;

      -- Verificar si la política de inserción ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'app' AND tablename = partition_table
        AND policyname = 'analytics_partition_insert_policy'
      ) INTO policy_exists;

      -- Política de inserción
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_insert_policy ON app.%I
           FOR INSERT WITH CHECK (
             user_id IN (SELECT id FROM app.users) -- Permitir inserción para usuarios reales
           )',
          partition_table
        );
      END IF;

      RAISE NOTICE 'Creadas políticas RLS para partición analytics: %', partition_table;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando políticas RLS en partición analytics %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  CLOSE partition_tables;
END;
$$ LANGUAGE plpgsql;

SELECT apply_analytics_partition_policies();