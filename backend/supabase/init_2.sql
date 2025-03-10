-- ARCHIVO: init.sql PARTE 2 - Tablas Fundamentales
-- Propósito: Crear tablas fundamentales del sistema como temas, usuarios y configuración

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS themes CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS user_config CASCADE;
DROP TABLE IF EXISTS subscription_plan_config CASCADE;
DROP FUNCTION IF EXISTS get_user_config CASCADE;

-- Tabla de Temas
CREATE TABLE IF NOT EXISTS themes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(50) NOT NULL,
  background_color VARCHAR(20) CHECK (background_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  text_color VARCHAR(20) CHECK (text_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  button_color VARCHAR(20) CHECK (button_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  button_text_color VARCHAR(20) CHECK (button_text_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  is_premium BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Crear índice único en nombre de tema
CREATE UNIQUE INDEX idx_themes_name_unique ON themes(name);

-- Tabla de Usuarios
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  auth_id UUID UNIQUE NOT NULL,
  username VARCHAR(30) NOT NULL CHECK (username ~* '^[a-z0-9_\.]{3,30}$'),
  email TEXT NOT NULL CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+[.][A-Za-z]+$'),
  display_name VARCHAR(50),
  bio TEXT,
  avatar_url TEXT CHECK (avatar_url IS NULL OR avatar_url ~* '^https?://.*$'),
  theme_id UUID REFERENCES themes(id) ON DELETE SET NULL,
  last_login_at TIMESTAMP WITH TIME ZONE,
  password_changed_at TIMESTAMP WITH TIME ZONE, -- Nueva para seguridad
  login_attempts INTEGER DEFAULT 0, -- Nueva para seguridad
  locked_until TIMESTAMP WITH TIME ZONE, -- Nueva para bloqueo temporal
  deleted_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Crear índices únicos para usuarios con comprobación de eliminados
CREATE UNIQUE INDEX idx_users_username_unique ON users(username) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_users_email_unique ON users(email) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_users_auth_id_unique ON users(auth_id) WHERE deleted_at IS NULL;

-- Tabla mejorada de configuración específica por usuario
CREATE TABLE IF NOT EXISTS user_config (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  config_key TEXT NOT NULL REFERENCES system_config(key) ON DELETE CASCADE,
  value TEXT NOT NULL,
  override_reason TEXT,
  created_by UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(user_id, config_key)
);

-- Tabla mejorada de configuración según plan de suscripción
CREATE TABLE IF NOT EXISTS subscription_plan_config (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  plan_type VARCHAR(20) NOT NULL CHECK (plan_type IN ('free', 'basic', 'premium', 'enterprise')),
  config_key TEXT NOT NULL REFERENCES system_config(key) ON DELETE CASCADE,
  value TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(plan_type, config_key)
);

-- Insertar temas predefinidos con mejor validación
INSERT INTO themes (name, background_color, text_color, button_color, button_text_color, is_premium)
VALUES
  ('Default', '#FFFFFF', '#000000', '#0366d6', '#FFFFFF', FALSE),
  ('Dark', '#121212', '#FFFFFF', '#BB86FC', '#000000', FALSE),
  ('Sunset', '#FFC0CB', '#800080', '#FF69B4', '#FFFFFF', FALSE),
  ('Forest', '#228B22', '#F5F5F5', '#006400', '#F5F5F5', FALSE),
  ('Ocean', '#1E90FF', '#F5F5F5', '#0000CD', '#F5F5F5', FALSE),
  ('Minimal', '#F5F5F5', '#333333', '#555555', '#FFFFFF', FALSE),
  ('Vibrant', '#FFD700', '#800080', '#FF4500', '#FFFFFF', TRUE),
  ('Pastel', '#E6E6FA', '#483D8B', '#DDA0DD', '#483D8B', TRUE),
  ('Corporate', '#F8F9FA', '#212529', '#0D6EFD', '#FFFFFF', TRUE),
  ('Elegant', '#2C3E50', '#ECF0F1', '#16A085', '#FFFFFF', TRUE),
  ('Neon', '#000000', '#00FF00', '#FF00FF', '#000000', TRUE),
  ('Retro', '#FFD700', '#8B4513', '#FF6347', '#FFFFFF', TRUE)
ON CONFLICT (name) 
DO UPDATE SET 
  background_color = EXCLUDED.background_color,
  text_color = EXCLUDED.text_color,
  button_color = EXCLUDED.button_color,
  button_text_color = EXCLUDED.button_text_color,
  is_premium = EXCLUDED.is_premium,
  updated_at = NOW();

-- Configuración inicial por tipo de suscripción
INSERT INTO subscription_plan_config (plan_type, config_key, value)
VALUES
  -- Plan Gratuito
  ('free', 'default_user_quota_bots', '1'),
  ('free', 'default_user_quota_collections', '3'),
  ('free', 'default_user_quota_documents', '50'),
  ('free', 'default_user_quota_vector_searches', '100'),
  ('free', 'user_enable_advanced_analytics', 'false'),
  ('free', 'user_rate_limit', '30'),
  ('free', 'user_max_token_length', '2048'),
  
  -- Plan Básico
  ('basic', 'default_user_quota_bots', '3'),
  ('basic', 'default_user_quota_collections', '5'),
  ('basic', 'default_user_quota_documents', '100'),
  ('basic', 'default_user_quota_vector_searches', '500'),
  ('basic', 'user_enable_advanced_analytics', 'true'),
  ('basic', 'user_rate_limit', '60'),
  ('basic', 'user_max_token_length', '4096'),
  
  -- Plan Premium
  ('premium', 'default_user_quota_bots', '5'),
  ('premium', 'default_user_quota_collections', '10'),
  ('premium', 'default_user_quota_documents', '200'),
  ('premium', 'default_user_quota_vector_searches', '1000'),
  ('premium', 'user_enable_advanced_analytics', 'true'),
  ('premium', 'user_rate_limit', '120'),
  ('premium', 'user_max_token_length', '8192'),
  
  -- Plan Enterprise
  ('enterprise', 'default_user_quota_bots', '20'),
  ('enterprise', 'default_user_quota_collections', '50'),
  ('enterprise', 'default_user_quota_documents', '1000'),
  ('enterprise', 'default_user_quota_vector_searches', '5000'),
  ('enterprise', 'user_enable_advanced_analytics', 'true'),
  ('enterprise', 'user_rate_limit', '300'),
  ('enterprise', 'user_max_token_length', '16384')
ON CONFLICT (plan_type, config_key) 
DO UPDATE SET 
  value = EXCLUDED.value,
  updated_at = NOW();

-- Función mejorada para obtener configuración específica de usuario
CREATE OR REPLACE FUNCTION get_user_config(
  p_user_id UUID,
  p_config_key TEXT,
  p_default_value TEXT DEFAULT NULL
) 
RETURNS TEXT AS $$
DECLARE
  v_value TEXT;
  v_subscription_plan VARCHAR(20);
  v_config_type VARCHAR(20);
BEGIN
  -- Verificar que la clave existe y obtener su tipo
  SELECT data_type INTO v_config_type 
  FROM system_config 
  WHERE key = p_config_key;
  
  IF v_config_type IS NULL THEN
    RAISE WARNING 'Configuración % no existe', p_config_key;
    RETURN p_default_value;
  END IF;

  -- Intentar obtener configuración específica del usuario
  SELECT value INTO v_value 
  FROM user_config 
  WHERE user_id = p_user_id AND config_key = p_config_key;
  
  -- Si no existe configuración específica, buscar en plan de suscripción
  IF v_value IS NULL THEN
    -- Obtener plan actual del usuario
    SELECT plan_type INTO v_subscription_plan
    FROM subscriptions
    WHERE user_id = p_user_id AND status = 'active'
    ORDER BY current_period_end DESC
    LIMIT 1;
    
    -- Si no tiene plan activo, usar 'free'
    IF v_subscription_plan IS NULL THEN
      v_subscription_plan := 'free';
    END IF;
    
    -- Buscar configuración según plan
    SELECT value INTO v_value
    FROM subscription_plan_config
    WHERE plan_type = v_subscription_plan AND config_key = p_config_key;
    
    -- Si no existe en plan, usar configuración global
    IF v_value IS NULL THEN
      SELECT value INTO v_value
      FROM system_config
      WHERE key = p_config_key;
    END IF;
  END IF;
  
  -- Si aún no hay valor, usar el default proporcionado
  RETURN COALESCE(v_value, p_default_value);
END;
$$ LANGUAGE plpgsql;

-- Versiones tipadas de get_user_config (nuevas)
CREATE OR REPLACE FUNCTION get_user_config_int(
  p_user_id UUID,
  p_config_key TEXT,
  p_default_value INTEGER DEFAULT NULL
) 
RETURNS INTEGER AS $$
DECLARE
  v_value TEXT;
  v_config_type VARCHAR(20);
BEGIN
  -- Verificar tipo de configuración
  SELECT data_type INTO v_config_type 
  FROM system_config 
  WHERE key = p_config_key;
  
  IF v_config_type != 'integer' THEN
    RAISE WARNING 'Configuración % no es de tipo integer', p_config_key;
    RETURN p_default_value;
  END IF;
  
  -- Obtener valor como texto
  v_value := get_user_config(p_user_id, p_config_key, p_default_value::TEXT);
  
  -- Convertir a entero con validación
  BEGIN
    RETURN v_value::INTEGER;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error convirtiendo % a integer: %', v_value, SQLERRM;
    RETURN p_default_value;
  END;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_user_config_bool(
  p_user_id UUID,
  p_config_key TEXT,
  p_default_value BOOLEAN DEFAULT NULL
) 
RETURNS BOOLEAN AS $$
DECLARE
  v_value TEXT;
  v_config_type VARCHAR(20);
BEGIN
  -- Verificar tipo de configuración
  SELECT data_type INTO v_config_type 
  FROM system_config 
  WHERE key = p_config_key;
  
  IF v_config_type != 'boolean' THEN
    RAISE WARNING 'Configuración % no es de tipo boolean', p_config_key;
    RETURN p_default_value;
  END IF;
  
  -- Obtener valor como texto
  v_value := get_user_config(p_user_id, p_config_key, p_default_value::TEXT);
  
  -- Convertir a boolean con validación
  IF v_value IN ('true', 't', '1') THEN
    RETURN TRUE;
  ELSIF v_value IN ('false', 'f', '0') THEN
    RETURN FALSE;
  ELSE
    RAISE WARNING 'Valor inválido para boolean: %', v_value;
    RETURN p_default_value;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_user_config_json(
  p_user_id UUID,
  p_config_key TEXT,
  p_default_value JSONB DEFAULT NULL
) 
RETURNS JSONB AS $$
DECLARE
  v_value TEXT;
  v_config_type VARCHAR(20);
BEGIN
  -- Verificar tipo de configuración
  SELECT data_type INTO v_config_type 
  FROM system_config 
  WHERE key = p_config_key;
  
  IF v_config_type != 'json' THEN
    RAISE WARNING 'Configuración % no es de tipo json', p_config_key;
    RETURN p_default_value;
  END IF;
  
  -- Obtener valor como texto
  v_value := get_user_config(p_user_id, p_config_key, NULL);
  
  -- Si no hay valor, devolver el default
  IF v_value IS NULL THEN
    RETURN p_default_value;
  END IF;
  
  -- Convertir a JSONB con validación
  BEGIN
    RETURN v_value::JSONB;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error convirtiendo a JSONB: %', SQLERRM;
    RETURN p_default_value;
  END;
END;
$$ LANGUAGE plpgsql;

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Tablas fundamentales creadas correctamente.';
END $$;