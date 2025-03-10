-- ARCHIVO: init.sql PARTE 9 - Vistas y Comentarios
-- Propósito: Crear vistas para operaciones frecuentes y documentar la base de datos

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

-- Vista para análisis de interacción de usuarios por día
CREATE OR REPLACE VIEW daily_user_activity AS
SELECT 
  c.user_id,
  DATE(m.created_at) AS activity_date,
  COUNT(DISTINCT m.conversation_id) AS conversation_count,
  COUNT(*) AS message_count,
  SUM(CASE WHEN m.is_user = TRUE THEN 1 ELSE 0 END) AS user_messages,
  SUM(CASE WHEN m.is_user = FALSE THEN 1 ELSE 0 END) AS bot_messages,
  AVG(m.latency_ms) AS avg_response_latency,
  MAX(m.created_at) AS last_activity
FROM messages m
JOIN conversations c ON m.conversation_id = c.id
GROUP BY c.user_id, DATE(m.created_at)
ORDER BY DATE(m.created_at) DESC, c.user_id;

-- Vista para usuarios con roles
CREATE OR REPLACE VIEW users_with_roles AS
SELECT 
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
  users u
LEFT JOIN 
  user_roles ur ON u.id = ur.user_id
LEFT JOIN
  profiles p ON u.id = p.id
WHERE
  u.deleted_at IS NULL;

-- Vista para análisis de rendimiento de bots
CREATE OR REPLACE VIEW bot_performance AS
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
      SELECT COUNT(*) FROM bot_collections 
      WHERE bot_id = b.id
    )
  ) AS extended_stats
FROM bots b
JOIN users u ON b.user_id = u.id
LEFT JOIN conversations c ON b.id = c.bot_id
LEFT JOIN messages m ON c.id = m.conversation_id AND m.is_user = FALSE
LEFT JOIN bot_response_feedback f ON m.id = f.message_id
LEFT JOIN vector_analytics v ON b.id = v.bot_id
WHERE b.deleted_at IS NULL AND u.deleted_at IS NULL
GROUP BY b.id, b.name, b.user_id, u.username, b.is_public, b.category, b.popularity_score;

-- Vista para análisis de uso de documentos
CREATE OR REPLACE VIEW document_usage AS
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
  (
    SELECT COUNT(DISTINCT va.id) 
    FROM vector_analytics va
    JOIN (
      SELECT va2.id, jsonb_array_elements_text(va2.metadata->'matched_chunks') AS chunk_id
      FROM vector_analytics va2
    ) vac ON va.id = vac.id
    JOIN document_chunks dch2 ON vac.chunk_id::UUID = dch2.id
    WHERE dch2.document_id = d.id
    AND va.created_at > NOW() - INTERVAL '30 days'
  ) AS recent_hits
FROM documents d
JOIN document_collections dc ON d.collection_id = dc.id
JOIN users u ON dc.user_id = u.id
LEFT JOIN document_chunks dch ON d.id = dch.document_id
LEFT JOIN LATERAL (
  SELECT va.id, va.created_at
  FROM vector_analytics va
  WHERE 
    va.metadata->'matched_chunks' ? dch.id::TEXT
    OR va.metadata->'result_docs' ? d.id::TEXT
) va ON TRUE
WHERE d.deleted_at IS NULL AND dc.deleted_at IS NULL
GROUP BY d.id, d.title, d.content_hash, d.file_type, d.file_size, d.processing_status, 
         dc.id, dc.name, dc.user_id, u.username;

-- Vista para roles de administrador
CREATE OR REPLACE VIEW admin_users AS
SELECT 
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
  users u
JOIN 
  user_roles ur ON u.id = ur.user_id
LEFT JOIN
  users u2 ON ur.granted_by = u2.id
WHERE 
  ur.role = 'admin' AND u.deleted_at IS NULL;

-- Vista para configuración de usuarios
CREATE OR REPLACE VIEW user_config_view AS
SELECT 
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
  users u
CROSS JOIN 
  system_config sc
