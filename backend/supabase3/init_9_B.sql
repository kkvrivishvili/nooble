-- ==============================================
-- ARCHIVO: init_9.sql - Vistas y Comentarios de BD
-- ==============================================
-- Propósito: Crear vistas para operaciones frecuentes y documentar la base de datos.
--
-- Las vistas proporcionan abstracciones útiles sobre las tablas subyacentes, 
-- facilitando consultas complejas y análisis de datos. Este archivo también añade 
-- comentarios descriptivos a tablas y columnas para mejorar la documentación
-- de la estructura de la base de datos.
--
-- Todas las vistas implementan SECURITY INVOKER por seguridad, lo que significa
-- que los permisos serán evaluados según el usuario que ejecuta la consulta,
-- no el usuario que creó la vista.
-- ==============================================

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

-- ---------- SECCIÓN 1: VISTAS DE ANÁLISIS DE ACTIVIDAD ----------

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
JOIN public.conversations c ON m.conversation_id = c.id
GROUP BY c.user_id, DATE(m.created_at)
ORDER BY DATE(m.created_at) DESC, c.user_id;

COMMENT ON VIEW daily_user_activity IS 'Análisis diario de actividad de usuarios en conversaciones y mensajes';

-- Vista para usuarios con roles
CREATE OR REPLACE VIEW users_with_roles 
WITH (security_invoker=true) 
AS SELECT 
  u.*,
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

-- ---------- SECCIÓN 2: VISTAS PARA ANÁLISIS DE BOTS Y DOCUMENTOS ----------

-- Vista para análisis de rendimiento de bots
CREATE OR REPLACE VIEW bot_performance 
WITH (security_invoker=true) 
AS SELECT 
  b.id AS bot_id,
  b.name AS bot_name,
  b.user_id AS owner_id,
  u.username AS owner_username,
  b.is_public,
  b.category,
  b.popularity_score,
  COUNT(DISTINCT c.id) AS conversation_count,
  COUNT(m.id) AS message_count,
  AVG(COALESCE(f.rating, 0)) AS avg_rating,
  COUNT(DISTINCT f.id) AS feedback_count,
  COUNT(DISTINCT v.id) AS vector_search_count,
  AVG(m.latency_ms) AS avg_response_latency_ms,
  MAX(m.created_at) AS last_activity,
  jsonb_build_object(
    'rating_stats', jsonb_build_object(
      '1_star', SUM(CASE WHEN f.rating = 1 THEN 1 ELSE 0 END),
      '2_star', SUM(CASE WHEN f.rating = 2 THEN 1 ELSE 0 END),
      '3_star', SUM(CASE WHEN f.rating = 3 THEN 1 ELSE 0 END),
      '4_star', SUM(CASE WHEN f.rating = 4 THEN 1 ELSE 0 END),
      '5_star', SUM(CASE WHEN f.rating = 5 THEN 1 ELSE 0 END)
    ),
    'collection_count', (
      SELECT COUNT(*) FROM app.bot_collections 
      WHERE bot_id = b.id
    )
  ) AS extended_stats
FROM public.bots b
JOIN app.users u ON b.user_id = u.id
LEFT JOIN public.conversations c ON b.id = c.bot_id
LEFT JOIN public.messages m ON c.id = m.conversation_id AND m.is_user = FALSE
LEFT JOIN app.bot_response_feedback f ON m.id = f.message_id
LEFT JOIN app.vector_analytics v ON b.id = v.bot_id
WHERE b.deleted_at IS NULL AND u.deleted_at IS NULL
GROUP BY b.id, b.name, b.user_id, u.username, b.is_public, b.category, b.popularity_score;

COMMENT ON VIEW bot_performance IS 'Métricas de rendimiento para bots con estadísticas detalladas de uso y feedback';

-- Vista para análisis de uso de documentos
CREATE OR REPLACE VIEW document_usage 
WITH (security_invoker=true) 
AS SELECT 
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
  (
    SELECT COUNT(DISTINCT va.id) 
    FROM app.vector_analytics va
    JOIN (
      SELECT va2.id, jsonb_array_elements_text(va2.metadata->'matched_chunks') AS chunk_id
      FROM app.vector_analytics va2
    ) vac ON va.id = vac.id
    JOIN app.document_chunks dch2 ON vac.chunk_id::UUID = dch2.id
    WHERE dch2.document_id = d.id
    AND va.created_at > NOW() - INTERVAL '30 days'
  ) AS recent_hits
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
WHERE d.deleted_at IS NULL AND dc.deleted_at IS NULL
GROUP BY d.id, d.title, d.content_hash, d.file_type, d.file_size, d.processing_status, 
         dc.id, dc.name, dc.user_id, u.username;

