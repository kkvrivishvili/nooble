-- ARCHIVO: init.sql PARTE 1 - Configuración Inicial y Extensiones
-- Propósito: Configurar extensiones básicas, esquema de autenticación y sistema de configuración global

-- Eliminar tablas relacionadas para evitar conflictos
DROP TABLE IF EXISTS system_config CASCADE;
DROP FUNCTION IF EXISTS get_vector_dimension() CASCADE;

-- Configuración inicial de la base de datos
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
ALTER ROLE current_user SET timezone TO 'UTC';

-- Habilitar extensiones necesarias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";      -- Para generación de UUIDs
CREATE EXTENSION IF NOT EXISTS "pg_trgm";        -- Para búsquedas de texto mejoradas
CREATE EXTENSION IF NOT EXISTS "vector";         -- Para capacidades vectoriales
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- Para funciones criptográficas

-- Esquema para autenticación pública
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS audit; -- Nuevo esquema para auditoría

-- Tabla mejorada de configuración global del sistema
CREATE TABLE IF NOT EXISTS system_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  description TEXT,
  scope VARCHAR(20) DEFAULT 'global' CHECK (scope IN ('global', 'user', 'subscription')),
  data_type VARCHAR(20) DEFAULT 'text' CHECK (data_type IN ('text', 'integer', 'boolean', 'json')),
  editable BOOLEAN DEFAULT TRUE,
  visible_in_admin BOOLEAN DEFAULT TRUE,
  requires_restart BOOLEAN DEFAULT FALSE,
  min_value TEXT,
  max_value TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índice para búsquedas rápidas por scope
CREATE INDEX IF NOT EXISTS idx_system_config_scope ON system_config(scope);

-- Configuraciones iniciales del sistema con metadata mejorada
INSERT INTO system_config (key, value, description, scope, data_type, editable, visible_in_admin, requires_restart, min_value, max_value)
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
  
  -- Configuraciones API para SWR (nuevas)
  ('api_cache_ttl', '300', 'Tiempo en segundos de vida del caché para respuestas API', 'global', 'integer', TRUE, TRUE, FALSE, '60', '86400'),
  ('api_page_size', '20', 'Número predeterminado de elementos por página en respuestas API', 'global', 'integer', TRUE, TRUE, FALSE, '5', '100'),
  ('api_max_page_size', '100', 'Número máximo de elementos por página en respuestas API', 'global', 'integer', TRUE, TRUE, FALSE, '20', '1000'),
  ('api_rate_limit_window', '60', 'Ventana de tiempo en segundos para rate limiting', 'global', 'integer', TRUE, TRUE, FALSE, '10', '3600')
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

-- Función mejorada para obtener la dimensión del vector desde la configuración
CREATE OR REPLACE FUNCTION get_vector_dimension() 
RETURNS INTEGER AS $$
DECLARE
  dim INTEGER;
BEGIN
  SELECT value::INTEGER INTO dim FROM system_config WHERE key = 'vector_dimension';
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
$$ LANGUAGE plpgsql;

-- Nueva función para obtener cualquier configuración con tipo correcto
CREATE OR REPLACE FUNCTION get_config(p_key TEXT) 
RETURNS TEXT AS $$
DECLARE
  v_value TEXT;
BEGIN
  SELECT value INTO v_value FROM system_config WHERE key = p_key;
  RETURN v_value;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al obtener configuración %: %', p_key, SQLERRM;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Tipado fuerte para configuraciones
CREATE OR REPLACE FUNCTION get_config_int(p_key TEXT, p_default INTEGER DEFAULT NULL) 
RETURNS INTEGER AS $$
DECLARE
  v_value TEXT;
  v_data_type TEXT;
BEGIN
  SELECT value, data_type INTO v_value, v_data_type 
  FROM system_config 
  WHERE key = p_key;
  
  IF v_value IS NULL THEN
    RETURN p_default;
  END IF;
  
  IF v_data_type = 'integer' THEN
    RETURN v_value::INTEGER;
  ELSE
    RAISE WARNING 'Configuración % no es de tipo integer', p_key;
    RETURN p_default;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al obtener configuración integer %: %', p_key, SQLERRM;
  RETURN p_default;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_config_bool(p_key TEXT, p_default BOOLEAN DEFAULT NULL) 
RETURNS BOOLEAN AS $$
DECLARE
  v_value TEXT;
  v_data_type TEXT;
BEGIN
  SELECT value, data_type INTO v_value, v_data_type 
  FROM system_config 
  WHERE key = p_key;
  
  IF v_value IS NULL THEN
    RETURN p_default;
  END IF;
  
  IF v_data_type = 'boolean' THEN
    RETURN v_value::BOOLEAN;
  ELSE
    RAISE WARNING 'Configuración % no es de tipo boolean', p_key;
    RETURN p_default;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al obtener configuración boolean %: %', p_key, SQLERRM;
  RETURN p_default;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_config_json(p_key TEXT, p_default JSONB DEFAULT NULL) 
RETURNS JSONB AS $$
DECLARE
  v_value TEXT;
  v_data_type TEXT;
BEGIN
  SELECT value, data_type INTO v_value, v_data_type 
  FROM system_config 
  WHERE key = p_key;
  
  IF v_value IS NULL THEN
    RETURN p_default;
  END IF;
  
  IF v_data_type = 'json' THEN
    RETURN v_value::JSONB;
  ELSE
    RAISE WARNING 'Configuración % no es de tipo json', p_key;
    RETURN p_default;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al obtener configuración json %: %', p_key, SQLERRM;
  RETURN p_default;
END;
$$ LANGUAGE plpgsql;

-- Tabla de auditoría para seguimiento de cambios en configuración
CREATE TABLE IF NOT EXISTS audit.config_changes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
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
$$ LANGUAGE plpgsql;

-- Eliminar trigger existente si hay para evitar duplicados
DROP TRIGGER IF EXISTS audit_config_changes_trigger ON system_config;

-- Crear trigger para auditoría
CREATE TRIGGER audit_config_changes_trigger
AFTER INSERT OR UPDATE OR DELETE ON system_config
FOR EACH ROW EXECUTE PROCEDURE audit_config_changes();

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Configuración inicial y extensiones instaladas correctamente.';
END $$;