LEFT JOIN 
  subscriptions s ON u.id = s.user_id AND s.status = 'active'
LEFT JOIN 
  subscription_plan_config spc ON COALESCE(s.plan_type, 'free') = spc.plan_type AND sc.key = spc.config_key
LEFT JOIN 
  user_config uc ON u.id = uc.user_id AND sc.key = uc.config_key
LEFT JOIN
  users u2 ON uc.created_by = u2.id
WHERE 
  u.deleted_at IS NULL AND
  (sc.scope = 'user' OR sc.scope = 'subscription');

-- Vista para administración de configuraciones por plan
CREATE OR REPLACE VIEW plan_config_view AS
SELECT 
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
  system_config sc
LEFT JOIN 
  subscription_plan_config p ON plans.plan_type = p.plan_type AND sc.key = p.config_key
WHERE 
  sc.scope = 'subscription';

-- Vista para subscripciones activas (útil para backoffice)
CREATE OR REPLACE VIEW active_subscriptions AS
SELECT
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
    SELECT COUNT(*) FROM subscription_history sh
    WHERE sh.subscription_id = s.id
  ) AS change_count
FROM
  subscriptions s
JOIN
  users u ON s.user_id = u.id
WHERE
  s.status IN ('active', 'trial') AND
  u.deleted_at IS NULL
ORDER BY
  expiring_soon DESC, s.current_period_end ASC;

-- Vista para bots públicos (comunidad)
CREATE OR REPLACE VIEW public_bots AS
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
  COUNT(DISTINCT c.id) AS conversation_count,
  COUNT(DISTINCT l.id) AS link_count,
  COALESCE(bp.avg_rating, 0) AS avg_rating,
  COALESCE(bp.feedback_count, 0) AS feedback_count,
  b.created_at,
  GREATEST(b.updated_at, MAX(COALESCE(c.last_activity_at, '2000-01-01'))) AS last_activity_at
FROM
  bots b
JOIN
  users u ON b.user_id = u.id
LEFT JOIN
  profiles p ON u.id = p.id
LEFT JOIN
  bot_collections bc ON b.id = bc.bot_id
LEFT JOIN
  conversations c ON b.id = c.bot_id
LEFT JOIN
  links l ON b.id = l.bot_id
LEFT JOIN
  bot_performance bp ON b.id = bp.bot_id
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
  
