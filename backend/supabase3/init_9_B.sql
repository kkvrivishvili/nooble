-- ==============================================
-- ARCHIVO: init_9.sql - Vistas, Optimizaciones y Documentación
-- ==============================================
-- Propósito: Crear vistas y optimizaciones para operaciones frecuentes y documentar la base de datos.
--
-- Las vistas proporcionan abstracciones útiles sobre las tablas subyacentes, 
-- facilitando consultas complejas y análisis de datos. Este archivo también añade 
-- comentarios descriptivos a tablas y columnas para mejorar la documentación,
-- además de implementar optimizaciones de rendimiento críticas como índices
-- adicionales, particionamiento y vistas materializadas.
--
-- Todas las vistas implementan SECURITY INVOKER por seguridad, lo que significa
-- que los permisos serán evaluados según el usuario que ejecuta la consulta,
-- no el usuario que creó la vista.
-- ==============================================

-- ---------- SECCIÓN 0: LIMPIEZA Y CONFIGURACIÓN INICIAL ----------

-- Eliminar vistas existentes para recrearlas desde cero
DROP VIEW IF EXISTS daily_user_activity CASCADE;
DROP VIEW IF EXISTS users_with_roles CASCADE;
DROP VIEW IF EXISTS bot_performance CASCADE;
DROP VIEW IF EXISTS document_usage CASCADE;
DROP VIEW IF EXISTS admin_users CASCADE;
DROP VIEW IF EXISTS user_config_view CASCADE;
DROP VIEW IF EXISTS plan_config_view CASCADE;
DROP VIEW IF EXISTS active_subscriptions CASCADE;
DROP VIEW IF EXISTS public_bots CASCADE;
DROP VIEW IF EXISTS user_activity_summary CASCADE;
DROP VIEW IF EXISTS vector_search_metrics CASCADE;
DROP VIEW IF EXISTS bot_quality_metrics CASCADE;
DROP VIEW IF EXISTS document_processing_status CASCADE;

-- Eliminar vistas materializadas si existen
DROP MATERIALIZED VIEW IF EXISTS bot_performance_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS user_activity_summary_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public_bots_mat CASCADE;

-- También eliminar vistas de compatibilidad si existen
DROP VIEW IF EXISTS users CASCADE;
DROP VIEW IF EXISTS user_config CASCADE;
DROP VIEW IF EXISTS subscription_plan_config CASCADE;
DROP VIEW IF EXISTS subscriptions CASCADE;
DROP VIEW IF EXISTS user_role_history CASCADE;
DROP VIEW IF EXISTS subscription_history CASCADE;
DROP VIEW IF EXISTS analytics CASCADE;
DROP VIEW IF EXISTS system_errors CASCADE;
DROP VIEW IF EXISTS usage_metrics CASCADE;
DROP VIEW IF EXISTS quota_notifications CASCADE;

-- ---------- SECCIÓN 1: ÍNDICES ADICIONALES PARA OPTIMIZACIÓN ----------

-- Índice para metadatos de vector_analytics (mejora búsquedas en vectores)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_vector_analytics_metadata_jsonb_path' 
    AND schemaname = 'app'
  ) THEN
    CREATE INDEX idx_vector_analytics_metadata_jsonb_path 
    ON app.vector_analytics USING GIN (metadata jsonb_path_ops);
    RAISE NOTICE 'Creado índice para búsquedas eficientes en metadatos de vector_analytics';
  END IF;
END $$;

-- Índice para filtrado por fecha en mensajes (optimiza vistas de actividad)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_messages_created_at' 
    AND schemaname = 'public'
  ) THEN
    CREATE INDEX idx_messages_created_at 
    ON public.messages (created_at);
    RAISE NOTICE 'Creado índice para filtrado por fecha en messages';
  END IF;
END $$;

-- Índice para mejorar consultas por latencia en messages (optimiza análisis de bots)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_messages_latency_ms' 
    AND schemaname = 'public'
  ) THEN
    CREATE INDEX idx_messages_latency_ms 
    ON public.messages (latency_ms) 
    WHERE latency_ms IS NOT NULL;
    RAISE NOTICE 'Creado índice para consultas de latencia en messages';
  END IF;
END $$;

-- Índice para búsquedas de bots por user_id (optimiza múltiples vistas)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_bots_user_id_deleted_at' 
    AND schemaname = 'public'
  ) THEN
    CREATE INDEX idx_bots_user_id_deleted_at 
    ON public.bots (user_id) 
    WHERE deleted_at IS NULL;
    RAISE NOTICE 'Creado índice para consulta de bots por usuario (no eliminados)';
  END IF;
END $$;

-- Índice para búsquedas por conversation_id y is_user (muy usado en vistas)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes 
    WHERE indexname = 'idx_messages_conversation_id_is_user' 
    AND schemaname = 'public'
  ) THEN
    CREATE INDEX idx_messages_conversation_id_is_user 
    ON public.messages (conversation_id, is_user);
    RAISE NOTICE 'Creado índice para consultas de mensajes por conversación y tipo';
  END IF;
END $$;

-- ---------- SECCIÓN 2: VISTAS DE ANÁLISIS DE ACTIVIDAD ----------

-- Vista para análisis de interacción de usuarios por día
CREATE OR REPLACE VIEW daily_user_activity 
WITH (security_invoker=true) 
AS SELECT 
  c.user_id,
  DATE(m.created_at) AS activity_date,
  COUNT(DISTINCT m.conversation_id) AS conversation_count,
  COUNT(*) AS message_count,
  SUM(CASE WHEN m.is_user = TRUE THEN 1 ELSE 0 END) AS user_messages,
  SUM(CASE WHEN m.is_user = FALSE THEN 1 ELSE 0 END) AS bot_messages,
  AVG(m.latency_ms) AS avg_response_latency,
  MAX(m.created_at) AS last_activity
FROM public.messages m
JOIN public.conversations c ON m.conversation_id = c.id AND c.deleted_at IS NULL
-- Limitamos a mensajes de los últimos 90 días para mejor rendimiento
WHERE m.created_at > NOW() - INTERVAL '90 days'
GROUP BY c.user_id, DATE(m.created_at)
ORDER BY DATE(m.created_at) DESC, c.user_id;

COMMENT ON VIEW daily_user_activity IS 'Análisis diario de actividad de usuarios en conversaciones y mensajes (últimos 90 días)';

-- Vista para usuarios con roles
CREATE OR REPLACE VIEW users_with_roles 
WITH (security_invoker=true) 
AS SELECT 
  u.id,
  u.username,
  u.email,
  u.display_name,
  u.avatar_url,
  u.last_login_at,
  ur.role,
  ur.permissions,
  COALESCE(ur.role, 'user') AS effective_role,
  jsonb_build_object(
    'role', COALESCE(ur.role, 'user'),
    'permissions', ur.permissions,
    'role_assigned_at', ur.created_at
  ) AS role_metadata,
  p.view_count AS profile_views,
  p.meta_title,
  p.meta_description,
  p.custom_domain,
  p.is_verified
FROM 
  app.users u
