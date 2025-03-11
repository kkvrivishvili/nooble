-- ==============================================
-- ARCHIVO: init_3.sql - Tablas Dependientes de Users
-- ==============================================
-- Propósito: Crear tablas que dependen de la tabla users, como perfiles (públicos), 
-- roles de usuario (permisos), historial de cambios de roles, suscripciones y 
-- su historial. Se implementa además la lógica para la creación automática de 
-- usuarios cuando se registran en el sistema de autenticación.
--
-- Reorganización de esquemas:
-- - profiles: Permanece en esquema 'public' por ser accesible públicamente
-- - user_roles, user_role_history: Movidas a esquema 'app' (gestión de permisos interna)
-- - subscriptions, subscription_history: Movidas a esquema 'app' (gestión financiera interna)
--
-- Los perfiles contienen información pública mostrada a visitantes.
-- Las demás tablas contienen información sensible de permisos, roles y pagos.
-- ==============================================

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS profiles CASCADE;
DROP TABLE IF EXISTS public.profiles CASCADE;
DROP TABLE IF EXISTS user_roles CASCADE;
DROP TABLE IF EXISTS app.user_roles CASCADE;
DROP TABLE IF EXISTS subscriptions CASCADE;
DROP TABLE IF EXISTS app.subscriptions CASCADE;
DROP TABLE IF EXISTS user_role_history CASCADE;
DROP TABLE IF EXISTS app.user_role_history CASCADE;
DROP TABLE IF EXISTS subscription_history CASCADE;
DROP TABLE IF EXISTS app.subscription_history CASCADE;

-- Eliminar funciones relacionadas
DROP FUNCTION IF EXISTS sync_user_config_on_subscription_change CASCADE;
DROP FUNCTION IF EXISTS generate_unique_username CASCADE;
DROP FUNCTION IF EXISTS handle_new_user CASCADE;

-- ---------- SECCIÓN 1: PERFILES DE USUARIO ----------

-- Tabla de Perfiles mejorada (públicamente accesible)
-- Contiene información para mostrar en la página pública tipo Linktree
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES app.users(id) ON DELETE CASCADE,
  -- Redes sociales con validación básica
  social_twitter TEXT CHECK (social_twitter IS NULL OR social_twitter ~* '^@?[A-Za-z0-9_]{1,15}$'),
  social_instagram TEXT CHECK (social_instagram IS NULL OR social_instagram ~* '^[A-Za-z0-9._]{1,30}$'),
  social_tiktok TEXT CHECK (social_tiktok IS NULL OR social_tiktok ~* '^@?[A-Za-z0-9_\.]{1,24}$'),
  social_linkedin TEXT CHECK (social_linkedin IS NULL OR social_linkedin ~* '^[A-Za-z0-9\-]{5,100}$'),
  social_github TEXT CHECK (social_github IS NULL OR social_github ~* '^[A-Za-z0-9\-]{1,39}$'),
  -- Información general
  location TEXT,
  website TEXT CHECK (website IS NULL OR website ~* '^https?://.*$'),
  allow_sensitive_content BOOLEAN DEFAULT FALSE,
  is_verified BOOLEAN DEFAULT FALSE,
  view_count INTEGER DEFAULT 0,
  -- Metadatos SEO
  meta_title TEXT,
  meta_description TEXT,
  meta_keywords TEXT,
  -- Personalización
  custom_css TEXT,
  custom_domain TEXT CHECK (custom_domain IS NULL OR custom_domain ~* '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'),
  custom_js TEXT,
  -- Analíticas y compliance
  google_analytics_id TEXT,
  enable_cookie_consent BOOLEAN DEFAULT TRUE,
  -- Configuración de chatbot público
  enable_public_chat BOOLEAN DEFAULT FALSE,
  chat_welcome_message TEXT,
  chat_placeholder_text TEXT,
  chat_position VARCHAR(20) DEFAULT 'bottom-right' CHECK (chat_position IN ('bottom-right', 'bottom-left', 'top-right', 'top-left', 'center')),
  chat_theme_override_id UUID REFERENCES public.themes(id) ON DELETE SET NULL,
  chat_avatar_url TEXT CHECK (chat_avatar_url IS NULL OR chat_avatar_url ~* '^https?://.*$'),
  chat_max_messages INTEGER DEFAULT 50 CHECK (chat_max_messages BETWEEN 5 AND 1000),
  -- Timestamps
  last_visited_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Crear índice único para dominio personalizado
