-- ==============================================
-- ARCHIVO: init_1.sql - Configuración Inicial y Extensiones
-- ==============================================
-- Propósito: Configurar estructura base de la base de datos, incluyendo:
--   1. Esquemas para diferentes funcionalidades (public, app, auth, extensions)
--   2. Extensiones PostgreSQL necesarias
--   3. Sistema central de configuración
--   4. Funciones de utilidad para acceso a configuración
-- ==============================================

-- ---------- SECCIÓN 1: ESQUEMAS Y EXTENSIONES ----------

-- Crear esquemas para organizar la base de datos
CREATE SCHEMA IF NOT EXISTS extensions; -- Esquema para extensiones (seguridad)
CREATE SCHEMA IF NOT EXISTS app;        -- Esquema para datos internos de la aplicación
CREATE SCHEMA IF NOT EXISTS auth;       -- Esquema para autenticación pública
CREATE SCHEMA IF NOT EXISTS audit;      -- Esquema para registros de auditoría

-- Configurar search path para incluir todos los esquemas necesarios
ALTER ROLE current_user SET search_path TO public, app, extensions, "$user";

-- Configuración inicial de la base de datos
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
ALTER ROLE current_user SET timezone TO 'UTC';

-- Habilitar extensiones necesarias en el esquema extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pg_trgm" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "vector" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pgcrypto" SCHEMA extensions;

-- Eliminar tablas relacionadas para evitar conflictos
DROP TABLE IF EXISTS app.system_config CASCADE;
DROP FUNCTION IF EXISTS get_vector_dimension() CASCADE;

-- ---------- SECCIÓN 2: SISTEMA DE CONFIGURACIÓN GLOBAL ----------

-- Tabla mejorada de configuración global del sistema (movida a esquema app)
CREATE TABLE IF NOT EXISTS app.system_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  description TEXT,
  scope VARCHAR(20) DEFAULT 'global' CHECK (scope IN ('global', 'user', 'subscription')),
  data_type VARCHAR(20) DEFAULT 'text' CHECK (data_type IN ('text', 'integer', 'boolean', 'json', 'float')),
  editable BOOLEAN DEFAULT TRUE,
  visible_in_admin BOOLEAN DEFAULT TRUE,
  requires_restart BOOLEAN DEFAULT FALSE,
  min_value TEXT,
  max_value TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índice para búsquedas rápidas por scope
CREATE INDEX IF NOT EXISTS idx_system_config_scope ON app.system_config(scope);

-- ---------- SECCIÓN 3: CONFIGURACIONES INICIALES DEL SISTEMA ----------