LEFT JOIN 
  app.user_roles ur ON u.id = ur.user_id
LEFT JOIN
  public.profiles p ON u.id = p.id
WHERE
  u.deleted_at IS NULL;

COMMENT ON VIEW users_with_roles IS 'Vista consolidada de usuarios con sus roles, permisos y metadatos de perfil';

-- ---------- SECCIÓN 3: VISTAS PARA ANÁLISIS DE BOTS Y DOCUMENTOS ----------

-- Vista para análisis de rendimiento de bots
CREATE OR REPLACE VIEW bot_performance 
WITH (security_invoker=true) 
AS WITH feedback_stats AS (
  SELECT 
    c.bot_id,
    AVG(f.rating) AS avg_rating,
    COUNT(DISTINCT f.id) AS feedback_count,
    SUM(CASE WHEN f.rating = 1 THEN 1 ELSE 0 END) AS star1_count,
    SUM(CASE WHEN f.rating = 2 THEN 1 ELSE 0 END) AS star2_count,
    SUM(CASE WHEN f.rating = 3 THEN 1 ELSE 0 END) AS star3_count,
    SUM(CASE WHEN f.rating = 4 THEN 1 ELSE 0 END) AS star4_count,
    SUM(CASE WHEN f.rating = 5 THEN 1 ELSE 0 END) AS star5_count
  FROM public.conversations c
  JOIN public.messages m ON c.id = m.conversation_id AND m.is_user = FALSE
  JOIN app.bot_response_feedback f ON m.id = f.message_id
  WHERE c.deleted_at IS NULL
  GROUP BY c.bot_id
)
SELECT 
  b.id AS bot_id,
  b.name AS bot_name,
  b.user_id AS owner_id,
  u.username AS owner_username,
  b.is_public,
  b.category,
  b.popularity_score,
  COUNT(DISTINCT c.id) AS conversation_count,
  COUNT(m.id) AS message_count,
  COALESCE(fs.avg_rating, 0) AS avg_rating,
  COALESCE(fs.feedback_count, 0) AS feedback_count,
  COUNT(DISTINCT v.id) AS vector_search_count,
  AVG(m.latency_ms) AS avg_response_latency_ms,
  MAX(m.created_at) AS last_activity,
  jsonb_build_object(
    'rating_stats', jsonb_build_object(
      '1_star', COALESCE(fs.star1_count, 0),
      '2_star', COALESCE(fs.star2_count, 0),
      '3_star', COALESCE(fs.star3_count, 0),
      '4_star', COALESCE(fs.star4_count, 0),
      '5_star', COALESCE(fs.star5_count, 0)
    ),
    'collection_count', (
      SELECT COUNT(*) FROM app.bot_collections 
      WHERE bot_id = b.id
    )
  ) AS extended_stats
FROM public.bots b
JOIN app.users u ON b.user_id = u.id
LEFT JOIN public.conversations c ON b.id = c.bot_id AND c.deleted_at IS NULL
LEFT JOIN public.messages m ON c.id = m.conversation_id AND m.is_user = FALSE
LEFT JOIN feedback_stats fs ON b.id = fs.bot_id
LEFT JOIN app.vector_analytics v ON b.id = v.bot_id
WHERE b.deleted_at IS NULL AND u.deleted_at IS NULL
GROUP BY 
  b.id, b.name, b.user_id, u.username, 
  b.is_public, b.category, b.popularity_score,
  fs.avg_rating, fs.feedback_count, 
  fs.star1_count, fs.star2_count, fs.star3_count, fs.star4_count, fs.star5_count;

COMMENT ON VIEW bot_performance IS 'Métricas de rendimiento para bots con estadísticas detalladas de uso y feedback';

-- Vista materializada de bot_performance para mejor rendimiento en paneles administrativos
CREATE MATERIALIZED VIEW bot_performance_mat
WITH (security_invoker=true) 
AS SELECT *, NOW() AS last_refresh
FROM bot_performance;

-- Crear índices para la vista materializada
CREATE UNIQUE INDEX idx_bot_performance_mat_id ON bot_performance_mat(bot_id);
CREATE INDEX idx_bot_performance_mat_owner ON bot_performance_mat(owner_id);
CREATE INDEX idx_bot_performance_mat_popularity ON bot_performance_mat(popularity_score DESC);

COMMENT ON MATERIALIZED VIEW bot_performance_mat IS 'Vista materializada de métricas de rendimiento para bots con actualización programada';

-- Vista para análisis de uso de documentos
CREATE OR REPLACE VIEW document_usage 
WITH (security_invoker=true) 
AS WITH recent_hits AS (
  SELECT 
    dch2.document_id,
    COUNT(DISTINCT va.id) AS hit_count
  FROM app.vector_analytics va
  JOIN (
    SELECT va2.id, jsonb_array_elements_text(va2.metadata->'matched_chunks') AS chunk_id
    FROM app.vector_analytics va2
    WHERE va2.created_at > NOW() - INTERVAL '30 days'
  ) vac ON va.id = vac.id
  JOIN app.document_chunks dch2 ON vac.chunk_id::UUID = dch2.id
  GROUP BY dch2.document_id
)
SELECT 
  d.id AS document_id,
  d.title AS document_title,
  d.content_hash,
  d.file_type,
  d.file_size,
  d.processing_status,
  dc.id AS collection_id,
  dc.name AS collection_name,
  dc.user_id AS owner_id,
  u.username AS owner_username,
  COUNT(DISTINCT dch.id) AS chunk_count,
  COUNT(DISTINCT va.id) AS search_hits,
  MAX(va.created_at) AS last_search_hit,
  AVG(dch.relevance_score) AS avg_chunk_relevance,
  COALESCE(rh.hit_count, 0) AS recent_hits
FROM app.documents d
JOIN app.document_collections dc ON d.collection_id = dc.id
JOIN app.users u ON dc.user_id = u.id
LEFT JOIN app.document_chunks dch ON d.id = dch.document_id
LEFT JOIN LATERAL (
  SELECT va.id, va.created_at
  FROM app.vector_analytics va
  WHERE 
    va.metadata->'matched_chunks' ? dch.id::TEXT
    OR va.metadata->'result_docs' ? d.id::TEXT
  LIMIT 1
) va ON TRUE
LEFT JOIN recent_hits rh ON d.id = rh.document_id
WHERE d.deleted_at IS NULL AND dc.deleted_at IS NULL
GROUP BY d.id, d.title, d.content_hash, d.file_type, d.file_size, d.processing_status, 
         dc.id, dc.name, dc.user_id, u.username, rh.hit_count;

COMMENT ON VIEW document_usage IS 'Estadísticas detalladas sobre el uso de documentos en búsquedas vectoriales';

-- ---------- SECCIÓN 4: VISTAS PARA ADMINISTRACIÓN Y CONFIGURACIÓN ----------

-- Vista para roles de administrador
CREATE OR REPLACE VIEW admin_users 
WITH (security_invoker=true) 
AS SELECT 
  u.id,
  u.username,
  u.email,
  u.display_name,
  ur.role,
  ur.permissions,
  ur.granted_by,
  u2.username AS granted_by_username,
  ur.notes,
  ur.created_at AS role_assigned_at,
  u.last_login_at