-- Vista para resumen de actividad de usuarios
CREATE OR REPLACE VIEW user_activity_summary AS
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
  (
    SELECT COUNT(*) FROM messages m
    JOIN conversations c2 ON m.conversation_id = c2.id
    WHERE c2.user_id = u.id AND m.is_user = TRUE
  ) AS total_user_messages,
  (
    SELECT COUNT(*) FROM messages m
    JOIN conversations c2 ON m.conversation_id = c2.id
    WHERE c2.user_id = u.id AND m.is_user = FALSE
  ) AS total_bot_messages,
  (
    SELECT COUNT(*) FROM vector_analytics va
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
  users u
LEFT JOIN
  subscriptions s ON u.id = s.user_id AND s.status = 'active'
LEFT JOIN
  profiles p ON u.id = p.id
LEFT JOIN
  bots b ON u.id = b.user_id AND b.deleted_at IS NULL
LEFT JOIN
  document_collections dc ON u.id = dc.user_id AND dc.deleted_at IS NULL
LEFT JOIN
  documents d ON dc.id = d.collection_id AND d.deleted_at IS NULL
LEFT JOIN
  conversations c ON u.id = c.user_id
LEFT JOIN
  links l ON u.id = l.user_id
WHERE
  u.deleted_at IS NULL
GROUP BY
  u.id, u.username, u.email, u.display_name, u.last_login_at,
  s.plan_type, s.status, p.view_count, u.created_at;

-- Vista para métricas de búsqueda vectorial
CREATE OR REPLACE VIEW vector_search_metrics AS
SELECT
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
  vector_analytics va
LEFT JOIN
  users u ON va.user_id = u.id
LEFT JOIN
  bots b ON va.bot_id = b.id
WHERE
  va.created_at > NOW() - INTERVAL '30 days'
GROUP BY
  DATE(va.created_at), va.user_id, u.username, va.bot_id, b.name
ORDER BY
  search_date DESC, search_count DESC;

-- Vista para métricas de calidad de bots
CREATE OR REPLACE VIEW bot_quality_metrics AS
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
  (
    SELECT jsonb_object_agg(category, count)
    FROM (
      SELECT 
        unnest(f2.feedback_categories) AS category,
        COUNT(*) AS count
      FROM bot_response_feedback f2 
      WHERE f2.message_id IN (
        SELECT id FROM messages 
        WHERE conversation_id IN (SELECT id FROM conversations WHERE bot_id = b.id)
      )
      GROUP BY category
    ) AS category_counts
  ) AS feedback_categories,
  (
    SELECT AVG(va.result_count)
    FROM vector_analytics va
    WHERE va.bot_id = b.id
  ) AS avg_search_results,
  b.created_at,
  MAX(COALESCE(c.last_activity_at, b.updated_at)) AS last_activity
FROM
  bots b
JOIN
  users u ON b.user_id = u.id
LEFT JOIN
  conversations c ON b.id = c.bot_id
LEFT JOIN
  messages m ON c.id = m.conversation_id
LEFT JOIN
  bot_response_feedback f ON m.id = f.message_id
WHERE
  b.deleted_at IS NULL
  AND u.deleted_at IS NULL
GROUP BY
  b.id, b.name, b.user_id, u.username, b.created_at;

-- Vista para estado de procesamiento de documentos
CREATE OR REPLACE VIEW document_processing_status AS
SELECT
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
  documents d
JOIN
  document_collections dc ON d.collection_id = dc.id
JOIN
  users u ON dc.user_id = u.id
LEFT JOIN
  document_chunks dch ON d.id = dch.document_id
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

-- Agregar comentarios para documentación
COMMENT ON TABLE users IS 'Información principal de los usuarios de la plataforma';
COMMENT ON TABLE profiles IS 'Información extendida de perfiles de usuario';
COMMENT ON TABLE user_roles IS 'Roles de usuario para gestión de permisos y acceso';
COMMENT ON TABLE user_role_history IS 'Historial de cambios en roles de usuario para auditoría';
COMMENT ON TABLE themes IS 'Temas visuales disponibles para personalizar los perfiles de Linktree';
COMMENT ON TABLE subscriptions IS 'Información de suscripciones y planes de usuarios';
COMMENT ON TABLE subscription_history IS 'Historial de cambios en suscripciones para auditoría';
COMMENT ON TABLE bots IS 'Bots personalizados creados por los usuarios para interactuar con su contenido';
COMMENT ON TABLE document_collections IS 'Colecciones de documentos que alimentan la base de conocimiento de los bots';
COMMENT ON TABLE documents IS 'Documentos individuales que contienen información para recuperación aumentada por generación (RAG)';
COMMENT ON TABLE document_chunks IS 'Fragmentos de documentos vectorizados para búsqueda semántica';
COMMENT ON TABLE links IS 'Enlaces que aparecen en el perfil de Linktree del usuario, pueden ser URLs o chatbots';
COMMENT ON TABLE link_groups IS 'Grupos para organizar enlaces en secciones';
COMMENT ON TABLE link_group_items IS 'Asociación entre enlaces y grupos';
COMMENT ON TABLE analytics IS 'Registro de interacciones con enlaces y perfiles para análisis';
COMMENT ON TABLE conversations IS 'Conversaciones entre usuarios y bots';
COMMENT ON TABLE messages IS 'Mensajes individuales dentro de conversaciones';
COMMENT ON TABLE bot_response_feedback IS 'Feedback de usuarios sobre respuestas de bots';
COMMENT ON TABLE vector_analytics IS 'Registro de consultas de búsqueda vectorial';
COMMENT ON TABLE system_config IS 'Configuración global del sistema con metadatos, tipos y restricciones';
COMMENT ON TABLE user_config IS 'Configuración específica por usuario que sobrescribe los valores por defecto';
COMMENT ON TABLE subscription_plan_config IS 'Configuración predeterminada para cada tipo de plan de suscripción';
COMMENT ON TABLE system_errors IS 'Registro de errores del sistema';
COMMENT ON TABLE usage_metrics IS 'Métricas de uso por usuario y tipo';
COMMENT ON TABLE quota_notifications IS 'Registro de notificaciones enviadas sobre límites de cuota';

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

-- Comentarios para funciones principales
COMMENT ON FUNCTION is_admin IS 'Verifica si un usuario tiene rol de administrador';
COMMENT ON FUNCTION has_permission IS 'Verifica si un usuario tiene un permiso específico basado en su rol';
COMMENT ON FUNCTION check_user_quota IS 'Verifica si un usuario está dentro de su cuota para diferentes recursos usando la jerarquía de configuración';
COMMENT ON FUNCTION log_system_error IS 'Registra errores del sistema para monitoreo y solución de problemas';
COMMENT ON FUNCTION update_vector_dimensions IS 'Actualiza las dimensiones vectoriales en todas las tablas relevantes';
COMMENT ON FUNCTION create_analytics_partition IS 'Crea automáticamente particiones mensuales para la tabla de analytics';
COMMENT ON FUNCTION update_vector_fields_to_current_dimension IS 'Actualiza los campos vectoriales en todas las tablas a la dimensión actual configurada';
COMMENT ON FUNCTION update_modified_column IS 'Función para actualizar automáticamente el timestamp de updated_at';
COMMENT ON FUNCTION increment_link_clicks IS 'Incrementa el contador de clics para enlaces';
COMMENT ON FUNCTION get_user_config IS 'Obtiene el valor de configuración específico para un usuario con cascada de prioridad';
COMMENT ON FUNCTION get_user_config_int IS 'Versión tipada para obtener configuraciones enteras';
COMMENT ON FUNCTION get_user_config_bool IS 'Versión tipada para obtener configuraciones booleanas';
COMMENT ON FUNCTION get_user_config_json IS 'Versión tipada para obtener configuraciones JSON';
COMMENT ON FUNCTION set_user_config IS 'Establece una configuración específica para un usuario con validación';
COMMENT ON FUNCTION bulk_update_config_by_plan IS 'Actualiza una configuración para todos los usuarios de un plan específico';
COMMENT ON FUNCTION reset_user_config_to_plan IS 'Restablece la configuración de un usuario a los valores predeterminados de su plan';
COMMENT ON FUNCTION sync_user_config_on_subscription_change IS 'Sincroniza automáticamente la configuración cuando un usuario cambia de plan';
COMMENT ON FUNCTION validate_config_value IS 'Valida y normaliza valores de configuración según su tipo y restricciones';
COMMENT ON FUNCTION track_role_changes IS 'Registra cambios en roles de usuario para auditoría';
COMMENT ON FUNCTION queue_document_for_embedding IS 'Pone un documento en cola para regenerar sus embeddings';
COMMENT ON FUNCTION queue_collection_for_embedding IS 'Pone una colección completa en cola para regenerar embeddings';
COMMENT ON FUNCTION check_database_integrity IS 'Verifica la integridad de la base de datos para detectar problemas';
COMMENT ON FUNCTION check_quota_thresholds IS 'Monitoriza los niveles de uso de cuota y genera notificaciones';
COMMENT ON FUNCTION update_conversation_last_activity IS 'Actualiza el timestamp de última actividad en una conversación';

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Instalación completa del sistema. Base de datos configurada exitosamente con vistas y documentación.';
  RAISE NOTICE 'Versión de esquema: %', (SELECT value FROM system_config WHERE key = 'version');
  RAISE NOTICE 'Dimensión vectorial configurada: %', (SELECT get_vector_dimension());
END $$;