CREATE UNIQUE INDEX idx_profiles_custom_domain ON public.profiles(custom_domain) WHERE custom_domain IS NOT NULL;
-- Índices adicionales para búsquedas comunes
CREATE INDEX idx_profiles_verified ON public.profiles(is_verified) WHERE is_verified = TRUE;
CREATE INDEX idx_profiles_public_chat ON public.profiles(enable_public_chat) WHERE enable_public_chat = TRUE;
CREATE INDEX idx_profiles_social_handles ON public.profiles USING gin(
  to_tsvector('english', COALESCE(social_twitter, '') || ' ' || 
                        COALESCE(social_instagram, '') || ' ' || 
                        COALESCE(social_tiktok, '') || ' ' ||
                        COALESCE(social_linkedin, '') || ' ' ||
                        COALESCE(social_github, ''))
);

-- Comentarios descriptivos
COMMENT ON TABLE public.profiles IS 'Almacena información pública del perfil de usuario mostrada en su página de Linktree';
COMMENT ON COLUMN public.profiles.id IS 'ID del usuario (mismo que en tabla users)';
COMMENT ON COLUMN public.profiles.social_twitter IS 'Handle de Twitter (sin @)';
COMMENT ON COLUMN public.profiles.social_instagram IS 'Nombre de usuario de Instagram';
COMMENT ON COLUMN public.profiles.social_tiktok IS 'Nombre de usuario de TikTok';
COMMENT ON COLUMN public.profiles.social_linkedin IS 'ID de perfil de LinkedIn';
COMMENT ON COLUMN public.profiles.social_github IS 'Nombre de usuario de GitHub';
COMMENT ON COLUMN public.profiles.location IS 'Ubicación geográfica del usuario';
COMMENT ON COLUMN public.profiles.website IS 'Sitio web personal o profesional';
COMMENT ON COLUMN public.profiles.allow_sensitive_content IS 'Permite contenido sensible en el perfil';
COMMENT ON COLUMN public.profiles.is_verified IS 'Indica si el perfil está verificado oficialmente';
COMMENT ON COLUMN public.profiles.view_count IS 'Contador de visitas al perfil';
COMMENT ON COLUMN public.profiles.meta_title IS 'Título para SEO';
COMMENT ON COLUMN public.profiles.meta_description IS 'Descripción para SEO';
COMMENT ON COLUMN public.profiles.meta_keywords IS 'Palabras clave para SEO';
COMMENT ON COLUMN public.profiles.custom_css IS 'CSS personalizado para el perfil';
COMMENT ON COLUMN public.profiles.custom_domain IS 'Dominio personalizado (ej: midominio.com)';
COMMENT ON COLUMN public.profiles.custom_js IS 'JavaScript personalizado para el perfil';
COMMENT ON COLUMN public.profiles.google_analytics_id IS 'ID de Google Analytics';
COMMENT ON COLUMN public.profiles.enable_cookie_consent IS 'Mostrar banner de consentimiento de cookies';
COMMENT ON COLUMN public.profiles.enable_public_chat IS 'Habilitar chatbot público en el perfil';
COMMENT ON COLUMN public.profiles.chat_welcome_message IS 'Mensaje inicial del chatbot';
COMMENT ON COLUMN public.profiles.chat_placeholder_text IS 'Texto de placeholder en campo de entrada del chat';
COMMENT ON COLUMN public.profiles.chat_position IS 'Posición del chatbot en la pantalla';
COMMENT ON COLUMN public.profiles.chat_theme_override_id IS 'Tema visual específico para el chat (anula el tema global)';
COMMENT ON COLUMN public.profiles.chat_avatar_url IS 'URL de avatar personalizado para el chatbot';
COMMENT ON COLUMN public.profiles.chat_max_messages IS 'Número máximo de mensajes a mostrar en el chat';
COMMENT ON COLUMN public.profiles.last_visited_at IS 'Última vez que el usuario visitó su propio perfil';

-- ---------- SECCIÓN 2: ROLES Y PERMISOS DE USUARIO ----------