COMMENT ON VIEW document_usage IS 'Estadísticas detalladas sobre el uso de documentos en búsquedas vectoriales';

-- ---------- SECCIÓN 3: VISTAS PARA ADMINISTRACIÓN Y CONFIGURACIÓN ----------

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
  ur.role = 'admin' AND u.deleted_at IS NULL;

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
AS SELECT 
  p.plan_type,
  sc.key AS config_key,
  sc.description,
  sc.data_type,
  COALESCE(p.value, sc.value) AS value,
  sc.min_value,
  sc.max_value,
  CASE WHEN p.id IS NOT NULL THEN TRUE ELSE FALSE END AS is_customized,
  p.updated_at AS last_modified
FROM 
  (SELECT UNNEST(ARRAY['free', 'basic', 'premium', 'enterprise']) AS plan_type) plans
CROSS JOIN 
  app.system_config sc
LEFT JOIN 
  app.subscription_plan_config p ON plans.plan_type = p.plan_type AND sc.key = p.config_key
WHERE 
  sc.scope = 'subscription';

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
  s.created_at,
  s.updated_at,
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

-- ---------- SECCIÓN 4: VISTAS PÚBLICAS Y DE COMUNIDAD ----------

-- Eliminando explícitamente la vista public_bots antes de recrearla
DROP VIEW IF EXISTS public_bots CASCADE;

-- Vista para bots públicos (comunidad)
CREATE VIEW public_bots
WITH (security_invoker=true)
AS SELECT
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
  COUNT(DISTINCT c.id) AS conversation_count,
  COUNT(DISTINCT l.id) AS link_count,
  COALESCE(bp.avg_rating, 0) AS avg_rating,
  COALESCE(bp.feedback_count, 0) AS feedback_count,
  b.created_at,
  GREATEST(b.updated_at, MAX(COALESCE(c.last_activity_at, '2000-01-01'))) AS last_activity_at
FROM
  public.bots b
JOIN
  app.users u ON b.user_id = u.id
LEFT JOIN
  public.profiles p ON u.id = p.id
LEFT JOIN
  app.bot_collections bc ON b.id = bc.bot_id
LEFT JOIN
  public.conversations c ON b.id = c.bot_id
LEFT JOIN
  public.links l ON b.id = l.bot_id
LEFT JOIN
  public.bot_performance bp ON b.id = bp.bot_id
WHERE
  b.is_public = TRUE AND
  b.deleted_at IS NULL AND
  u.deleted_at IS NULL
GROUP BY
  b.id, b.name, b.description, b.avatar_url, b.category, b.tags,
  b.popularity_score, b.user_id, u.username, p.is_verified,
  bp.avg_rating, bp.feedback_count, b.created_at, b.updated_at
ORDER BY
  b.popularity_score DESC, feedback_count DESC;

COMMENT ON VIEW public_bots IS 'Bots públicos disponibles para la comunidad con estadísticas relevantes';

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

-- ---------- SECCIÓN 5: VISTAS PARA ANÁLISIS AVANZADO ----------
  
-- Vista para resumen de actividad de usuarios
CREATE OR REPLACE VIEW user_activity_summary 
WITH (security_invoker=true) 
AS SELECT
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
  (
    SELECT COUNT(*) FROM public.messages m
    JOIN public.conversations c2 ON m.conversation_id = c2.id
    WHERE c2.user_id = u.id AND m.is_user = TRUE
  ) AS total_user_messages,
  (
    SELECT COUNT(*) FROM public.messages m
    JOIN public.conversations c2 ON m.conversation_id = c2.id
    WHERE c2.user_id = u.id AND m.is_user = FALSE
  ) AS total_bot_messages,
  (
    SELECT COUNT(*) FROM app.vector_analytics va
    WHERE va.user_id = u.id
  ) AS total_vector_searches,
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
  public.conversations c ON u.id = c.user_id
LEFT JOIN
  public.links l ON u.id = l.user_id
WHERE
  u.deleted_at IS NULL
GROUP BY
  u.id, u.username, u.email, u.display_name, u.last_login_at,
  s.plan_type, s.status, p.view_count, u.created_at;

COMMENT ON VIEW user_activity_summary IS 'Resumen completo de actividad por usuario para análisis y reportes administrativos';

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
  public.bots b ON va.bot_id = b.id
