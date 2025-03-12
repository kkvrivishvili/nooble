-- ==============================================
-- ARCHIVO: init_2.sql - Tablas Fundamentales
-- ==============================================
-- Propósito: Crear las tablas fundamentales del sistema incluyendo temas (themes), 
-- usuarios (users) y configuración específica por usuario/suscripción. Estas tablas 
-- forman el núcleo de la aplicación y son referenciadas por prácticamente todos 
-- los demás componentes.
--
-- Reorganización de esquemas:
-- - themes: Permanece en esquema 'public' por ser accesible públicamente
-- - users: Movida a esquema 'app' como tabla interna central
-- - user_config: Movida a esquema 'app' para gestión interna
-- - subscription_plan_config: Movida a esquema 'app' para gestión interna
--
-- La tabla themes es pública ya que define la apariencia visual accesible por visitantes.
-- Las tablas users, user_config y subscription_plan_config contienen datos sensibles
-- que deben ser protegidos en el esquema 'app'.
-- ==============================================

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS themes CASCADE;
DROP TABLE IF EXISTS public.themes CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS app.users CASCADE;
DROP TABLE IF EXISTS user_config CASCADE;
DROP TABLE IF EXISTS app.user_config CASCADE;
DROP TABLE IF EXISTS subscription_plan_config CASCADE;
DROP TABLE IF EXISTS app.subscription_plan_config CASCADE;
DROP FUNCTION IF EXISTS get_user_config CASCADE;

-- ---------- SECCIÓN 1: TEMAS VISUALES ----------