-- Tabla mejorada de roles de usuario (interna)
CREATE TABLE IF NOT EXISTS app.user_roles (
  user_id UUID PRIMARY KEY REFERENCES app.users(id) ON DELETE CASCADE,
  role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'admin', 'moderator', 'support', 'developer')),
  permissions JSONB DEFAULT '{
    "manage_own_profile": true,
    "create_links": true,
    "create_bots": true,
    "view_own_analytics": true,
    "invite_users": false,
    "manage_users": false,
    "manage_subscriptions": false,
    "view_system_logs": false,
    "manage_system_config": false
  }',
  granted_by UUID REFERENCES app.users(id) ON DELETE SET NULL,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para búsquedas eficientes
CREATE INDEX idx_user_roles_role ON app.user_roles(role);
CREATE INDEX idx_user_roles_granted_by ON app.user_roles(granted_by);

-- Comentarios descriptivos
COMMENT ON TABLE app.user_roles IS 'Almacena los roles y permisos específicos de cada usuario';
COMMENT ON COLUMN app.user_roles.user_id IS 'ID del usuario';
COMMENT ON COLUMN app.user_roles.role IS 'Rol principal del usuario (user, admin, moderator, support, developer)';
COMMENT ON COLUMN app.user_roles.permissions IS 'Permisos específicos configurables en formato JSON';
COMMENT ON COLUMN app.user_roles.granted_by IS 'Usuario que concedió este rol';
COMMENT ON COLUMN app.user_roles.notes IS 'Notas adicionales sobre la asignación del rol';