WHERE
  va.created_at > NOW() - INTERVAL '30 days'
GROUP BY
  DATE(va.created_at), va.user_id, u.username, va.bot_id, b.name
ORDER BY
  search_date DESC, search_count DESC;

COMMENT ON VIEW vector_search_metrics IS 'Métricas detalladas de búsquedas vectoriales para análisis de rendimiento y uso';

-- Vista para métricas de calidad de bots
CREATE OR REPLACE VIEW bot_quality_metrics 
WITH (security_invoker=true) 
AS SELECT
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
  (
    SELECT jsonb_object_agg(category, count)
    FROM (
      SELECT 
        unnest(f2.feedback_categories) AS category,
        COUNT(*) AS count
      FROM app.bot_response_feedback f2 
      WHERE f2.message_id IN (
        SELECT id FROM public.messages 
        WHERE conversation_id IN (SELECT id FROM public.conversations WHERE bot_id = b.id)
      )
      GROUP BY category
    ) AS category_counts
  ) AS feedback_categories,
  (
    SELECT AVG(va.result_count)
    FROM app.vector_analytics va
    WHERE va.bot_id = b.id
  ) AS avg_search_results,
  b.created_at,
  MAX(COALESCE(c.last_activity_at, b.updated_at)) AS last_activity
FROM
  public.bots b
JOIN
  app.users u ON b.user_id = u.id
LEFT JOIN
  public.conversations c ON b.id = c.bot_id
LEFT JOIN
  public.messages m ON c.id = m.conversation_id
LEFT JOIN
  app.bot_response_feedback f ON m.id = f.message_id
WHERE
  b.deleted_at IS NULL
  AND u.deleted_at IS NULL
GROUP BY
  b.id, b.name, b.user_id, u.username, b.created_at;

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
  CASE 
    WHEN d.processing_status = 'error' THEN 1
    WHEN d.processing_status = 'processing' THEN 2
    WHEN d.processing_status = 'pending' THEN 3
    WHEN d.processing_status = 'completed' THEN 4
    ELSE 5
  END,
  d.updated_at DESC;

COMMENT ON VIEW document_processing_status IS 'Vista de estado de procesamiento de documentos para monitoreo de pipeline de ingesta';

-- ---------- SECCIÓN 6: CREAR VISTAS DE COMPATIBILIDAD ----------

-- Crear vistas de compatibilidad para mantener código existente funcionando
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

-- ---------- SECCIÓN 7: VERIFICAR SECURITY INVOKER EN TODAS LAS VISTAS ----------

-- Verificar que todas las vistas tienen SECURITY INVOKER
DO $$
DECLARE
  definer_views TEXT[];
  view_name TEXT;
BEGIN
  CREATE TEMP TABLE temp_views AS
  SELECT viewname
  FROM pg_views
  WHERE schemaname = 'public'
  AND securitypolicy = true; -- true = SECURITY DEFINER
  
  IF EXISTS (SELECT 1 FROM temp_views) THEN
    SELECT array_agg(viewname) INTO definer_views FROM temp_views;
    
    RAISE WARNING 'Las siguientes vistas todavía tienen SECURITY DEFINER: %', definer_views;
    
    -- Intentar corregir automáticamente cada vista
    FOR view_name IN SELECT viewname FROM temp_views LOOP
      RAISE NOTICE 'Intentando corregir vista %...', view_name;
      BEGIN
        EXECUTE format('ALTER VIEW %I SET (security_invoker=true)', view_name);
        RAISE NOTICE 'Vista % corregida exitosamente.', view_name;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'No se pudo corregir automáticamente la vista %: %', view_name, SQLERRM;
      END;
    END LOOP;
  ELSE
    RAISE NOTICE 'Todas las vistas están configuradas correctamente como SECURITY INVOKER.';
  END IF;
  
  DROP TABLE IF EXISTS temp_views;
END $$;

-- ---------- SECCIÓN 8: COMENTARIOS DE DOCUMENTACIÓN ----------

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
COMMENT ON VIEW quota_notifications IS 'Vista de compatibilidad para app.quota_notifications';users IS 'Información principal de los usuarios de la plataforma';
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
  RAISE NOTICE 'Instalación completa del sistema. Base de datos configurada exitosamente con vistas y documentación.';
  RAISE NOTICE 'Versión de esquema: %', (SELECT value FROM system_config WHERE key = 'version');
  RAISE NOTICE 'Dimensión vectorial configurada: %', (SELECT get_vector_dimension());
END $$;