FROM 
  app.users u
JOIN 
  app.user_roles ur ON u.id = ur.user_id
LEFT JOIN
  app.users u2 ON ur.granted_by = u2.id
WHERE 
  ur.role = 'admin' AND u.deleted_at IS NULL
ORDER BY u.username;

COMMENT ON VIEW admin_users IS 'Lista de usuarios con permisos de administrador para gestión del sistema';

-- Vista para configuración de usuarios
CREATE OR REPLACE VIEW user_config_view 
WITH (security_invoker=true) 
AS SELECT 
  u.id AS user_id,
  u.username,
  u.email,
  COALESCE(s.plan_type, 'free') AS plan_type,
  s.status AS subscription_status,
  sc.key AS config_key,
  sc.description,
  sc.scope,
  sc.data_type,
  COALESCE(uc.value, 
           spc.value, 
           sc.value) AS effective_value,
  CASE
    WHEN uc.id IS NOT NULL THEN 'user_specific'
    WHEN spc.id IS NOT NULL THEN 'subscription_plan'
    ELSE 'global_default'
  END AS config_source,
  uc.override_reason,
  u2.username AS override_by,
  uc.updated_at AS last_modified
FROM 
  app.users u
CROSS JOIN 
  app.system_config sc
LEFT JOIN 
  app.subscriptions s ON u.id = s.user_id AND s.status = 'active'
LEFT JOIN 
  app.subscription_plan_config spc ON COALESCE(s.plan_type, 'free') = spc.plan_type AND sc.key = spc.config_key
LEFT JOIN 
  app.user_config uc ON u.id = uc.user_id AND sc.key = uc.config_key
LEFT JOIN
  app.users u2 ON uc.created_by = u2.id
WHERE 
  u.deleted_at IS NULL AND
  (sc.scope = 'user' OR sc.scope = 'subscription');

COMMENT ON VIEW user_config_view IS 'Vista consolidada de configuración efectiva por usuario, incluyendo origen de valores';

-- Vista para administración de configuraciones por plan
CREATE OR REPLACE VIEW plan_config_view 
WITH (security_invoker=true) 
AS WITH plan_types AS (
  SELECT unnest(ARRAY['free', 'basic', 'premium', 'enterprise']) AS plan_type
)
SELECT 
  p.plan_type,
  sc.key AS config_key,
  sc.description,
  sc.data_type,
  COALESCE(spc.value, sc.value) AS value,
  sc.min_value,
  sc.max_value,
  CASE WHEN spc.id IS NOT NULL THEN TRUE ELSE FALSE END AS is_customized,
  spc.updated_at AS last_modified
FROM 
  plan_types p
CROSS JOIN 
  app.system_config sc
LEFT JOIN 
  app.subscription_plan_config spc ON p.plan_type = spc.plan_type AND sc.key = spc.config_key
WHERE 
  sc.scope = 'subscription'
ORDER BY 
  CASE p.plan_type 
    WHEN 'free' THEN 1 
    WHEN 'basic' THEN 2 
    WHEN 'premium' THEN 3 
    WHEN 'enterprise' THEN 4 
  END, 
  sc.key;

COMMENT ON VIEW plan_config_view IS 'Vista para administración de configuraciones por tipo de plan de suscripción';

-- Vista para subscripciones activas
CREATE OR REPLACE VIEW active_subscriptions 
WITH (security_invoker=true) 
AS SELECT
  s.id AS subscription_id,
  s.user_id,
  u.username,
  u.email,
  s.plan_type,
  s.status,
  s.current_period_start,
  s.current_period_end,
  s.payment_provider,
  s.payment_reference,
  s.recurring_amount,
  s.currency,
  s.auto_renew,
  s.discount_code,
  s.discount_percent,
  (s.current_period_end < NOW() + INTERVAL '7 days' AND s.auto_renew = FALSE) AS expiring_soon,
  (s.current_period_end < NOW()) AS expired,
  (
    SELECT COUNT(*) FROM app.subscription_history sh
    WHERE sh.subscription_id = s.id
  ) AS change_count
FROM
  app.subscriptions s
JOIN
  app.users u ON s.user_id = u.id
WHERE
  s.status IN ('active', 'trial') AND
  u.deleted_at IS NULL
ORDER BY
  expiring_soon DESC, s.current_period_end ASC;

COMMENT ON VIEW active_subscriptions IS 'Vista de suscripciones activas con detalles para gestión y alertas de vencimiento';

-- ---------- SECCIÓN 5: VISTAS PÚBLICAS Y DE COMUNIDAD ----------

-- Eliminando explícitamente la vista public_bots antes de recrearla
DROP VIEW IF EXISTS public_bots CASCADE;

-- Vista para bots públicos (comunidad)
CREATE VIEW public_bots
WITH (security_invoker=true)
AS WITH bot_stats AS (
  SELECT 
    c.bot_id,
    COUNT(DISTINCT c.id) AS conversation_count,
    MAX(c.last_activity_at) AS last_activity_at
  FROM public.conversations c
  WHERE c.deleted_at IS NULL
  GROUP BY c.bot_id
),
feedback_stats AS (
  SELECT
    c.bot_id,
    AVG(f.rating) AS avg_rating,
    COUNT(DISTINCT f.id) AS feedback_count
  FROM public.conversations c
  JOIN public.messages m ON c.id = m.conversation_id
  JOIN app.bot_response_feedback f ON m.id = f.message_id
  WHERE c.deleted_at IS NULL
  GROUP BY c.bot_id
)
SELECT
  b.id AS bot_id,
  b.name,
  b.description,
  b.avatar_url,
  b.category,
  b.tags,
  b.popularity_score,
  b.user_id AS creator_id,
  u.username AS creator_username,
  p.is_verified AS creator_verified,
  COUNT(DISTINCT bc.collection_id) AS collection_count,
  COALESCE(bs.conversation_count, 0) AS conversation_count,
  COUNT(DISTINCT l.id) AS link_count,
  COALESCE(fs.avg_rating, 0) AS avg_rating,
  COALESCE(fs.feedback_count, 0) AS feedback_count,
  b.created_at,
  GREATEST(b.updated_at, COALESCE(bs.last_activity_at, '2000-01-01')) AS last_activity_at
FROM
  public.bots b
JOIN
  app.users u ON b.user_id = u.id
LEFT JOIN
  public.profiles p ON u.id = p.id
LEFT JOIN
  app.bot_collections bc ON b.id = bc.bot_id
LEFT JOIN
  bot_stats bs ON b.id = bs.bot_id
LEFT JOIN
  feedback_stats fs ON b.id = fs.bot_id
LEFT JOIN
  public.links l ON b.id = l.bot_id
WHERE
  b.is_public = TRUE AND
  b.deleted_at IS NULL AND
  u.deleted_at IS NULL
