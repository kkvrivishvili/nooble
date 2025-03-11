-- ARCHIVO: init.sql PARTE 3 - Tablas Dependientes de Users
-- Propósito: Crear tablas que dependen de la tabla users, como perfiles, roles y suscripciones

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS profiles CASCADE;
DROP TABLE IF EXISTS user_roles CASCADE;
DROP TABLE IF EXISTS subscriptions CASCADE;
DROP FUNCTION IF EXISTS sync_user_config_on_subscription_change CASCADE;
DROP FUNCTION IF EXISTS generate_unique_username CASCADE;
DROP FUNCTION IF EXISTS handle_new_user CASCADE;

-- Tabla de Perfiles mejorada
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  social_twitter TEXT CHECK (social_twitter IS NULL OR social_twitter ~* '^@?[A-Za-z0-9_]{1,15}$'),
  social_instagram TEXT CHECK (social_instagram IS NULL OR social_instagram ~* '^[A-Za-z0-9._]{1,30}$'),
  social_tiktok TEXT CHECK (social_tiktok IS NULL OR social_tiktok ~* '^@?[A-Za-z0-9_\.]{1,24}$'),
  social_linkedin TEXT CHECK (social_linkedin IS NULL OR social_linkedin ~* '^[A-Za-z0-9\-]{5,100}$'), -- Nuevo
  social_github TEXT CHECK (social_github IS NULL OR social_github ~* '^[A-Za-z0-9\-]{1,39}$'), -- Nuevo
  location TEXT, -- Nuevo
  website TEXT CHECK (website IS NULL OR website ~* '^https?://.*$'), -- Nuevo
  allow_sensitive_content BOOLEAN DEFAULT FALSE,
  is_verified BOOLEAN DEFAULT FALSE,
  view_count INTEGER DEFAULT 0,
  meta_title TEXT,
  meta_description TEXT,
  meta_keywords TEXT, -- Nuevo para SEO
  custom_css TEXT,
  custom_domain TEXT CHECK (custom_domain IS NULL OR custom_domain ~* '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'),
  custom_js TEXT, -- Nuevo para scripts personalizados
  google_analytics_id TEXT, -- Nuevo para GA
  enable_cookie_consent BOOLEAN DEFAULT TRUE, -- Nuevo para GDPR
  last_visited_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Crear índice único para dominio personalizado
CREATE UNIQUE INDEX idx_profiles_custom_domain ON profiles(custom_domain) WHERE custom_domain IS NOT NULL;