-- Tabla de historial de roles (interna)
CREATE TABLE IF NOT EXISTS app.user_role_history (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  previous_role VARCHAR(20) CHECK (previous_role IN ('user', 'admin', 'moderator', 'support', 'developer')),
  new_role VARCHAR(20) CHECK (new_role IN ('user', 'admin', 'moderator', 'support', 'developer')),
  changed_by UUID REFERENCES app.users(id) ON DELETE SET NULL,
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para búsquedas eficientes
CREATE INDEX idx_user_role_history_user ON app.user_role_history(user_id);
CREATE INDEX idx_user_role_history_changed_by ON app.user_role_history(changed_by);
CREATE INDEX idx_user_role_history_created_at ON app.user_role_history(created_at DESC);

-- Comentarios descriptivos
COMMENT ON TABLE app.user_role_history IS 'Registro histórico de cambios en roles de usuario para auditoría';
COMMENT ON COLUMN app.user_role_history.id IS 'ID único del registro histórico';
COMMENT ON COLUMN app.user_role_history.user_id IS 'Usuario cuyo rol fue modificado';
COMMENT ON COLUMN app.user_role_history.previous_role IS 'Rol anterior';
COMMENT ON COLUMN app.user_role_history.new_role IS 'Nuevo rol asignado';
COMMENT ON COLUMN app.user_role_history.changed_by IS 'Usuario que realizó el cambio';
COMMENT ON COLUMN app.user_role_history.reason IS 'Motivo del cambio de rol';

-- ---------- SECCIÓN 3: SUSCRIPCIONES Y PAGOS ----------

-- Tabla mejorada de Suscripciones (interna)
CREATE TABLE IF NOT EXISTS app.subscriptions (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  plan_type VARCHAR(20) NOT NULL CHECK (plan_type IN ('free', 'basic', 'premium', 'enterprise')),
  status VARCHAR(20) NOT NULL CHECK (status IN ('active', 'canceled', 'expired', 'trial', 'pending')),
  current_period_start TIMESTAMP WITH TIME ZONE NOT NULL,
  current_period_end TIMESTAMP WITH TIME ZONE NOT NULL,
  cancellation_date TIMESTAMP WITH TIME ZONE,
  trial_end TIMESTAMP WITH TIME ZONE,
  payment_provider VARCHAR(20),
  payment_reference TEXT,
  recurring_amount DECIMAL(10,2),
  currency VARCHAR(3) DEFAULT 'USD',
  billing_email TEXT,
  -- Nuevos campos para LLM
  llm_tokens_included INTEGER, -- Tokens incluidos en el plan
  llm_tokens_used INTEGER DEFAULT 0, -- Tokens consumidos en el período actual
  llm_tokens_reset_date TIMESTAMP WITH TIME ZONE, -- Fecha de reinicio del contador de tokens
  llm_max_embedding_dimensions INTEGER, -- Máxima dimensión de embeddings permitida
  llm_available_models JSONB, -- Modelos disponibles para este plan
  -- Metadatos
  meta_data JSONB DEFAULT '{}',
  auto_renew BOOLEAN DEFAULT TRUE,
  discount_code TEXT,
  discount_percent INTEGER,
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT subscription_period_check CHECK (current_period_end > current_period_start)
);

-- Crear índice para usuarios activos
CREATE UNIQUE INDEX idx_active_subscriptions ON app.subscriptions(user_id) 
WHERE status = 'active';
-- Índices adicionales para búsquedas comunes
CREATE INDEX idx_subscriptions_status ON app.subscriptions(status, current_period_end);
CREATE INDEX idx_subscriptions_expiring ON app.subscriptions(current_period_end) 
  WHERE status = 'active' AND auto_renew = FALSE;
CREATE INDEX idx_subscriptions_plan_type ON app.subscriptions(plan_type, status);
CREATE INDEX idx_subscriptions_tokens_running_out ON app.subscriptions(llm_tokens_used, llm_tokens_included)
  WHERE llm_tokens_used > (llm_tokens_included * 0.8);

-- Comentarios descriptivos
COMMENT ON TABLE app.subscriptions IS 'Almacena información de suscripciones y pagos de los usuarios';
COMMENT ON COLUMN app.subscriptions.id IS 'ID único de la suscripción';
COMMENT ON COLUMN app.subscriptions.user_id IS 'Usuario al que pertenece la suscripción';
COMMENT ON COLUMN app.subscriptions.plan_type IS 'Tipo de plan contratado';
COMMENT ON COLUMN app.subscriptions.status IS 'Estado actual de la suscripción';
COMMENT ON COLUMN app.subscriptions.current_period_start IS 'Inicio del período de facturación actual';
COMMENT ON COLUMN app.subscriptions.current_period_end IS 'Fin del período de facturación actual';
COMMENT ON COLUMN app.subscriptions.cancellation_date IS 'Fecha en que se canceló la suscripción';
COMMENT ON COLUMN app.subscriptions.trial_end IS 'Fecha de finalización del período de prueba';
COMMENT ON COLUMN app.subscriptions.payment_provider IS 'Proveedor de pagos (Stripe, PayPal, etc.)';
COMMENT ON COLUMN app.subscriptions.payment_reference IS 'Referencia o ID de pago en el proveedor';
COMMENT ON COLUMN app.subscriptions.recurring_amount IS 'Importe recurrente a cobrar';
COMMENT ON COLUMN app.subscriptions.currency IS 'Moneda de cobro (USD, EUR, etc.)';
COMMENT ON COLUMN app.subscriptions.billing_email IS 'Email para facturación';
COMMENT ON COLUMN app.subscriptions.llm_tokens_included IS 'Tokens LLM incluidos en el plan';
COMMENT ON COLUMN app.subscriptions.llm_tokens_used IS 'Tokens LLM consumidos en el período actual';
COMMENT ON COLUMN app.subscriptions.llm_tokens_reset_date IS 'Fecha de reinicio del contador de tokens';
COMMENT ON COLUMN app.subscriptions.llm_max_embedding_dimensions IS 'Dimensiones de embedding permitidas';
COMMENT ON COLUMN app.subscriptions.llm_available_models IS 'Modelos LLM disponibles para este plan';
COMMENT ON COLUMN app.subscriptions.meta_data IS 'Metadatos adicionales de la suscripción';
COMMENT ON COLUMN app.subscriptions.auto_renew IS 'Indica si la suscripción se renueva automáticamente';
COMMENT ON COLUMN app.subscriptions.discount_code IS 'Código de descuento aplicado';
COMMENT ON COLUMN app.subscriptions.discount_percent IS 'Porcentaje de descuento aplicado';

-- Tabla de historial de suscripciones (interna)
CREATE TABLE IF NOT EXISTS app.subscription_history (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  subscription_id UUID NOT NULL REFERENCES app.subscriptions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  previous_plan VARCHAR(20) CHECK (previous_plan IN ('free', 'basic', 'premium', 'enterprise')),
  new_plan VARCHAR(20) CHECK (new_plan IN ('free', 'basic', 'premium', 'enterprise')),
  previous_status VARCHAR(20) CHECK (previous_status IN ('active', 'canceled', 'expired', 'trial', 'pending')),
  new_status VARCHAR(20) CHECK (new_status IN ('active', 'canceled', 'expired', 'trial', 'pending')),
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_by UUID REFERENCES app.users(id) ON DELETE SET NULL
);

-- Índices para búsquedas eficientes
CREATE INDEX idx_subscription_history_user ON app.subscription_history(user_id);
CREATE INDEX idx_subscription_history_subscription ON app.subscription_history(subscription_id);
CREATE INDEX idx_subscription_history_created_at ON app.subscription_history(created_at DESC);

-- Comentarios descriptivos
COMMENT ON TABLE app.subscription_history IS 'Registro histórico de cambios en suscripciones para auditoría';
COMMENT ON COLUMN app.subscription_history.id IS 'ID único del registro histórico';
COMMENT ON COLUMN app.subscription_history.subscription_id IS 'ID de la suscripción modificada';
COMMENT ON COLUMN app.subscription_history.user_id IS 'Usuario cuya suscripción fue modificada';
COMMENT ON COLUMN app.subscription_history.previous_plan IS 'Plan anterior';
COMMENT ON COLUMN app.subscription_history.new_plan IS 'Nuevo plan';
COMMENT ON COLUMN app.subscription_history.previous_status IS 'Estado anterior';
COMMENT ON COLUMN app.subscription_history.new_status IS 'Nuevo estado';
COMMENT ON COLUMN app.subscription_history.reason IS 'Motivo del cambio';
COMMENT ON COLUMN app.subscription_history.created_by IS 'Usuario que realizó el cambio';

-- ---------- SECCIÓN 4: TRIGGERS Y FUNCIONES ----------

-- Trigger para sincronizar configuración al cambiar suscripción
CREATE OR REPLACE FUNCTION sync_user_config_on_subscription_change()
RETURNS TRIGGER AS $$
DECLARE
  v_bot_enabled BOOLEAN;
BEGIN
  -- Registrar cambio en el historial si es relevante
  IF (NEW.plan_type != OLD.plan_type OR NEW.status != OLD.status) THEN
    INSERT INTO app.subscription_history (
      subscription_id, user_id, previous_plan, new_plan, 
      previous_status, new_status, reason
    ) VALUES (
      NEW.id, NEW.user_id, OLD.plan_type, NEW.plan_type, 
      OLD.status, NEW.status, 
      CASE 
        WHEN NEW.status = 'expired' THEN 'Suscripción expirada automáticamente'
        WHEN NEW.status = 'canceled' THEN 'Cancelada por el usuario'
        WHEN OLD.plan_type != NEW.plan_type THEN 'Cambio de plan'
        ELSE 'Actualización de estado'
      END
    );
  END IF;

  -- Si hay cambio de plan o cambio de estado a activo desde otro estado
  IF (NEW.plan_type != OLD.plan_type OR
      (OLD.status != 'active' AND NEW.status = 'active')) THEN
    
    -- Si el plan es activo, sincronizar configuraciones
    IF NEW.status = 'active' THEN
      -- Insertar configuraciones de nuevo plan que no existan
      INSERT INTO app.user_config (user_id, config_key, value, override_reason)
      SELECT 
        NEW.user_id, 
        spc.config_key, 
        spc.value, 
        'Auto-configurado por cambio de plan a ' || NEW.plan_type
      FROM app.subscription_plan_config spc
      WHERE spc.plan_type = NEW.plan_type
      ON CONFLICT (user_id, config_key) DO NOTHING;
      
      -- Verificar si el plan actual permite chatbots públicos
      SELECT (value = 'true') INTO v_bot_enabled
      FROM app.subscription_plan_config 
      WHERE plan_type = NEW.plan_type AND config_key = 'enable_public_chat';
      
      -- Actualizar perfil con la nueva configuración de chatbot
      IF v_bot_enabled IS NOT NULL THEN
        UPDATE public.profiles
        SET enable_public_chat = v_bot_enabled
        WHERE id = NEW.user_id;
      END IF;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Crear trigger
DROP TRIGGER IF EXISTS sync_config_on_subscription_change ON app.subscriptions;
CREATE TRIGGER sync_config_on_subscription_change
AFTER UPDATE ON app.subscriptions
FOR EACH ROW
WHEN (NEW.plan_type != OLD.plan_type OR NEW.status != OLD.status)
EXECUTE PROCEDURE sync_user_config_on_subscription_change();

-- Trigger para historial de roles de usuario
CREATE OR REPLACE FUNCTION track_role_changes()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND OLD.role != NEW.role) THEN
    INSERT INTO app.user_role_history (
      user_id, previous_role, new_role, 
      changed_by, reason
    ) VALUES (
      NEW.user_id, OLD.role, NEW.role, 
      NEW.granted_by, NEW.notes
    );
  ELSIF (TG_OP = 'INSERT') THEN
    INSERT INTO app.user_role_history (
      user_id, previous_role, new_role, 
      changed_by, reason
    ) VALUES (
      NEW.user_id, NULL, NEW.role, 
      NEW.granted_by, NEW.notes
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Crear trigger para seguimiento de cambios en roles
DROP TRIGGER IF EXISTS track_user_role_changes ON app.user_roles;
CREATE TRIGGER track_user_role_changes
AFTER INSERT OR UPDATE ON app.user_roles
FOR EACH ROW
EXECUTE PROCEDURE track_role_changes();

-- ---------- SECCIÓN 5: AUTOMATIZACIÓN DE USUARIOS ----------

-- Función para generar un username único basado en el email
CREATE OR REPLACE FUNCTION generate_unique_username(p_email TEXT) 
RETURNS TEXT AS $$
DECLARE
  base_username TEXT;
  candidate_username TEXT;
  username_exists BOOLEAN;
  counter INTEGER := 0;
BEGIN
  -- Extraer la parte antes del @ como base para el username
  base_username := split_part(p_email, '@', 1);
  
  -- Reemplazar caracteres no permitidos y limitar longitud
  base_username := regexp_replace(base_username, '[^a-z0-9_\.]', '', 'gi');
  base_username := substring(base_username, 1, 20);
  
  -- Verificar si ya existe
  candidate_username := base_username;
  
  LOOP
    -- Comprobar si el username ya existe
    SELECT EXISTS (
      SELECT 1 FROM app.users WHERE username = candidate_username
    ) INTO username_exists;
    
    -- Si no existe o hemos intentado demasiadas veces, salir del bucle
    EXIT WHEN NOT username_exists OR counter > 100;
    
    -- Incrementar contador y generar nuevo candidato
    counter := counter + 1;
    candidate_username := base_username || counter;
  END LOOP;
  
  -- Si después de 100 intentos sigue existiendo, usar un UUID parcial
  IF username_exists THEN
    candidate_username := base_username || '_' || substr(extensions.uuid_generate_v4()::text, 1, 8);
  END IF;
  
  RETURN candidate_username;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función para manejar nuevos usuarios cuando se registran en auth
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER SECURITY DEFINER AS $$
DECLARE
  default_theme_id UUID;
  user_id UUID;
  username_from_meta TEXT;
  display_name_from_meta TEXT;
  generated_username TEXT;
  current_date TIMESTAMP WITH TIME ZONE := NOW();
  period_end TIMESTAMP WITH TIME ZONE;
BEGIN
  -- Obtener ID de tema por defecto (usamos el primero, normalmente 'Default')
  SELECT id INTO default_theme_id FROM public.themes WHERE name = 'Default';
  IF default_theme_id IS NULL THEN
    SELECT id INTO default_theme_id FROM public.themes LIMIT 1;
  END IF;
  
  -- Extraer información de metadatos si están disponibles
  username_from_meta := NEW.raw_user_meta_data->>'username';
  display_name_from_meta := NEW.raw_user_meta_data->>'display_name';
  
  -- Generar un username único si no se proporcionó uno
  IF username_from_meta IS NULL OR trim(username_from_meta) = '' THEN
    generated_username := generate_unique_username(NEW.email);
  ELSE
    -- Validar y limpiar el username proporcionado
    IF username_from_meta ~* '^[a-z0-9_\.]{3,30}$' THEN
      generated_username := username_from_meta;
    ELSE
      -- Si no cumple con el formato, generar uno basado en el email
      generated_username := generate_unique_username(NEW.email);
    END IF;
    
    -- Verificar si ya existe
    IF EXISTS (SELECT 1 FROM app.users WHERE username = generated_username) THEN
      generated_username := generate_unique_username(NEW.email);
    END IF;
  END IF;
  
  -- Insertar en la tabla users (ahora en esquema app)
  INSERT INTO app.users (
    auth_id, 
    username, 
    email, 
    display_name, 
    theme_id, 
    last_login_at
  ) VALUES (
    NEW.id, 
    generated_username, 
    NEW.email, 
    COALESCE(display_name_from_meta, split_part(NEW.email, '@', 1)), 
    default_theme_id,
    current_date
  )
  RETURNING id INTO user_id;
  
  -- Insertar en la tabla profiles
  INSERT INTO public.profiles (
    id,
    meta_title,
    meta_description,
    chat_welcome_message
  ) VALUES (
    user_id,
    generated_username || '''s Links',
    'Check out my links and resources',
    'Hi! Welcome to my Linktree. Feel free to ask me anything!'
  );
  
  -- Insertar en user_roles con rol de usuario estándar
  INSERT INTO app.user_roles (
    user_id, 
    role, 
    permissions,
    notes
  ) VALUES (
    user_id, 
    'user', 
    '{
      "create_links": true, 
      "create_bots": true, 
      "customize_profile": true,
      "view_own_analytics": true
    }',
    'Rol asignado automáticamente durante registro'
  );
  
  -- Calcular el período de finalización para la suscripción gratuita (1 año desde ahora)
  period_end := current_date + INTERVAL '1 year';
  
  -- Crear suscripción gratuita automáticamente
  INSERT INTO app.subscriptions (
    user_id,
    plan_type,
    status,
    current_period_start,
    current_period_end,
    auto_renew,
    llm_tokens_included,
    llm_tokens_reset_date,
    llm_max_embedding_dimensions,
    llm_available_models,
    meta_data
  ) VALUES (
    user_id,
    'free',
    'active',
    current_date,
    period_end,
    TRUE,
    100000, -- 100k tokens mensuales gratis
    current_date + INTERVAL '1 month',
    1536, -- dimensión estándar para embeddings
    '["gpt-3.5-turbo"]', -- modelos disponibles para plan gratuito
    jsonb_build_object(
      'registration_source', COALESCE(NEW.raw_user_meta_data->>'source', 'direct'),
      'auto_created', true
    )
  );
  
  -- Insertar un link inicial de bienvenida si la tabla links existe
  BEGIN
    EXECUTE 'SELECT 1 FROM information_schema.tables WHERE table_name = ''links'' AND table_schema = ''public''';
    
    IF FOUND THEN
      EXECUTE '
        INSERT INTO public.links (
          user_id,
          title,
          url,
          position,
          is_active,
          is_featured
        ) VALUES (
          $1,
          $2,
          $3,
          $4,
          $5,
          $6
        )
      ' USING 
        user_id,
        'Welcome to My Linktree',
        'https://docs.linktree.com/welcome',
        1,
        TRUE,
        TRUE;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Si la tabla links aún no existe o hay otro error, continuar sin error
    NULL;
  END;
  
  -- Log del sistema para registrar la creación automática (si la función existe)
  BEGIN
    PERFORM log_system_error(
      user_id,
      'user_creation',
      'Usuario creado automáticamente con plan gratuito',
      'info',
      'auth',
      jsonb_build_object(
        'email', NEW.email,
        'username', generated_username,
        'auth_id', NEW.id,
        'subscription_end', period_end
      )
    );
  EXCEPTION WHEN OTHERS THEN
    -- Si la función log_system_error aún no existe, continuar sin error
    NULL;
  END;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Trigger que se dispara cuando se crea un nuevo usuario en auth
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION handle_new_user();

-- ---------- SECCIÓN 6: VISTAS DE COMPATIBILIDAD ----------

-- Vistas para mantener compatibilidad con código existente
CREATE OR REPLACE VIEW user_roles AS 
  SELECT * FROM app.user_roles;

CREATE OR REPLACE VIEW subscriptions AS 
  SELECT * FROM app.subscriptions;

CREATE OR REPLACE VIEW user_role_history AS 
  SELECT * FROM app.user_role_history;

CREATE OR REPLACE VIEW subscription_history AS 
  SELECT * FROM app.subscription_history;

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  RAISE NOTICE 'Tablas dependientes de Users creadas correctamente con automatización de usuarios.';
  RAISE NOTICE 'Tablas públicas: profiles';
  RAISE NOTICE 'Tablas internas: app.user_roles, app.subscriptions, app.user_role_history, app.subscription_history';
  RAISE NOTICE 'Vistas de compatibilidad creadas para facilitar la migración.';
END $$;