GROUP BY
  b.id, b.name, b.description, b.avatar_url, b.category, b.tags,
  b.popularity_score, b.user_id, u.username, p.is_verified,
  bs.conversation_count, bs.last_activity_at, fs.avg_rating, fs.feedback_count,
  b.created_at, b.updated_at
ORDER BY
  b.popularity_score DESC, fs.feedback_count DESC NULLS LAST;

COMMENT ON VIEW public_bots IS 'Bots públicos disponibles para la comunidad con estadísticas relevantes';

-- Vista materializada de public_bots para mejor rendimiento en frontend
CREATE MATERIALIZED VIEW public_bots_mat
WITH (security_invoker=true)
AS SELECT *, NOW() AS last_refresh
FROM public_bots;

-- Crear índices para la vista materializada
CREATE UNIQUE INDEX idx_public_bots_mat_id ON public_bots_mat(bot_id);
CREATE INDEX idx_public_bots_mat_category ON public_bots_mat(category);
CREATE INDEX idx_public_bots_mat_popularity ON public_bots_mat(popularity_score DESC);
CREATE INDEX idx_public_bots_mat_creator ON public_bots_mat(creator_id);

COMMENT ON MATERIALIZED VIEW public_bots_mat IS 'Vista materializada de bots públicos para la comunidad con actualización programada';

-- Verificación de security_invoker para public_bots
DO $$
DECLARE
  security_type TEXT;
BEGIN
  SELECT CASE 
           WHEN securitypolicy THEN 'SECURITY DEFINER' 
           ELSE 'SECURITY INVOKER' 
         END 
  INTO security_type
  FROM pg_views 
  WHERE schemaname = 'public' AND viewname = 'public_bots';
  
  IF security_type = 'SECURITY DEFINER' THEN
    RAISE WARNING 'La vista public_bots está configurada como SECURITY DEFINER. Corrigiendo...';
    
    ALTER VIEW public_bots SET (security_invoker=true);
    
    -- Verificar de nuevo para confirmar la corrección
    SELECT CASE 
             WHEN securitypolicy THEN 'SECURITY DEFINER' 
             ELSE 'SECURITY INVOKER' 
           END 
    INTO security_type
    FROM pg_views 
    WHERE schemaname = 'public' AND viewname = 'public_bots';
    
    IF security_type = 'SECURITY DEFINER' THEN
      RAISE WARNING 'No se pudo corregir la vista public_bots a SECURITY INVOKER. Se requiere intervención manual.';
    ELSE
      RAISE NOTICE 'La vista public_bots ha sido corregida a SECURITY INVOKER correctamente.';
    END IF;
  ELSE
    RAISE NOTICE 'La vista public_bots está configurada correctamente como SECURITY INVOKER.';
  END IF;
END $$;

-- ---------- SECCIÓN 6: VISTAS PARA ANÁLISIS AVANZADO ----------
  
-- Vista para resumen de actividad de usuarios
CREATE OR REPLACE VIEW user_activity_summary 
WITH (security_invoker=true) 
AS WITH user_message_counts AS (
  SELECT 
    c.user_id,
    COUNT(CASE WHEN m.is_user = TRUE THEN 1 END) AS user_messages,
    COUNT(CASE WHEN m.is_user = FALSE THEN 1 END) AS bot_messages
  FROM public.conversations c
  JOIN public.messages m ON c.id = m.conversation_id
  WHERE c.deleted_at IS NULL
  GROUP BY c.user_id
),
search_counts AS (
  SELECT 
    user_id, 
    COUNT(*) AS search_count
  FROM app.vector_analytics
  WHERE created_at > NOW() - INTERVAL '90 days'
  GROUP BY user_id
)
SELECT
  u.id AS user_id,
  u.username,
  u.email,
  u.display_name,
  u.last_login_at,
  COALESCE(s.plan_type, 'free') AS plan_type,
  COALESCE(s.status, 'none') AS subscription_status,
  COUNT(DISTINCT b.id) AS bot_count,
  COUNT(DISTINCT dc.id) AS collection_count,
  COUNT(DISTINCT d.id) AS document_count,
  COUNT(DISTINCT c.id) AS conversation_count,
  COUNT(DISTINCT l.id) AS link_count,
  COALESCE(p.view_count, 0) AS profile_view_count,
  SUM(COALESCE(l.click_count, 0)) AS total_link_clicks,
  COALESCE(umc.user_messages, 0) AS total_user_messages,
  COALESCE(umc.bot_messages, 0) AS total_bot_messages,
  COALESCE(sc.search_count, 0) AS total_vector_searches,
  u.created_at AS user_since,
  GREATEST(
    u.updated_at,
    MAX(COALESCE(b.updated_at, '2000-01-01')),
    MAX(COALESCE(c.updated_at, '2000-01-01')),
    MAX(COALESCE(l.updated_at, '2000-01-01'))
  ) AS last_activity
FROM
  app.users u
LEFT JOIN
  app.subscriptions s ON u.id = s.user_id AND s.status = 'active'
LEFT JOIN
  public.profiles p ON u.id = p.id
LEFT JOIN
  public.bots b ON u.id = b.user_id AND b.deleted_at IS NULL
LEFT JOIN
  app.document_collections dc ON u.id = dc.user_id AND dc.deleted_at IS NULL
LEFT JOIN
  app.documents d ON dc.id = d.collection_id AND d.deleted_at IS NULL
LEFT JOIN
  public.conversations c ON u.id = c.user_id AND c.deleted_at IS NULL
LEFT JOIN
  public.links l ON u.id = l.user_id
LEFT JOIN
  user_message_counts umc ON u.id = umc.user_id
LEFT JOIN
  search_counts sc ON u.id = sc.user_id
WHERE
  u.deleted_at IS NULL
GROUP BY
  u.id, u.username, u.email, u.display_name, u.last_login_at,
  s.plan_type, s.status, p.view_count, umc.user_messages, umc.bot_messages,
  sc.search_count, u.created_at;

COMMENT ON VIEW user_activity_summary IS 'Resumen completo de actividad por usuario para análisis y reportes administrativos';

-- Vista materializada de user_activity_summary para mejor rendimiento en dashboards
CREATE MATERIALIZED VIEW user_activity_summary_mat
WITH (security_invoker=true) 
AS SELECT *, NOW() AS last_refresh
FROM user_activity_summary;

-- Crear índices para la vista materializada
CREATE UNIQUE INDEX idx_user_activity_summary_mat_id ON user_activity_summary_mat(user_id);
CREATE INDEX idx_user_activity_summary_mat_plan ON user_activity_summary_mat(plan_type);
CREATE INDEX idx_user_activity_summary_mat_last_login ON user_activity_summary_mat(last_login_at DESC);

COMMENT ON MATERIALIZED VIEW user_activity_summary_mat IS 'Vista materializada de resumen de actividad de usuarios con actualización programada';