-- Tabla mejorada de roles de usuario
CREATE TABLE IF NOT EXISTS user_roles (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'admin', 'moderator', 'support', 'developer')), -- Añadidos nuevos roles
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
  }', -- Estructura definida para permisos
  granted_by UUID REFERENCES users(id) ON DELETE SET NULL, -- Nuevo para auditoria
  notes TEXT, -- Nuevo para contextualizar asignación de rol
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabla de historial de roles (nueva)
CREATE TABLE IF NOT EXISTS user_role_history (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  previous_role VARCHAR(20) CHECK (previous_role IN ('user', 'admin', 'moderator', 'support', 'developer')),
  new_role VARCHAR(20) CHECK (new_role IN ('user', 'admin', 'moderator', 'support', 'developer')),
  changed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabla mejorada de Suscripciones
CREATE TABLE IF NOT EXISTS subscriptions (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan_type VARCHAR(20) NOT NULL CHECK (plan_type IN ('free', 'basic', 'premium', 'enterprise')),
  status VARCHAR(20) NOT NULL CHECK (status IN ('active', 'canceled', 'expired', 'trial', 'pending')),
  current_period_start TIMESTAMP WITH TIME ZONE NOT NULL,
  current_period_end TIMESTAMP WITH TIME ZONE NOT NULL,
  cancellation_date TIMESTAMP WITH TIME ZONE, -- Nueva
  trial_end TIMESTAMP WITH TIME ZONE, -- Nueva
  payment_provider VARCHAR(20),
  payment_reference TEXT,
  recurring_amount DECIMAL(10,2), -- Nueva para monto
  currency VARCHAR(3) DEFAULT 'USD', -- Nueva para moneda
  billing_email TEXT, -- Nueva para facturación
  meta_data JSONB DEFAULT '{}',
  auto_renew BOOLEAN DEFAULT TRUE,
  discount_code TEXT, -- Nueva para códigos promocionales
  discount_percent INTEGER, -- Nueva para descuentos
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT subscription_period_check CHECK (current_period_end > current_period_start)
);

-- Crear índice para usuarios activos
CREATE UNIQUE INDEX idx_active_subscriptions ON subscriptions(user_id) 
WHERE status = 'active';

-- Tabla de historial de suscripciones (nueva)
CREATE TABLE IF NOT EXISTS subscription_history (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  subscription_id UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  previous_plan VARCHAR(20) CHECK (previous_plan IN ('free', 'basic', 'premium', 'enterprise')),
  new_plan VARCHAR(20) CHECK (new_plan IN ('free', 'basic', 'premium', 'enterprise')),
  previous_status VARCHAR(20) CHECK (previous_status IN ('active', 'canceled', 'expired', 'trial', 'pending')),
  new_status VARCHAR(20) CHECK (new_status IN ('active', 'canceled', 'expired', 'trial', 'pending')),
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_by UUID REFERENCES users(id) ON DELETE SET NULL
);

-- Trigger mejorado para sincronizar configuración al cambiar suscripción
-- Corregido: Añadido SET search_path
CREATE OR REPLACE FUNCTION sync_user_config_on_subscription_change()
RETURNS TRIGGER AS $$
BEGIN
  -- Registrar cambio en el historial si es relevante
  IF (NEW.plan_type != OLD.plan_type OR NEW.status != OLD.status) THEN
    INSERT INTO subscription_history (
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
      INSERT INTO user_config (user_id, config_key, value, override_reason)
      SELECT 
        NEW.user_id, 
        spc.config_key, 
        spc.value, 
        'Auto-configurado por cambio de plan a ' || NEW.plan_type
      FROM subscription_plan_config spc
      WHERE spc.plan_type = NEW.plan_type
      ON CONFLICT (user_id, config_key) DO NOTHING;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, extensions;

-- Crear trigger
DROP TRIGGER IF EXISTS sync_config_on_subscription_change ON subscriptions;
CREATE TRIGGER sync_config_on_subscription_change
AFTER UPDATE ON subscriptions
FOR EACH ROW
WHEN (NEW.plan_type != OLD.plan_type OR NEW.status != OLD.status)
EXECUTE PROCEDURE sync_user_config_on_subscription_change();

-- Trigger para historial de roles de usuario
-- Corregido: Añadido SET search_path
CREATE OR REPLACE FUNCTION track_role_changes()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND OLD.role != NEW.role) THEN
    INSERT INTO user_role_history (
      user_id, previous_role, new_role, 
      changed_by, reason
    ) VALUES (
      NEW.user_id, OLD.role, NEW.role, 
      NEW.granted_by, NEW.notes
    );
  ELSIF (TG_OP = 'INSERT') THEN
    INSERT INTO user_role_history (
      user_id, previous_role, new_role, 
      changed_by, reason
    ) VALUES (
      NEW.user_id, NULL, NEW.role, 
      NEW.granted_by, NEW.notes
    );
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, extensions;

-- Crear trigger para seguimiento de cambios en roles
DROP TRIGGER IF EXISTS track_user_role_changes ON user_roles;
CREATE TRIGGER track_user_role_changes
AFTER INSERT OR UPDATE ON user_roles
FOR EACH ROW
EXECUTE PROCEDURE track_role_changes();

-- =============================================
-- SECCIÓN: Automatización de creación de usuarios y suscripciones
-- =============================================

-- Función para generar un username único basado en el email
-- Corregido: Añadido SET search_path
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
      SELECT 1 FROM users WHERE username = candidate_username
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
$$ LANGUAGE plpgsql SET search_path = public, extensions;

-- Función para manejar nuevos usuarios cuando se registran en auth
-- Corregido: Añadido SET search_path y mejorado manejo de errores
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
  SELECT id INTO default_theme_id FROM themes WHERE name = 'Default';
  IF default_theme_id IS NULL THEN
    SELECT id INTO default_theme_id FROM themes LIMIT 1;
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
    IF EXISTS (SELECT 1 FROM users WHERE username = generated_username) THEN
      generated_username := generate_unique_username(NEW.email);
    END IF;
  END IF;
  
  -- Insertar en la tabla users
  INSERT INTO users (
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
  INSERT INTO profiles (
    id,
    meta_title,
    meta_description
  ) VALUES (
    user_id,
    generated_username || '''s Links',
    'Check out my links and resources'
  );
  
  -- Insertar en user_roles con rol de usuario estándar
  INSERT INTO user_roles (
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
  INSERT INTO subscriptions (
    user_id,
    plan_type,
    status,
    current_period_start,
    current_period_end,
    auto_renew,
    meta_data
  ) VALUES (
    user_id,
    'free',
    'active',
    current_date,
    period_end,
    TRUE,
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
        INSERT INTO links (
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
$$ LANGUAGE plpgsql SET search_path = public, extensions;

-- Trigger que se dispara cuando se crea un nuevo usuario en auth
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION handle_new_user();

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Tablas dependientes de Users creadas correctamente con automatización de usuarios.';
END $$;