-- Configuraciones iniciales del sistema con metadata mejorada
INSERT INTO app.system_config (key, value, description, scope, data_type, editable, visible_in_admin, requires_restart, min_value, max_value)
VALUES
  -- Configuraciones de sistema
  ('vector_dimension', '1536', 'Dimensión del modelo de embeddings actual', 'global', 'integer', TRUE, TRUE, TRUE, '768', '4096'),
  ('version', '2.1', 'Versión actual del esquema de base de datos', 'global', 'text', FALSE, TRUE, FALSE, NULL, NULL),
  ('db_check_interval', '86400', 'Intervalo en segundos para verificación automática de integridad de BD', 'global', 'integer', TRUE, TRUE, FALSE, '3600', '604800'),
  
  -- Configuraciones de cuotas por defecto
  ('default_user_quota_bots', '1', 'Número de bots permitidos para usuarios gratuitos', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '100'),
  ('default_user_quota_collections', '3', 'Número de colecciones permitidas para usuarios gratuitos', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '100'),
  ('default_user_quota_documents', '50', 'Número de documentos permitidos para usuarios gratuitos', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '1000'),
  ('default_user_quota_vector_searches', '100', 'Número de búsquedas vectoriales diarias para usuarios gratuitos', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '10000'),
  
  -- Configuraciones de cuotas premium
  ('premium_user_quota_bots', '5', 'Número de bots permitidos para usuarios premium', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '100'),
  ('premium_user_quota_collections', '10', 'Número de colecciones permitidas para usuarios premium', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '500'),
  ('premium_user_quota_documents', '200', 'Número de documentos permitidos para usuarios premium', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '5000'),
  ('premium_user_quota_vector_searches', '1000', 'Número de búsquedas vectoriales diarias para usuarios premium', 'subscription', 'integer', TRUE, TRUE, FALSE, '0', '50000'),
  
  -- Configuraciones específicas por usuario
  ('user_enable_advanced_analytics', 'false', 'Habilitar analytics avanzados para el usuario', 'user', 'boolean', TRUE, TRUE, FALSE, NULL, NULL),
  ('user_custom_bot_model', 'gpt-3.5-turbo', 'Modelo personalizado para bots del usuario', 'user', 'text', TRUE, TRUE, FALSE, NULL, NULL),
  ('user_rate_limit', '60', 'Límite de peticiones por minuto para el usuario', 'user', 'integer', TRUE, TRUE, FALSE, '10', '1000'),
  ('user_max_token_length', '4096', 'Longitud máxima de tokens para peticiones', 'user', 'integer', TRUE, TRUE, FALSE, '1024', '16384'),
  
  -- Configuraciones de seguridad
  ('security_password_min_length', '8', 'Longitud mínima de contraseña', 'global', 'integer', TRUE, TRUE, FALSE, '6', '32'),
  ('security_rate_limit_penalty', '300', 'Tiempo en segundos de penalización por superar rate limit', 'global', 'integer', TRUE, TRUE, FALSE, '30', '3600'),
  ('security_max_failed_attempts', '5', 'Máximo de intentos de login fallidos antes de bloqueo', 'global', 'integer', TRUE, TRUE, FALSE, '3', '10'),
  ('security_password_expiry_days', '90', 'Días hasta que se requiera cambio de contraseña', 'global', 'integer', TRUE, TRUE, FALSE, '30', '365'),
  
  -- Configuraciones API para SWR
  ('api_cache_ttl', '300', 'Tiempo en segundos de vida del caché para respuestas API', 'global', 'integer', TRUE, TRUE, FALSE, '60', '86400'),
  ('api_page_size', '20', 'Número predeterminado de elementos por página en respuestas API', 'global', 'integer', TRUE, TRUE, FALSE, '5', '100'),
  ('api_max_page_size', '100', 'Número máximo de elementos por página en respuestas API', 'global', 'integer', TRUE, TRUE, FALSE, '20', '1000'),
  ('api_rate_limit_window', '60', 'Ventana de tiempo en segundos para rate limiting', 'global', 'integer', TRUE, TRUE, FALSE, '10', '3600'),
  
  -- Configuraciones para LlamaIndex y Langchain
  ('llamaindex_default_chunk_size', '1000', 'Tamaño de chunk predeterminado para LlamaIndex', 'global', 'integer', TRUE, TRUE, FALSE, '100', '4000'),
  ('llamaindex_default_chunk_overlap', '200', 'Overlap de chunks predeterminado para LlamaIndex', 'global', 'integer', TRUE, TRUE, FALSE, '0', '1000'),
  ('llamaindex_similarity_top_k', '5', 'Número de chunks similares a recuperar por defecto', 'global', 'integer', TRUE, TRUE, FALSE, '1', '20'),
  ('langchain_max_tokens_response', '1024', 'Número máximo de tokens para respuestas de Langchain', 'global', 'integer', TRUE, TRUE, FALSE, '50', '8000'),
  ('langchain_default_temperature', '0.7', 'Temperatura predeterminada para generación de contenido', 'global', 'float', TRUE, TRUE, FALSE, '0', '2'),
  ('bot_default_system_prompt', 'You are a helpful assistant.', 'Prompt de sistema predeterminado para nuevos bots', 'global', 'text', TRUE, TRUE, FALSE, NULL, NULL)
ON CONFLICT (key) 
DO UPDATE SET 
  value = EXCLUDED.value,
  description = EXCLUDED.description,
  scope = EXCLUDED.scope,
  data_type = EXCLUDED.data_type,
  editable = EXCLUDED.editable,
  visible_in_admin = EXCLUDED.visible_in_admin,
  requires_restart = EXCLUDED.requires_restart,
  min_value = EXCLUDED.min_value,
  max_value = EXCLUDED.max_value,
  updated_at = NOW();

-- ---------- SECCIÓN 4: FUNCIONES DE ACCESO A CONFIGURACIÓN ----------

-- Función para obtener la dimensión del vector (mantenida por compatibilidad)
CREATE OR REPLACE FUNCTION get_vector_dimension() 
RETURNS INTEGER AS $$
DECLARE
  dim INTEGER;
BEGIN
  SELECT value::INTEGER INTO dim FROM app.system_config WHERE key = 'vector_dimension';
  IF dim IS NULL THEN
    -- Valor por defecto si no se encuentra la configuración
    RETURN 1536;
  END IF;
  RETURN dim;
EXCEPTION WHEN OTHERS THEN
  -- En caso de error, devolver el valor por defecto
  RAISE WARNING 'Error al obtener dimensión del vector: %', SQLERRM;
  RETURN 1536;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función genérica para obtener cualquier configuración
CREATE OR REPLACE FUNCTION get_config(p_key TEXT, p_default TEXT DEFAULT NULL) 
RETURNS TEXT AS $$
DECLARE
  v_value TEXT;
BEGIN
  SELECT value INTO v_value FROM app.system_config WHERE key = p_key;
  RETURN COALESCE(v_value, p_default);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al obtener configuración %: %', p_key, SQLERRM;
  RETURN p_default;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función única mejorada para obtener configuración tipada