-- Vista para métricas de búsqueda vectorial
CREATE OR REPLACE VIEW vector_search_metrics 
WITH (security_invoker=true) 
AS SELECT
  DATE(va.created_at) AS search_date,
  va.user_id,
  u.username,
  va.bot_id,
  b.name AS bot_name,
  COUNT(*) AS search_count,
  AVG(va.latency_ms) AS avg_latency_ms,
  MIN(va.latency_ms) AS min_latency_ms,
  MAX(va.latency_ms) AS max_latency_ms,
  AVG(va.result_count) AS avg_result_count,
  SUM(CASE WHEN va.successful = FALSE THEN 1 ELSE 0 END) AS error_count,
  jsonb_agg(DISTINCT va.search_strategy) FILTER (WHERE va.search_strategy IS NOT NULL) AS strategies_used
FROM
  app.vector_analytics va
LEFT JOIN
  app.users u ON va.user_id = u.id
LEFT JOIN
  public.bots b ON va.bot_id = b.id AND b.deleted_at IS NULL
WHERE
  va.created_at > NOW() - INTERVAL '30 days'
GROUP BY
  DATE(va.created_at), va.user_id, u.username, va.bot_id, b.name
ORDER BY
  search_date DESC, search_count DESC;

COMMENT ON VIEW vector_search_metrics IS 'Métricas detalladas de búsquedas vectoriales para análisis de rendimiento y uso (últimos 30 días)';

-- Vista para métricas de calidad de bots
CREATE OR REPLACE VIEW bot_quality_metrics 
WITH (security_invoker=true) 
AS WITH feedback_categories_agg AS (
  SELECT 
    category_counts.bot_id,
    jsonb_object_agg(category, count) AS categories_json
  FROM (
    SELECT 
      c.bot_id,
      unnest(f.feedback_categories) AS category,
      COUNT(*) AS count
    FROM public.conversations c
    JOIN public.messages m ON c.id = m.conversation_id
    JOIN app.bot_response_feedback f ON m.id = f.message_id
    WHERE c.deleted_at IS NULL
    GROUP BY c.bot_id, category
  ) AS category_counts
  GROUP BY category_counts.bot_id
),
search_results AS (
  SELECT 
    bot_id,
    AVG(result_count) AS avg_results
  FROM app.vector_analytics
  GROUP BY bot_id
)
SELECT
  b.id AS bot_id,
  b.name AS bot_name,
  b.user_id AS owner_id,
  u.username AS owner_username,
  COUNT(DISTINCT c.id) AS conversation_count,
  COUNT(DISTINCT m.id) FILTER (WHERE m.is_user = FALSE) AS bot_response_count,
  AVG(m.latency_ms) FILTER (WHERE m.is_user = FALSE) AS avg_response_time_ms,
  AVG(char_length(m.content)) FILTER (WHERE m.is_user = FALSE) AS avg_response_length,
  COALESCE(AVG(f.rating), 0) AS avg_rating,
  COUNT(f.id) AS total_ratings,
  SUM(CASE WHEN f.rating >= 4 THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(f.id), 0) * 100 AS satisfaction_percentage,
  fca.categories_json AS feedback_categories,
  COALESCE(sr.avg_results, 0) AS avg_search_results,
  b.created_at,
  MAX(COALESCE(c.last_activity_at, b.updated_at)) AS last_activity
FROM
  public.bots b
JOIN
  app.users u ON b.user_id = u.id
LEFT JOIN
  public.conversations c ON b.id = c.bot_id AND c.deleted_at IS NULL
LEFT JOIN
  public.messages m ON c.id = m.conversation_id
LEFT JOIN
  app.bot_response_feedback f ON m.id = f.message_id
LEFT JOIN
  feedback_categories_agg fca ON b.id = fca.bot_id
LEFT JOIN
  search_results sr ON b.id = sr.bot_id
WHERE
  b.deleted_at IS NULL
  AND u.deleted_at IS NULL
GROUP BY
  b.id, b.name, b.user_id, u.username, b.created_at, fca.categories_json, sr.avg_results;

COMMENT ON VIEW bot_quality_metrics IS 'Métricas detalladas de calidad, rendimiento y satisfacción para bots';

-- Vista para estado de procesamiento de documentos
CREATE OR REPLACE VIEW document_processing_status 
WITH (security_invoker=true) 
AS SELECT
  d.id AS document_id,
  d.title,
  dc.id AS collection_id,
  dc.name AS collection_name,
  dc.user_id AS owner_id,
  u.username AS owner_username,
  d.processing_status,
  d.error_message,
  COUNT(dch.id) AS chunk_count,
  SUM(CASE WHEN dch.content_vector IS NULL THEN 1 ELSE 0 END) AS unprocessed_chunks,
  MIN(dch.created_at) AS oldest_chunk_date,
  MAX(dch.updated_at) AS newest_chunk_update,
  d.created_at AS document_created,
  d.updated_at AS document_updated,
  d.file_type,
  d.file_size,
  d.language
FROM
  app.documents d
JOIN
  app.document_collections dc ON d.collection_id = dc.id
JOIN
  app.users u ON dc.user_id = u.id
LEFT JOIN
  app.document_chunks dch ON d.id = dch.document_id
WHERE
  d.deleted_at IS NULL AND dc.deleted_at IS NULL
GROUP BY
  d.id, d.title, dc.id, dc.name, dc.user_id, u.username, 
  d.processing_status, d.error_message, d.created_at, d.updated_at,
  d.file_type, d.file_size, d.language
ORDER BY
  CASE d.processing_status
    WHEN 'error' THEN 1
    WHEN 'processing' THEN 2
    WHEN 'pending' THEN 3
    WHEN 'completed' THEN 4
    ELSE 5
  END,
  d.updated_at DESC;

COMMENT ON VIEW document_processing_status IS 'Vista de estado de procesamiento de documentos para monitoreo de pipeline de ingesta';

-- ---------- SECCIÓN 7: CREAR VISTAS DE COMPATIBILIDAD ----------

-- Crear vistas de compatibilidad para mantener código existente funcionando
-- NOTA: Estas vistas son temporales y se utilizan para mantener compatibilidad
-- con el código existente. El código debe actualizarse para usar los nombres
-- de esquema completos (app.users, app.user_config, etc.) tan pronto como sea posible.
-- Estas vistas se eliminarán en futuras actualizaciones.
CREATE OR REPLACE VIEW users AS 
  SELECT * FROM app.users;

CREATE OR REPLACE VIEW user_config AS 
  SELECT * FROM app.user_config;

CREATE OR REPLACE VIEW subscription_plan_config AS 
  SELECT * FROM app.subscription_plan_config;

CREATE OR REPLACE VIEW subscriptions AS 
  SELECT * FROM app.subscriptions;

CREATE OR REPLACE VIEW user_role_history AS 
  SELECT * FROM app.user_role_history;

CREATE OR REPLACE VIEW subscription_history AS 
  SELECT * FROM app.subscription_history;

CREATE OR REPLACE VIEW analytics AS 
  SELECT * FROM app.analytics;

CREATE OR REPLACE VIEW system_errors AS 
  SELECT * FROM app.system_errors;

CREATE OR REPLACE VIEW usage_metrics AS 
  SELECT * FROM app.usage_metrics;

CREATE OR REPLACE VIEW quota_notifications AS 
  SELECT * FROM app.quota_notifications;