-- Tabla de Temas (públicamente accesible)
-- Define los estilos visuales disponibles para perfiles de Linktree
CREATE TABLE IF NOT EXISTS public.themes (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  name VARCHAR(50) NOT NULL,
  -- Colores principales
  background_color VARCHAR(20) CHECK (background_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  text_color VARCHAR(20) CHECK (text_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  button_color VARCHAR(20) CHECK (button_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  button_text_color VARCHAR(20) CHECK (button_text_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  -- Indicador de tema premium
  is_premium BOOLEAN DEFAULT FALSE,
  -- Configuraciones extendidas para chatbots LLM
  chat_bubble_user_color VARCHAR(20) CHECK (chat_bubble_user_color IS NULL OR chat_bubble_user_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  chat_bubble_bot_color VARCHAR(20) CHECK (chat_bubble_bot_color IS NULL OR chat_bubble_bot_color ~* '^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$'),
  chat_font_size VARCHAR(10) DEFAULT 'medium' CHECK (chat_font_size IN ('small', 'medium', 'large')),
  chat_animation_style VARCHAR(20) DEFAULT 'fade' CHECK (chat_animation_style IN ('fade', 'slide', 'bounce', 'none')),
  -- CSS personalizado para temas avanzados
  custom_css TEXT,
  -- Metadatos
  description TEXT,
  thumbnail_url TEXT CHECK (thumbnail_url IS NULL OR thumbnail_url ~* '^https?://[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_\+.~#?&//=]*)$'),
  -- Fechas
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Crear índice único en nombre de tema
CREATE UNIQUE INDEX idx_themes_name_unique ON public.themes(name);
-- Índices para búsqueda eficiente
CREATE INDEX idx_themes_premium ON public.themes(is_premium) WHERE is_premium = TRUE;
CREATE INDEX idx_themes_non_premium ON public.themes(is_premium) WHERE is_premium = FALSE;

-- Comentarios descriptivos para la tabla y columnas 
COMMENT ON TABLE public.themes IS 'Define los temas visuales disponibles para personalizar perfiles de Linktree y chats con bots';
COMMENT ON COLUMN public.themes.id IS 'Identificador único del tema';
COMMENT ON COLUMN public.themes.name IS 'Nombre visible del tema';
COMMENT ON COLUMN public.themes.background_color IS 'Color de fondo principal en formato hexadecimal';
COMMENT ON COLUMN public.themes.text_color IS 'Color de texto principal en formato hexadecimal';
COMMENT ON COLUMN public.themes.button_color IS 'Color de botones en formato hexadecimal';
COMMENT ON COLUMN public.themes.button_text_color IS 'Color de texto en botones en formato hexadecimal';
COMMENT ON COLUMN public.themes.is_premium IS 'Indica si es un tema premium disponible solo para suscriptores de pago';
COMMENT ON COLUMN public.themes.chat_bubble_user_color IS 'Color para las burbujas de chat del usuario';
COMMENT ON COLUMN public.themes.chat_bubble_bot_color IS 'Color para las burbujas de chat del bot';
COMMENT ON COLUMN public.themes.chat_font_size IS 'Tamaño de fuente para el chat (small, medium, large)';
COMMENT ON COLUMN public.themes.chat_animation_style IS 'Estilo de animación para la aparición de mensajes de chat';
COMMENT ON COLUMN public.themes.custom_css IS 'CSS personalizado para temas avanzados';
COMMENT ON COLUMN public.themes.description IS 'Descripción detallada del tema';
COMMENT ON COLUMN public.themes.thumbnail_url IS 'URL a una imagen de vista previa del tema';

-- ---------- SECCIÓN 2: USUARIOS ----------

-- Tabla de Usuarios (movida a esquema 'app')
-- Contiene la información principal de usuarios registrados
CREATE TABLE IF NOT EXISTS app.users (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  auth_id UUID UNIQUE NOT NULL,
  username VARCHAR(30) NOT NULL CHECK (username ~* '^[a-z0-9_\.]{3,30}$'),
  email TEXT NOT NULL CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+[.][A-Za-z]+$'),
  display_name VARCHAR(50),
  bio TEXT,
  avatar_url TEXT CHECK (avatar_url IS NULL OR avatar_url ~* '^https?://[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_\+.~#?&//=]*)$'),
  theme_id UUID REFERENCES public.themes(id) ON DELETE SET NULL,
  -- Información de acceso y seguridad
  last_login_at TIMESTAMP WITH TIME ZONE,
  password_changed_at TIMESTAMP WITH TIME ZONE,
  login_attempts INTEGER DEFAULT 0,
  locked_until TIMESTAMP WITH TIME ZONE,
  -- Configuración LLM personalizada
  default_llm_provider VARCHAR(30) DEFAULT 'openai' CHECK (default_llm_provider IN ('openai', 'anthropic', 'cohere', 'mistral', 'ollama', 'local')),
  default_model VARCHAR(50),
  default_temperature NUMERIC(3,2) DEFAULT 0.7 CHECK (default_temperature BETWEEN 0 AND 2),
  message_history_limit INTEGER DEFAULT 50 CHECK (message_history_limit BETWEEN 5 AND 1000),
  -- Estadísticas de uso
  total_bot_interactions INTEGER DEFAULT 0,
  last_bot_interaction_at TIMESTAMP WITH TIME ZONE,
  -- Campos para soft delete
  deleted_at TIMESTAMP WITH TIME ZONE,
  -- Fechas
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Crear índices únicos para usuarios con comprobación de eliminados
CREATE UNIQUE INDEX idx_users_username_unique ON app.users(username) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_users_email_unique ON app.users(email) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_users_auth_id_unique ON app.users(auth_id) WHERE deleted_at IS NULL;
-- Índices adicionales para búsquedas comunes
CREATE INDEX idx_users_theme ON app.users(theme_id);
CREATE INDEX idx_users_last_login ON app.users(last_login_at);
CREATE INDEX idx_users_llm_provider ON app.users(default_llm_provider);
CREATE INDEX idx_users_username_search ON app.users USING gin(username gin_trgm_ops) WHERE deleted_at IS NULL;

-- Comentarios descriptivos para la tabla y columnas
COMMENT ON TABLE app.users IS 'Almacena los datos principales de todos los usuarios del sistema';
COMMENT ON COLUMN app.users.id IS 'Identificador único del usuario en la aplicación';
COMMENT ON COLUMN app.users.auth_id IS 'Identificador del usuario en el sistema de autenticación';
COMMENT ON COLUMN app.users.username IS 'Nombre de usuario único (3-30 caracteres alfanuméricos, puntos y guiones bajos)';
COMMENT ON COLUMN app.users.email IS 'Dirección de correo electrónico del usuario';
COMMENT ON COLUMN app.users.display_name IS 'Nombre mostrado públicamente';
COMMENT ON COLUMN app.users.bio IS 'Biografía o descripción del usuario';
COMMENT ON COLUMN app.users.avatar_url IS 'URL a la imagen de perfil';
COMMENT ON COLUMN app.users.theme_id IS 'Tema visual seleccionado por el usuario';
COMMENT ON COLUMN app.users.last_login_at IS 'Fecha y hora del último inicio de sesión';
COMMENT ON COLUMN app.users.password_changed_at IS 'Fecha y hora del último cambio de contraseña';
COMMENT ON COLUMN app.users.login_attempts IS 'Contador de intentos fallidos de inicio de sesión';
COMMENT ON COLUMN app.users.locked_until IS 'Fecha hasta la que el usuario está bloqueado por intentos fallidos';
COMMENT ON COLUMN app.users.default_llm_provider IS 'Proveedor de LLM por defecto para los bots del usuario';
COMMENT ON COLUMN app.users.default_model IS 'Modelo de LLM por defecto para los bots del usuario';
COMMENT ON COLUMN app.users.default_temperature IS 'Temperatura por defecto para generación de contenido (0-2)';
COMMENT ON COLUMN app.users.message_history_limit IS 'Número máximo de mensajes a conservar en el historial por conversación';
COMMENT ON COLUMN app.users.total_bot_interactions IS 'Total de interacciones con bots LLM';
COMMENT ON COLUMN app.users.last_bot_interaction_at IS 'Fecha y hora de la última interacción con un bot';
COMMENT ON COLUMN app.users.deleted_at IS 'Fecha y hora de eliminación (soft delete)';
COMMENT ON COLUMN app.users.created_at IS 'Fecha y hora de creación del usuario';
COMMENT ON COLUMN app.users.updated_at IS 'Fecha y hora de última actualización';

-- ---------- SECCIÓN 3: CONFIGURACIÓN ESPECÍFICA DE USUARIO ----------

-- Verificar si la tabla system_config existe antes de crear user_config
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'app' AND table_name = 'system_config') THEN
    RAISE EXCEPTION 'La tabla app.system_config no existe. Ejecute primero init_1.sql';
  END IF;
END $$;

-- Tabla de configuración específica por usuario (movida a esquema 'app')
-- Permite sobrescribir valores de configuración global para usuarios específicos
CREATE TABLE IF NOT EXISTS app.user_config (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  config_key TEXT NOT NULL REFERENCES app.system_config(key) ON DELETE CASCADE,
  value TEXT NOT NULL,
  override_reason TEXT,
  created_by UUID REFERENCES app.users(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(user_id, config_key)
);

-- Índices para búsquedas eficientes
CREATE INDEX idx_user_config_user ON app.user_config(user_id);
CREATE INDEX idx_user_config_key ON app.user_config(config_key);
CREATE INDEX idx_user_config_created_by ON app.user_config(created_by);

-- Comentarios descriptivos
COMMENT ON TABLE app.user_config IS 'Almacena configuraciones específicas por usuario que sobrescriben la configuración global o por plan';
COMMENT ON COLUMN app.user_config.id IS 'Identificador único de la configuración';
COMMENT ON COLUMN app.user_config.user_id IS 'Usuario al que aplica la configuración';
COMMENT ON COLUMN app.user_config.config_key IS 'Clave de configuración (referencia a system_config)';
COMMENT ON COLUMN app.user_config.value IS 'Valor específico de la configuración para este usuario';
COMMENT ON COLUMN app.user_config.override_reason IS 'Razón por la que se sobrescribió el valor predeterminado';
COMMENT ON COLUMN app.user_config.created_by IS 'Usuario (generalmente admin) que creó la configuración';

-- Tabla de configuración según plan de suscripción (movida a esquema 'app')
-- Define valores por defecto para cada tipo de plan de suscripción
CREATE TABLE IF NOT EXISTS app.subscription_plan_config (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  plan_type VARCHAR(20) NOT NULL CHECK (plan_type IN ('free', 'basic', 'premium', 'enterprise')),
  config_key TEXT NOT NULL REFERENCES app.system_config(key) ON DELETE CASCADE,
  value TEXT NOT NULL,
  description TEXT, -- Agregado para documentar el propósito de esta configuración
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(plan_type, config_key)
);

-- Índices para búsquedas eficientes
CREATE INDEX idx_sub_plan_config_plan ON app.subscription_plan_config(plan_type);
CREATE INDEX idx_sub_plan_config_key ON app.subscription_plan_config(config_key);

-- Comentarios descriptivos
COMMENT ON TABLE app.subscription_plan_config IS 'Define los valores predeterminados de configuración según el tipo de plan de suscripción';
COMMENT ON COLUMN app.subscription_plan_config.id IS 'Identificador único de la configuración';
COMMENT ON COLUMN app.subscription_plan_config.plan_type IS 'Tipo de plan (free, basic, premium, enterprise)';
COMMENT ON COLUMN app.subscription_plan_config.config_key IS 'Clave de configuración (referencia a system_config)';
COMMENT ON COLUMN app.subscription_plan_config.value IS 'Valor por defecto para el plan especificado';
COMMENT ON COLUMN app.subscription_plan_config.description IS 'Explicación del propósito y efecto de esta configuración para este plan';

-- ---------- SECCIÓN 4: DATOS INICIALES ----------

-- Insertar temas predefinidos con mejor validación
INSERT INTO public.themes (
  name, 
  background_color, 
  text_color, 
  button_color, 
  button_text_color, 
  chat_bubble_user_color,
  chat_bubble_bot_color,
  is_premium,
  description
) VALUES
  ('Default', '#FFFFFF', '#000000', '#0366d6', '#FFFFFF', '#E1F5FE', '#F5F5F5', FALSE, 'Tema clásico con fondo blanco y botones azules'),
  ('Dark', '#121212', '#FFFFFF', '#BB86FC', '#000000', '#424242', '#212121', FALSE, 'Tema oscuro con acentos púrpura, ideal para uso nocturno'),
  ('Sunset', '#FFC0CB', '#800080', '#FF69B4', '#FFFFFF', '#FFD180', '#FFECB3', FALSE, 'Tema cálido con colores de atardecer'),
  ('Forest', '#228B22', '#F5F5F5', '#006400', '#F5F5F5', '#81C784', '#C8E6C9', FALSE, 'Tema inspirado en tonos de bosque y naturaleza'),
  ('Ocean', '#1E90FF', '#F5F5F5', '#0000CD', '#F5F5F5', '#B3E5FC', '#E1F5FE', FALSE, 'Tema de tonos azules oceánicos'),
  ('Minimal', '#F5F5F5', '#333333', '#555555', '#FFFFFF', '#EEEEEE', '#F5F5F5', FALSE, 'Diseño minimalista con colores neutros'),
  ('Vibrant', '#FFD700', '#800080', '#FF4500', '#FFFFFF', '#F44336', '#FF9800', TRUE, 'Colores vibrantes y llamativos premium'),
  ('Pastel', '#E6E6FA', '#483D8B', '#DDA0DD', '#483D8B', '#B2DFDB', '#DCEDC8', TRUE, 'Suaves tonos pastel premium'),
  ('Corporate', '#F8F9FA', '#212529', '#0D6EFD', '#FFFFFF', '#E3F2FD', '#F1F8E9', TRUE, 'Estilo profesional para perfiles empresariales'),
  ('Elegant', '#2C3E50', '#ECF0F1', '#16A085', '#FFFFFF', '#26A69A', '#80CBC4', TRUE, 'Diseño elegante con tonos sofisticados'),
  ('Neon', '#000000', '#00FF00', '#FF00FF', '#000000', '#00E676', '#FF80AB', TRUE, 'Colores neón vibrantes sobre fondo negro'),
  ('Retro', '#FFD700', '#8B4513', '#FF6347', '#FFFFFF', '#FFCC80', '#FFAB91', TRUE, 'Inspirado en estética retro de los 80s'),
  ('AI Chat', '#343541', '#FFFFFF', '#10A37F', '#FFFFFF', '#444654', '#10A37F', TRUE, 'Inspirado en interfaces de chat AI modernas')
ON CONFLICT (name) 
DO UPDATE SET 
  background_color = EXCLUDED.background_color,
  text_color = EXCLUDED.text_color,
  button_color = EXCLUDED.button_color,
  button_text_color = EXCLUDED.button_text_color,
  chat_bubble_user_color = EXCLUDED.chat_bubble_user_color,
  chat_bubble_bot_color = EXCLUDED.chat_bubble_bot_color,
  is_premium = EXCLUDED.is_premium,
  description = EXCLUDED.description,
  updated_at = NOW();

-- Verificar y configurar los planes sólo si system_config existe
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'app' AND table_name = 'system_config') THEN
    -- Configuración inicial por tipo de suscripción
    INSERT INTO app.subscription_plan_config (plan_type, config_key, value, description)
    VALUES
      -- Plan Gratuito
      ('free', 'default_user_quota_bots', '1', 'Número máximo de bots para usuarios gratuitos'),
      ('free', 'default_user_quota_collections', '3', 'Número máximo de colecciones de documentos para usuarios gratuitos'),
      ('free', 'default_user_quota_documents', '50', 'Número máximo de documentos para usuarios gratuitos'),
      ('free', 'default_user_quota_vector_searches', '100', 'Búsquedas vectoriales diarias para usuarios gratuitos'),
      ('free', 'user_enable_advanced_analytics', 'false', 'Los usuarios gratuitos no tienen acceso a analytics avanzados'),
      ('free', 'user_custom_bot_model', 'gpt-3.5-turbo', 'Modelo predeterminado para usuarios gratuitos'),
      ('free', 'user_rate_limit', '30', 'Límite de peticiones por minuto para usuarios gratuitos'),
      ('free', 'user_max_token_length', '2048', 'Longitud máxima de tokens para peticiones de usuarios gratuitos'),
      ('free', 'user_max_conversation_length', '10', 'Máximo de conversaciones guardadas para usuarios gratuitos'),
      ('free', 'user_max_message_length', '1000', 'Longitud máxima de mensajes para usuarios gratuitos'),
      
      -- Plan Básico
      ('basic', 'default_user_quota_bots', '3', 'Número máximo de bots para usuarios básicos'),
      ('basic', 'default_user_quota_collections', '5', 'Número máximo de colecciones para usuarios básicos'),
      ('basic', 'default_user_quota_documents', '100', 'Número máximo de documentos para usuarios básicos'),
      ('basic', 'default_user_quota_vector_searches', '500', 'Búsquedas vectoriales diarias para usuarios básicos'),
      ('basic', 'user_enable_advanced_analytics', 'true', 'Los usuarios básicos tienen acceso a analytics avanzados'),
      ('basic', 'user_custom_bot_model', 'gpt-3.5-turbo', 'Modelo predeterminado para usuarios básicos'),
      ('basic', 'user_rate_limit', '60', 'Límite de peticiones por minuto para usuarios básicos'),
      ('basic', 'user_max_token_length', '4096', 'Longitud máxima de tokens para peticiones de usuarios básicos'),
      ('basic', 'user_max_conversation_length', '50', 'Máximo de conversaciones guardadas para usuarios básicos'),
      ('basic', 'user_max_message_length', '2000', 'Longitud máxima de mensajes para usuarios básicos'),
      
      -- Plan Premium
      ('premium', 'default_user_quota_bots', '5', 'Número máximo de bots para usuarios premium'),
      ('premium', 'default_user_quota_collections', '10', 'Número máximo de colecciones para usuarios premium'),
      ('premium', 'default_user_quota_documents', '200', 'Número máximo de documentos para usuarios premium'),
      ('premium', 'default_user_quota_vector_searches', '1000', 'Búsquedas vectoriales diarias para usuarios premium'),
      ('premium', 'user_enable_advanced_analytics', 'true', 'Los usuarios premium tienen acceso a analytics avanzados'),
      ('premium', 'user_custom_bot_model', 'gpt-4', 'Modelo predeterminado para usuarios premium'),
      ('premium', 'user_rate_limit', '120', 'Límite de peticiones por minuto para usuarios premium'),
      ('premium', 'user_max_token_length', '8192', 'Longitud máxima de tokens para peticiones de usuarios premium'),
      ('premium', 'user_max_conversation_length', '500', 'Máximo de conversaciones guardadas para usuarios premium'),
      ('premium', 'user_max_message_length', '4000', 'Longitud máxima de mensajes para usuarios premium'),
      
      -- Plan Enterprise
      ('enterprise', 'default_user_quota_bots', '20', 'Número máximo de bots para usuarios enterprise'),
      ('enterprise', 'default_user_quota_collections', '50', 'Número máximo de colecciones para usuarios enterprise'),
      ('enterprise', 'default_user_quota_documents', '1000', 'Número máximo de documentos para usuarios enterprise'),
      ('enterprise', 'default_user_quota_vector_searches', '5000', 'Búsquedas vectoriales diarias para usuarios enterprise'),
      ('enterprise', 'user_enable_advanced_analytics', 'true', 'Los usuarios enterprise tienen acceso a analytics avanzados'),
      ('enterprise', 'user_custom_bot_model', 'gpt-4', 'Modelo predeterminado para usuarios enterprise'),
      ('enterprise', 'user_rate_limit', '300', 'Límite de peticiones por minuto para usuarios enterprise'),
      ('enterprise', 'user_max_token_length', '16384', 'Longitud máxima de tokens para peticiones de usuarios enterprise'),
      ('enterprise', 'user_max_conversation_length', 'unlimited', 'Sin límite de conversaciones guardadas para usuarios enterprise'),
      ('enterprise', 'user_max_message_length', '8000', 'Longitud máxima de mensajes para usuarios enterprise')
    ON CONFLICT (plan_type, config_key) 
    DO UPDATE SET 
      value = EXCLUDED.value,
      description = EXCLUDED.description,
      updated_at = NOW();
  ELSE
    RAISE WARNING 'No se pudo insertar la configuración de planes porque app.system_config no existe. Ejecute init_1.sql primero.';
  END IF;
END $$;

-- ---------- SECCIÓN 5: FUNCIONES DE COMPATIBILIDAD ----------

-- Estas vistas se crean solo para mantener compatibilidad con código existente
CREATE OR REPLACE VIEW users AS 
  SELECT * FROM app.users;

CREATE OR REPLACE VIEW user_config AS 
  SELECT * FROM app.user_config;

CREATE OR REPLACE VIEW subscription_plan_config AS 
  SELECT * FROM app.subscription_plan_config;

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  RAISE NOTICE 'Tablas fundamentales creadas correctamente.';
  RAISE NOTICE 'Tablas públicas: themes';
  RAISE NOTICE 'Tablas internas: app.users, app.user_config, app.subscription_plan_config';
  RAISE NOTICE 'Vistas de compatibilidad creadas para facilitar la migración.';
END $$;