CREATE OR REPLACE FUNCTION get_typed_config(
  p_key TEXT, 
  p_default ANYELEMENT
) 
RETURNS ANYELEMENT AS $$
DECLARE
  v_value TEXT;
  v_data_type TEXT;
  v_result ANYELEMENT;
BEGIN
  -- Obtener valor y tipo de dato de la configuración
  SELECT value, data_type INTO v_value, v_data_type 
  FROM app.system_config 
  WHERE key = p_key;
  
  -- Si no existe, devolver el valor por defecto
  IF v_value IS NULL THEN
    RETURN p_default;
  END IF;
  
  -- Determinar el tipo de dato de retorno basado en el valor por defecto
  IF pg_typeof(p_default) = 'integer'::regtype THEN
    IF v_data_type = 'integer' THEN
      RETURN v_value::INTEGER;
    ELSE
      RAISE WARNING 'Configuración % no es de tipo integer', p_key;
      RETURN p_default;
    END IF;
  ELSIF pg_typeof(p_default) = 'boolean'::regtype THEN
    IF v_data_type = 'boolean' THEN
      IF v_value IN ('true', 't', '1') THEN
        RETURN TRUE;
      ELSIF v_value IN ('false', 'f', '0') THEN  
        RETURN FALSE;
      ELSE
        RAISE WARNING 'Valor inválido para boolean: %', v_value;
        RETURN p_default;
      END IF;
    ELSE
      RAISE WARNING 'Configuración % no es de tipo boolean', p_key;
      RETURN p_default;
    END IF;
  ELSIF pg_typeof(p_default) = 'numeric'::regtype THEN
    IF v_data_type = 'float' THEN
      RETURN v_value::NUMERIC;
    ELSE
      RAISE WARNING 'Configuración % no es de tipo float', p_key;
      RETURN p_default;
    END IF;
  ELSIF pg_typeof(p_default) = 'jsonb'::regtype THEN
    IF v_data_type = 'json' THEN
      RETURN v_value::JSONB;
    ELSE
      RAISE WARNING 'Configuración % no es de tipo json', p_key;
      RETURN p_default;
    END IF;
  ELSE
    -- Para tipos de texto u otros
    RETURN v_value;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al obtener configuración %: %', p_key, SQLERRM;
  RETURN p_default;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Funciones de compatibilidad para no romper código existente
CREATE OR REPLACE FUNCTION get_config_int(p_key TEXT, p_default INTEGER DEFAULT NULL) 
RETURNS INTEGER AS $$
BEGIN
  RETURN get_typed_config(p_key, p_default);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

CREATE OR REPLACE FUNCTION get_config_bool(p_key TEXT, p_default BOOLEAN DEFAULT NULL) 
RETURNS BOOLEAN AS $$
BEGIN
  RETURN get_typed_config(p_key, p_default);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

CREATE OR REPLACE FUNCTION get_config_json(p_key TEXT, p_default JSONB DEFAULT NULL) 
RETURNS JSONB AS $$
BEGIN
  RETURN get_typed_config(p_key, p_default);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 5: AUDITORÍA DE CONFIGURACIÓN ----------

-- Tabla de auditoría para seguimiento de cambios en configuración
CREATE TABLE IF NOT EXISTS audit.config_changes (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  config_key TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT,
  change_type VARCHAR(10) CHECK (change_type IN ('INSERT', 'UPDATE', 'DELETE')),
  changed_by TEXT,
  changed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Trigger para auditar cambios en configuración
CREATE OR REPLACE FUNCTION audit_config_changes()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit.config_changes (config_key, old_value, new_value, change_type, changed_by)
    VALUES (NEW.key, NULL, NEW.value, 'INSERT', current_user);
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.value <> NEW.value THEN
      INSERT INTO audit.config_changes (config_key, old_value, new_value, change_type, changed_by)
      VALUES (NEW.key, OLD.value, NEW.value, 'UPDATE', current_user);
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO audit.config_changes (config_key, old_value, new_value, change_type, changed_by)
    VALUES (OLD.key, OLD.value, NULL, 'DELETE', current_user);
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Eliminar trigger existente si hay para evitar duplicados
DROP TRIGGER IF EXISTS audit_config_changes_trigger ON app.system_config;

-- Crear trigger para auditoría
CREATE TRIGGER audit_config_changes_trigger
AFTER INSERT OR UPDATE OR DELETE ON app.system_config
FOR EACH ROW EXECUTE PROCEDURE audit_config_changes();

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  RAISE NOTICE 'Configuración inicial y extensiones instaladas correctamente.';
  RAISE NOTICE 'Esquema app creado para tablas internas.';
  RAISE NOTICE 'Sistema de configuración inicializado.';
END $$;