-- ---------- SECCIÓN 8: VERIFICAR SECURITY INVOKER EN TODAS LAS VISTAS ----------

-- Verificar que todas las vistas tienen SECURITY INVOKER
DO $$
DECLARE
  definer_views TEXT[];
  view_name TEXT;
  view_schema TEXT;
BEGIN
  CREATE TEMP TABLE temp_views AS
  SELECT schemaname, viewname
  FROM pg_views
  WHERE schemaname IN ('public', 'app')
  AND securitypolicy = true; -- true = SECURITY DEFINER
  
  IF EXISTS (SELECT 1 FROM temp_views) THEN
    SELECT array_agg(schemaname || '.' || viewname) INTO definer_views FROM temp_views;
    
    RAISE WARNING 'Las siguientes vistas todavía tienen SECURITY DEFINER: %', definer_views;
    
    -- Intentar corregir automáticamente cada vista
    FOR view_schema, view_name IN SELECT schemaname, viewname FROM temp_views LOOP
      RAISE NOTICE 'Intentando corregir vista %.%...', view_schema, view_name;
      BEGIN
        EXECUTE format('ALTER VIEW %I.%I SET (security_invoker=true)', view_schema, view_name);
        RAISE NOTICE 'Vista %.% corregida exitosamente.', view_schema, view_name;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'No se pudo corregir automáticamente la vista %.%: %', view_schema, view_name, SQLERRM;
      END;
    END LOOP;
  ELSE
    RAISE NOTICE 'Todas las vistas están configuradas correctamente como SECURITY INVOKER.';
  END IF;
  
  DROP TABLE IF EXISTS temp_views;
END $$;

-- ---------- SECCIÓN 9: PARTICIONAMIENTO DE MENSAJES ----------

-- Función para crear particiones de mensajes automáticamente
-- Esta función se usará posteriormente cuando se particione la tabla messages
CREATE OR REPLACE FUNCTION create_message_partition()
RETURNS TRIGGER AS $$
DECLARE
  partition_date DATE;
  partition_name TEXT;
  start_date TEXT;
  end_date TEXT;
  next_month_date DATE;
  next_next_month_date DATE;
BEGIN
  -- Determinar el mes del dato a insertar
  partition_date := date_trunc('month', NEW.created_at)::DATE;
  partition_name := 'messages_y' || 
                      EXTRACT(YEAR FROM partition_date)::TEXT || 
                      'm' || 
                      LPAD(EXTRACT(MONTH FROM partition_date)::TEXT, 2, '0');
  start_date := partition_date::TEXT;
  end_date := (partition_date + INTERVAL '1 month')::TEXT;
  
  -- Verificar y crear partición para el mes actual
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'public'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.messages
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      -- Crear índices específicos para la partición
      EXECUTE format(
        'CREATE INDEX %I ON public.%I (conversation_id, is_user)',
        partition_name || '_conv_idx', 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON public.%I (created_at)',
        partition_name || '_date_idx', 
        partition_name
      );
      
      RAISE NOTICE 'Creada partición % para mensajes', partition_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  -- Crear particiones anticipadas para los próximos dos meses (proactivo)
  next_month_date := partition_date + INTERVAL '1 month';
  next_next_month_date := partition_date + INTERVAL '2 month';
  
  -- Próximo mes
  partition_name := 'messages_y' || 
                    EXTRACT(YEAR FROM next_month_date)::TEXT || 
                    'm' || 
                    LPAD(EXTRACT(MONTH FROM next_month_date)::TEXT, 2, '0');
  start_date := next_month_date::TEXT;
  end_date := (next_month_date + INTERVAL '1 month')::TEXT;
  
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'public'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.messages
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      RAISE NOTICE 'Creada partición anticipada % para mensajes', partition_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición anticipada %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  -- Siguiente mes
  partition_name := 'messages_y' || 
                    EXTRACT(YEAR FROM next_next_month_date)::TEXT || 
                    'm' || 
                    LPAD(EXTRACT(MONTH FROM next_next_month_date)::TEXT, 2, '0');
  start_date := next_next_month_date::TEXT;
  end_date := (next_next_month_date + INTERVAL '1 month')::TEXT;
  
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'public'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.messages
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      RAISE NOTICE 'Creada partición anticipada % para mensajes', partition_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición anticipada %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION create_message_partition() IS 'Función para crear particiones automáticamente para la tabla messages';

-- Advertencia sobre particionamiento de tabla messages existente
DO $$
DECLARE
  messages_exists BOOLEAN;
  messages_is_partitioned BOOLEAN;
BEGIN
  -- Verificar si messages existe y si ya está particionada
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables 
    WHERE table_schema = 'public' AND table_name = 'messages'
  ) INTO messages_exists;
  
  IF messages_exists THEN
    SELECT EXISTS (
      SELECT 1 FROM pg_partitioned_table pt
      JOIN pg_class c ON pt.partrelid = c.oid
      JOIN pg_namespace n ON c.relnamespace = n.oid
      WHERE n.nspname = 'public' AND c.relname = 'messages'
    ) INTO messages_is_partitioned;
  END IF;
  
  -- Si la tabla existe pero no está particionada, mostrar advertencia
  IF messages_exists AND NOT messages_is_partitioned THEN
    RAISE WARNING '
    =====================================================================
    ADVERTENCIA: Para implementar particionamiento en tabla public.messages 
    existente, seguir estos pasos en un script de migración separado:
    
    1. Crear tabla messages_new particionada por rango en created_at
    2. Migrar datos de messages a messages_new
    3. Eliminar tabla messages original
    4. Renombrar messages_new a messages
    5. Recrear índices, triggers y constraints
    
    El particionamiento mejora significativamente el rendimiento en
    tablas con gran volumen de datos. Para habilitar esta funcionalidad
    en una base de datos nueva, compruebe que messages no exista y luego
    ejecute el script migration_partition_messages.sql incluido.
    =====================================================================';
  END IF;
END $$;

-- ---------- SECCIÓN 10: FUNCIONES DE MANTENIMIENTO AUTOMÁTICO ----------

-- Función para refrescar las vistas materializadas de forma concurrente
CREATE OR REPLACE FUNCTION refresh_materialized_views(parallel BOOLEAN DEFAULT true)
RETURNS VOID AS $$
DECLARE
  view_name TEXT;
  refresh_cmd TEXT;
BEGIN
  RAISE NOTICE 'Iniciando actualización de vistas materializadas...';
  
  -- Definir vistas para refrescar
  FOR view_name IN 
    SELECT matviewname FROM pg_matviews 
    WHERE schemaname = 'public'
    AND matviewname IN ('bot_performance_mat', 'user_activity_summary_mat', 'public_bots_mat')
  LOOP
    BEGIN
      IF parallel THEN
        refresh_cmd := 'REFRESH MATERIALIZED VIEW CONCURRENTLY ' || quote_ident(view_name);
      ELSE
        refresh_cmd := 'REFRESH MATERIALIZED VIEW ' || quote_ident(view_name);
      END IF;
      
      EXECUTE refresh_cmd;
      RAISE NOTICE 'Actualizada vista materializada %', view_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error al actualizar vista materializada %: %', view_name, SQLERRM;
    END;
  END LOOP;
  
  RAISE NOTICE 'Actualización de vistas materializadas completada';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION refresh_materialized_views(BOOLEAN) IS 'Función para actualizar vistas materializadas. Usar en tareas programadas.';

