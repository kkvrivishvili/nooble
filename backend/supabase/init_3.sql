-- ARCHIVO: init.sql PARTE 3 - Tablas Dependientes de Users
-- Propósito: Crear tablas que dependen de la tabla users, como perfiles, roles y suscripciones

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS profiles CASCADE;
DROP TABLE IF EXISTS user_roles CASCADE;
DROP TABLE IF EXISTS subscriptions CASCADE;
DROP FUNCTION IF EXISTS sync_user_config_on_subscription_change CASCADE;

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
  permissions JSONB DEFAULT '{}', -- Nuevo para permisos granulares
  granted_by UUID REFERENCES users(id) ON DELETE SET NULL, -- Nuevo para auditoria
  notes TEXT, -- Nuevo para contextualizar asignación de rol
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabla de historial de roles (nueva)
CREATE TABLE IF NOT EXISTS user_role_history (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  previous_role VARCHAR(20) CHECK (previous_role IN ('user', 'admin', 'moderator', 'support', 'developer')),
  new_role VARCHAR(20) CHECK (new_role IN ('user', 'admin', 'moderator', 'support', 'developer')),
  changed_by UUID REFERENCES users(id) ON DELETE SET NULL,
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabla mejorada de Suscripciones
CREATE TABLE IF NOT EXISTS subscriptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
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
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
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
$$ LANGUAGE plpgsql;

-- Crear trigger
DROP TRIGGER IF EXISTS sync_config_on_subscription_change ON subscriptions;
CREATE TRIGGER sync_config_on_subscription_change
AFTER UPDATE ON subscriptions
FOR EACH ROW
WHEN (NEW.plan_type != OLD.plan_type OR NEW.status != OLD.status)
EXECUTE PROCEDURE sync_user_config_on_subscription_change();

-- Trigger para historial de roles de usuario
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
$$ LANGUAGE plpgsql;

-- Crear trigger para seguimiento de cambios en roles
DROP TRIGGER IF EXISTS track_user_role_changes ON user_roles;
CREATE TRIGGER track_user_role_changes
AFTER INSERT OR UPDATE ON user_roles
FOR EACH ROW
EXECUTE PROCEDURE track_role_changes();

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Tablas dependientes de Users creadas correctamente.';
END $$;