-- Función para eliminar particiones antiguas de analytics y messages
CREATE OR REPLACE FUNCTION cleanup_old_partitions(months_to_keep INTEGER DEFAULT 12)
RETURNS VOID AS $$
DECLARE
  partition_table TEXT;
  cutoff_date DATE := (NOW() - (months_to_keep || ' MONTHS')::INTERVAL)::DATE;
  year_month TEXT;
  extract_year INTEGER;
  extract_month INTEGER;
  partition_date DATE;
BEGIN
  RAISE NOTICE 'Iniciando limpieza de particiones antiguas (conservando % meses)...', months_to_keep;
  
  -- Buscar particiones de analytics
  FOR partition_table IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'app' AND tablename LIKE 'analytics_y%m%'
  LOOP
    BEGIN
      -- Extraer año y mes de nombre de partición (analytics_y2023m01)
      year_month := substring(partition_table FROM 'y([0-9]+)m([0-9]+)');
      extract_year := substring(year_month FROM '([0-9]+)m')::INTEGER;
      extract_month := substring(year_month FROM 'm([0-9]+)')::INTEGER;
      
      -- Construir fecha
      partition_date := make_date(extract_year, extract_month, 1);
      
      -- Comparar con fecha límite
      IF partition_date < cutoff_date THEN
        EXECUTE 'DROP TABLE app.' || quote_ident(partition_table);
        RAISE NOTICE 'Eliminada partición %', partition_table;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error procesando partición %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  
  -- Buscar particiones de messages
  FOR partition_table IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND tablename LIKE 'messages_y%m%'
  LOOP
    BEGIN
      -- Extraer año y mes de nombre de partición (messages_y2023m01)
      year_month := substring(partition_table FROM 'y([0-9]+)m([0-9]+)');
      extract_year := substring(year_month FROM '([0-9]+)m')::INTEGER;
      extract_month := substring(year_month FROM 'm([0-9]+)')::INTEGER;
      
      -- Construir fecha
      partition_date := make_date(extract_year, extract_month, 1);
      
      -- Comparar con fecha límite
      IF partition_date < cutoff_date THEN
        EXECUTE 'DROP TABLE public.' || quote_ident(partition_table);
        RAISE NOTICE 'Eliminada partición %', partition_table;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error procesando partición %: %', partition_table, SQLERRM;
    END;
  END LOOP;
  
  RAISE NOTICE 'Limpieza de particiones antiguas completada';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_old_partitions(INTEGER) IS 'Función para eliminar particiones antiguas según número de meses a conservar';

-- Función para detectar y reportar anomalías en métricas clave
CREATE OR REPLACE FUNCTION detect_system_anomalies()
RETURNS TABLE(metric TEXT, warning TEXT, severity TEXT) AS $$
BEGIN
  RETURN QUERY
  
  -- Verificar número de documentos con error de procesamiento
  SELECT 
    'documents_processing_error' AS metric,
    'Hay ' || COUNT(*) || ' documentos con errores de procesamiento' AS warning,
    CASE 
      WHEN COUNT(*) > 100 THEN 'critical'
      WHEN COUNT(*) > 50 THEN 'high'
      WHEN COUNT(*) > 10 THEN 'medium'
      ELSE 'low'
    END AS severity
  FROM 
    app.documents 
  WHERE 
    processing_status = 'error' AND 
    deleted_at IS NULL AND
    updated_at > NOW() - INTERVAL '7 days'
  HAVING COUNT(*) > 0
  
  UNION ALL
  
  -- Verificar conversaciones sin actividad reciente (posible bloqueo)
  SELECT 
    'stuck_conversations' AS metric,
    'Hay ' || COUNT(*) || ' conversaciones activas sin actividad reciente' AS warning,
    CASE 
      WHEN COUNT(*) > 50 THEN 'high'
      WHEN COUNT(*) > 20 THEN 'medium'
      ELSE 'low'
    END AS severity
  FROM 
    public.conversations c
  WHERE 
    c.deleted_at IS NULL AND
    EXISTS (
      SELECT 1 FROM public.messages m 
      WHERE m.conversation_id = c.id AND m.is_user = TRUE
      AND m.created_at > NOW() - INTERVAL '1 day'
    ) AND
    NOT EXISTS (
      SELECT 1 FROM public.messages m 
      WHERE m.conversation_id = c.id AND m.is_user = FALSE
      AND m.created_at > NOW() - INTERVAL '1 day'
    )
  HAVING COUNT(*) > 0
  
  UNION ALL
  
  -- Verificar alta tasa de búsquedas vectoriales fallidas
  SELECT 
    'vector_search_errors' AS metric,
    'La tasa de error de búsquedas vectoriales es ' || 
    ROUND((failed_count*100.0)/total_count, 1) || '%' AS warning,
    CASE 
      WHEN (failed_count*100.0)/total_count > 20 THEN 'critical'
      WHEN (failed_count*100.0)/total_count > 10 THEN 'high'
      WHEN (failed_count*100.0)/total_count > 5 THEN 'medium'
      ELSE 'low'
    END AS severity
  FROM (
    SELECT 
      COUNT(*) AS total_count,
      SUM(CASE WHEN successful = FALSE THEN 1 ELSE 0 END) AS failed_count
    FROM app.vector_analytics
    WHERE created_at > NOW() - INTERVAL '1 hour'
    HAVING COUNT(*) > 20
  ) AS search_stats
  WHERE (failed_count*100.0)/total_count > 3
  
  UNION ALL
  
  -- Verificar latencia anormal en las respuestas de bots
  SELECT 
    'high_response_latency' AS metric,
    'La latencia promedio de respuesta de bots es ' || 
    ROUND(AVG(latency_ms)::numeric, 0) || 'ms' AS warning,
    CASE 
      WHEN AVG(latency_ms) > 5000 THEN 'critical'
      WHEN AVG(latency_ms) > 3000 THEN 'high'
      WHEN AVG(latency_ms) > 1500 THEN 'medium'
      ELSE 'low'
    END AS severity
  FROM public.messages m
  JOIN public.conversations c ON m.conversation_id = c.id
  WHERE 
    m.is_user = FALSE AND 
    m.created_at > NOW() - INTERVAL '1 hour' AND
    c.deleted_at IS NULL
  GROUP BY EXTRACT(HOUR FROM m.created_at)
  HAVING AVG(latency_ms) > 1000;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION detect_system_anomalies() IS 'Función para detectar y reportar anomalías en el sistema';

-- ---------- SECCIÓN 11: COMENTARIOS DE DOCUMENTACIÓN ----------

-- Agregar comentarios para documentación de tablas principales
COMMENT ON TABLE app.document_chunks IS 'Fragmentos de documentos vectorizados para búsqueda semántica con LlamaIndex';
COMMENT ON TABLE public.links IS 'Enlaces que aparecen en el perfil de Linktree del usuario, pueden ser URLs o chatbots';
COMMENT ON TABLE public.link_groups IS 'Grupos para organizar enlaces en secciones';
COMMENT ON TABLE public.link_group_items IS 'Asociación entre enlaces y grupos';
COMMENT ON TABLE app.analytics IS 'Registro de interacciones con enlaces y perfiles para análisis';
COMMENT ON TABLE public.conversations IS 'Conversaciones entre usuarios y bots';
COMMENT ON TABLE public.messages IS 'Mensajes individuales dentro de conversaciones';
COMMENT ON TABLE app.bot_response_feedback IS 'Feedback de usuarios sobre respuestas de bots';
COMMENT ON TABLE app.vector_analytics IS 'Registro de consultas de búsqueda vectorial';
COMMENT ON TABLE app.system_config IS 'Configuración global del sistema con metadatos, tipos y restricciones';
COMMENT ON TABLE app.user_config IS 'Configuración específica por usuario que sobrescribe los valores por defecto';
COMMENT ON TABLE app.subscription_plan_config IS 'Configuración predeterminada para cada tipo de plan de suscripción';
COMMENT ON TABLE app.system_errors IS 'Registro de errores del sistema';
COMMENT ON TABLE app.usage_metrics IS 'Métricas de uso por usuario y tipo';
COMMENT ON TABLE app.quota_notifications IS 'Registro de notificaciones enviadas sobre límites de cuota';
COMMENT ON TABLE app.bot_collections IS 'Relación entre bots y colecciones de documentos utilizadas';

-- Comentarios para vistas
COMMENT ON VIEW daily_user_activity IS 'Análisis diario de actividad de usuarios en conversaciones';
COMMENT ON VIEW users_with_roles IS 'Vista con datos de usuario y sus roles correspondientes';
COMMENT ON VIEW bot_performance IS 'Métricas de rendimiento para bots por usuario';
COMMENT ON VIEW document_usage IS 'Estadísticas de uso de documentos en búsquedas vectoriales';
COMMENT ON VIEW admin_users IS 'Lista de usuarios con permisos de administrador';
COMMENT ON VIEW user_config_view IS 'Vista consolidada de configuración efectiva por usuario, incluyendo origen de valores';
COMMENT ON VIEW plan_config_view IS 'Vista para administración de configuraciones por tipo de plan';
COMMENT ON VIEW active_subscriptions IS 'Vista de suscripciones activas con detalles para gestión';
COMMENT ON VIEW public_bots IS 'Bots públicos disponibles para la comunidad con estadísticas';
COMMENT ON VIEW user_activity_summary IS 'Resumen de actividad por usuario para backoffice';
COMMENT ON VIEW vector_search_metrics IS 'Métricas detalladas de búsquedas vectoriales para análisis de rendimiento';
COMMENT ON VIEW bot_quality_metrics IS 'Métricas de calidad y satisfacción para bots';
COMMENT ON VIEW document_processing_status IS 'Estado de procesamiento de documentos para monitoreo';

-- Comentarios para vistas materializadas
COMMENT ON MATERIALIZED VIEW bot_performance_mat IS 'Vista materializada de métricas de rendimiento para bots con actualización programada';
COMMENT ON MATERIALIZED VIEW user_activity_summary_mat IS 'Vista materializada de resumen de actividad de usuarios con actualización programada';
COMMENT ON MATERIALIZED VIEW public_bots_mat IS 'Vista materializada de bots públicos para la comunidad con actualización programada';

-- Comentarios para vistas de compatibilidad
COMMENT ON VIEW users IS 'Vista de compatibilidad para app.users';
COMMENT ON VIEW user_config IS 'Vista de compatibilidad para app.user_config';
COMMENT ON VIEW subscription_plan_config IS 'Vista de compatibilidad para app.subscription_plan_config';
COMMENT ON VIEW subscriptions IS 'Vista de compatibilidad para app.subscriptions';
COMMENT ON VIEW user_role_history IS 'Vista de compatibilidad para app.user_role_history';
COMMENT ON VIEW subscription_history IS 'Vista de compatibilidad para app.subscription_history';
COMMENT ON VIEW analytics IS 'Vista de compatibilidad para app.analytics';
COMMENT ON VIEW system_errors IS 'Vista de compatibilidad para app.system_errors';
COMMENT ON VIEW usage_metrics IS 'Vista de compatibilidad para app.usage_metrics';
COMMENT ON VIEW quota_notifications IS 'Vista de compatibilidad para app.quota_notifications';

-- Comentarios para tablas de usuarios
COMMENT ON TABLE app.users IS 'Información principal de los usuarios de la plataforma';
COMMENT ON TABLE public.profiles IS 'Información extendida de perfiles de usuario para minipages tipo Linktree';
COMMENT ON TABLE app.user_roles IS 'Roles de usuario para gestión de permisos y acceso';
COMMENT ON TABLE app.user_role_history IS 'Historial de cambios en roles de usuario para auditoría';
COMMENT ON TABLE public.themes IS 'Temas visuales disponibles para personalizar los perfiles de Linktree';
COMMENT ON TABLE app.subscriptions IS 'Información de suscripciones y planes de usuarios';
COMMENT ON TABLE app.subscription_history IS 'Historial de cambios en suscripciones para auditoría';
COMMENT ON TABLE public.bots IS 'Bots personalizados creados por los usuarios para interactuar con su contenido';
COMMENT ON TABLE app.document_collections IS 'Colecciones de documentos que alimentan la base de conocimiento de los bots';
COMMENT ON TABLE app.documents IS 'Documentos individuales que contienen información para recuperación aumentada por generación (RAG)';

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE '================================================================';
  RAISE NOTICE 'Instalación completa del sistema con optimizaciones de rendimiento:';
  RAISE NOTICE '- Vistas analíticas y administrativas para operaciones frecuentes';
  RAISE NOTICE '- Vistas materializadas para consultas complejas y de alto rendimiento';
  RAISE NOTICE '- Índices adicionales para optimizar consultas frecuentes';
  RAISE NOTICE '- Funciones de mantenimiento para gestión automática del sistema';
  RAISE NOTICE '- Documentación completa de tablas y vistas';
  RAISE NOTICE '================================================================';
  RAISE NOTICE 'Versión de esquema: %', (SELECT value FROM app.system_config WHERE key = 'version');
  RAISE NOTICE 'Dimensión vectorial configurada: %', (SELECT get_vector_dimension());
  RAISE NOTICE '================================================================';
  RAISE NOTICE 'IMPORTANTE: Para mantener el rendimiento óptimo:';
  RAISE NOTICE '1. Programar refresh_materialized_views() cada 30-60 minutos';
  RAISE NOTICE '2. Programar cleanup_old_partitions() mensualmente';
  RAISE NOTICE '3. Monitorizar detect_system_anomalies() regularmente';
  RAISE NOTICE '================================================================';
END $$;