-- ARCHIVO: init.sql PARTE 5 - Tablas de Enlaces y Analytics
-- Propósito: Crear tablas para enlaces, analytics y monitoreo de uso

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS links CASCADE;
DROP TABLE IF EXISTS system_errors CASCADE;
DROP TABLE IF EXISTS analytics CASCADE;
DROP TABLE IF EXISTS usage_metrics CASCADE;
DROP FUNCTION IF EXISTS create_analytics_partition CASCADE;
DROP FUNCTION IF EXISTS check_quota_thresholds CASCADE;

-- Tabla de Enlaces mejorada
CREATE TABLE IF NOT EXISTS links (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title VARCHAR(100) NOT NULL,
  url TEXT CHECK (url IS NULL OR url ~* '^https?://.*$'),
  bot_id UUID REFERENCES bots(id) ON DELETE SET NULL,
  thumbnail_url TEXT CHECK (thumbnail_url IS NULL OR thumbnail_url ~* '^https?://.*$'),
  icon_name VARCHAR(30),
  position INTEGER NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  is_featured BOOLEAN DEFAULT FALSE, -- Nuevo para destacar enlaces
  start_date TIMESTAMP WITH TIME ZONE, -- Nuevo para programación
  end_date TIMESTAMP WITH TIME ZONE, -- Nuevo para programación
  click_count INTEGER DEFAULT 0,
  utm_source TEXT, -- Nuevo para marketing
  utm_medium TEXT, -- Nuevo para marketing
  utm_campaign TEXT, -- Nuevo para marketing
  custom_css TEXT,
  mobile_only BOOLEAN DEFAULT FALSE, -- Nuevo para visibilidad condicional
  desktop_only BOOLEAN DEFAULT FALSE, -- Nuevo para visibilidad condicional
  require_login BOOLEAN DEFAULT FALSE, -- Nuevo para acceso restringido
  is_premium_feature BOOLEAN DEFAULT FALSE,
  custom_data JSONB DEFAULT '{}', -- Nuevo para metadatos personalizados
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT link_has_destination CHECK (
    (url IS NOT NULL AND bot_id IS NULL) OR
    (url IS NULL AND bot_id IS NOT NULL)
  ),
  CONSTRAINT link_visibility_check CHECK (
    NOT (mobile_only = TRUE AND desktop_only = TRUE)
  )
);

-- Índices mejorados para links
CREATE INDEX idx_links_user_position ON links(user_id, position);
CREATE INDEX idx_links_bot_id ON links(bot_id) WHERE bot_id IS NOT NULL;
CREATE INDEX idx_links_active ON links(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_links_featured ON links(is_featured) WHERE is_featured = TRUE;
CREATE INDEX idx_links_date_range ON links(start_date, end_date) 
  WHERE start_date IS NOT NULL OR end_date IS NOT NULL;

-- Tabla para grupos de enlaces (nueva)
CREATE TABLE IF NOT EXISTS link_groups (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name VARCHAR(50) NOT NULL,
  description TEXT,
  position INTEGER NOT NULL,
  is_collapsed BOOLEAN DEFAULT FALSE,
  icon_name VARCHAR(30),
  custom_css TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índice para grupos de enlaces
CREATE INDEX idx_link_groups_user ON link_groups(user_id, position);

-- Tabla para relacionar enlaces con grupos (nueva)
CREATE TABLE IF NOT EXISTS link_group_items (
  link_id UUID NOT NULL REFERENCES links(id) ON DELETE CASCADE,
  group_id UUID NOT NULL REFERENCES link_groups(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  PRIMARY KEY(link_id, group_id)
);

-- Índice para items en grupos
CREATE INDEX idx_link_group_items_group ON link_group_items(group_id, position);

-- Tabla para registro de errores del sistema mejorada
CREATE TABLE IF NOT EXISTS system_errors (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  error_type VARCHAR(50) NOT NULL,
  error_message TEXT NOT NULL,
  severity VARCHAR(20) DEFAULT 'error' CHECK (severity IN ('info', 'warning', 'error', 'critical')), -- Nuevo para clasificación
  source VARCHAR(50), -- Nuevo para origen (API, database, auth, etc)
  request_path TEXT, -- Nuevo para endpoint
  stack_trace TEXT, -- Nuevo para debug
  ip_address TEXT, -- Nuevo para seguridad
  user_agent TEXT, -- Nuevo para debug
  context JSONB DEFAULT '{}',
  is_resolved BOOLEAN DEFAULT FALSE, -- Nuevo para seguimiento
  resolved_by UUID REFERENCES users(id) ON DELETE SET NULL, -- Nuevo para responsabilidad
  resolved_at TIMESTAMP WITH TIME ZONE, -- Nuevo para timestamp
  resolution_notes TEXT, -- Nuevo para documentación
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para errores
CREATE INDEX idx_system_errors_type ON system_errors(error_type);
CREATE INDEX idx_system_errors_user ON system_errors(user_id);
CREATE INDEX idx_system_errors_severity ON system_errors(severity);
CREATE INDEX idx_system_errors_date ON system_errors(created_at);
CREATE INDEX idx_system_errors_resolved ON system_errors(is_resolved, resolved_at);

-- Crear tabla particionada de analytics con mejor manejo
CREATE TABLE IF NOT EXISTS analytics (
  id UUID NOT NULL DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  link_id UUID REFERENCES links(id) ON DELETE SET NULL,
  visitor_ip TEXT,
  user_agent TEXT,
  referer TEXT,
  country TEXT,
  city TEXT,
  region TEXT, -- Nuevo para localización
  device_type VARCHAR(20),
  browser VARCHAR(50), -- Nuevo para stats
  browser_version VARCHAR(20), -- Nuevo para stats
  os VARCHAR(50), -- Nuevo para stats
  os_version VARCHAR(20), -- Nuevo para stats
  utm_source TEXT, -- Nuevo para marketing
  utm_medium TEXT, -- Nuevo para marketing
  utm_campaign TEXT, -- Nuevo para marketing
  session_id UUID,
  is_unique BOOLEAN DEFAULT TRUE, -- Nuevo para stats
  duration_seconds INTEGER, -- Nuevo para engagement
  page_views INTEGER DEFAULT 1, -- Nuevo para engagement
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Función mejorada para crear particiones de analytics
CREATE OR REPLACE FUNCTION create_analytics_partition()
RETURNS TRIGGER AS $$
DECLARE
  partition_date DATE;
  partition_name TEXT;
  start_date TEXT;
  end_date TEXT;
  next_month_date DATE;
  next_next_month_date DATE;
  unique_suffix TEXT;
BEGIN
  -- Determinar el mes del dato a insertar
  partition_date := date_trunc('month', NEW.created_at)::DATE;
  partition_name := 'analytics_y' || 
                    EXTRACT(YEAR FROM partition_date)::TEXT || 
                    'm' || 
                    LPAD(EXTRACT(MONTH FROM partition_date)::TEXT, 2, '0');
  start_date := partition_date::TEXT;
  end_date := (partition_date + INTERVAL '1 month')::TEXT;
  
  -- Generar sufijo único basado en timestamp para evitar colisiones
  unique_suffix := '_' || EXTRACT(EPOCH FROM NOW())::BIGINT;
  
  -- Verificar y crear partición para el mes actual
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = partition_name AND n.nspname = 'public'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      -- Crear índices con nombres únicos
      EXECUTE format(
        'CREATE INDEX %I ON %I (user_id, created_at)',
        partition_name || '_user_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON %I (created_at)',
        partition_name || '_date_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON %I (link_id, created_at) WHERE link_id IS NOT NULL',
        partition_name || '_link_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON %I (country, city)',
        partition_name || '_geo_idx' || unique_suffix, 
        partition_name
      );

      RAISE NOTICE 'Creada partición % para datos de analytics', partition_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  -- Crear particiones anticipadas para los próximos dos meses (proactivo)
  next_month_date := partition_date + INTERVAL '1 month';
  next_next_month_date := partition_date + INTERVAL '2 month';
  
  -- Próximo mes
  partition_name := 'analytics_y' || 
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
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      RAISE NOTICE 'Creada partición anticipada % para próximo mes', partition_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición anticipada %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  -- Siguiente mes
  partition_name := 'analytics_y' || 
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
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      RAISE NOTICE 'Creada partición anticipada % para mes subsiguiente', partition_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición anticipada %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Crear particiones iniciales manualmente para datos históricos y actuales
DO $$
DECLARE
  current_date DATE := CURRENT_DATE;
  start_month DATE;
  partition_name TEXT;
  start_date TEXT;
  end_date TEXT;
BEGIN
  -- Crear particiones para 3 meses pasados, mes actual y 2 meses futuros
  FOR i IN -3..2 LOOP
    start_month := date_trunc('month', current_date + (i * INTERVAL '1 month'))::DATE;
    
    partition_name := 'analytics_y' || 
                      EXTRACT(YEAR FROM start_month)::TEXT || 
                      'm' || 
                      LPAD(EXTRACT(MONTH FROM start_month)::TEXT, 2, '0');
    start_date := start_month::TEXT;
    end_date := (start_month + INTERVAL '1 month')::TEXT;
    
    -- Verificar si la partición ya existe
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = partition_name AND n.nspname = 'public'
    ) THEN
      BEGIN
        EXECUTE format(
          'CREATE TABLE IF NOT EXISTS %I PARTITION OF analytics
           FOR VALUES FROM (%L) TO (%L)',
          partition_name, start_date, end_date
        );
        
        -- Índices básicos para particiones
        EXECUTE format(
          'CREATE INDEX %I ON %I (user_id, created_at)',
          partition_name || '_user_idx', 
          partition_name
        );
        
        EXECUTE format(
          'CREATE INDEX %I ON %I (created_at)',
          partition_name || '_date_idx', 
          partition_name
        );
        
        EXECUTE format(
          'CREATE INDEX %I ON %I (link_id, created_at) WHERE link_id IS NOT NULL',
          partition_name || '_link_idx', 
          partition_name
        );
        
        RAISE NOTICE 'Creada partición % para datos de analytics', partition_name;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Error creando partición %: %', partition_name, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;

-- Tabla mejorada para cuotas de uso mensual
CREATE TABLE IF NOT EXISTS usage_metrics (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  metric_type VARCHAR(30) NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  year_month INTEGER NOT NULL, -- formato YYYYMM
  daily_breakdown JSONB DEFAULT '{}', -- Nuevo para desglose diario
  quota_limit INTEGER, -- Nuevo para límite aplicable
  quota_reset_date TIMESTAMP WITH TIME ZONE, -- Nuevo para reset
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices mejorados para métricas
CREATE UNIQUE INDEX idx_usage_metrics_unique ON usage_metrics(user_id, metric_type, year_month);
CREATE INDEX idx_usage_metrics_type ON usage_metrics(metric_type, year_month);
CREATE INDEX idx_usage_metrics_reset ON usage_metrics(quota_reset_date);

-- Tabla para notificaciones de cuota (nueva)
CREATE TABLE IF NOT EXISTS quota_notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  metric_type VARCHAR(30) NOT NULL,
  threshold_percent INTEGER NOT NULL, -- e.g. 80, 90, 100
  message TEXT NOT NULL,
  sent_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  year_month INTEGER NOT NULL, -- formato YYYYMM
  is_read BOOLEAN DEFAULT FALSE,
  read_at TIMESTAMP WITH TIME ZONE
);

-- Índices para notificaciones
CREATE INDEX idx_quota_notifications_user ON quota_notifications(user_id, is_read);
CREATE INDEX idx_quota_notifications_month ON quota_notifications(user_id, year_month);

-- Trigger para monitorizar % de uso de cuota
CREATE OR REPLACE FUNCTION check_quota_thresholds()
RETURNS TRIGGER AS $$
DECLARE
  v_quota_limit INTEGER;
  v_usage_percent INTEGER;
  v_threshold INTEGER;
  v_notification_exists BOOLEAN;
  v_thresholds INTEGER[] := ARRAY[80, 90, 100]; -- Definir array de umbrales
BEGIN
  -- Solo proceder si hay un límite de cuota definido
  IF NEW.quota_limit IS NULL OR NEW.quota_limit <= 0 THEN
    RETURN NEW;
  END IF;
  
  -- Calcular porcentaje de uso
  v_usage_percent := (NEW.count * 100) / NEW.quota_limit;
  
  -- Verificar umbrales (80%, 90%, 100%)
  FOREACH v_threshold IN ARRAY v_thresholds LOOP
    -- Si el uso supera el umbral
    IF v_usage_percent >= v_threshold THEN
      -- Verificar si ya existe notificación para este umbral
      SELECT EXISTS (
        SELECT 1 FROM quota_notifications
        WHERE user_id = NEW.user_id
        AND metric_type = NEW.metric_type
        AND year_month = NEW.year_month
        AND threshold_percent = v_threshold
      ) INTO v_notification_exists;
      
      -- Si no existe, crear notificación
      IF NOT v_notification_exists THEN
        INSERT INTO quota_notifications (
          user_id, metric_type, threshold_percent, year_month,
          message
        ) VALUES (
          NEW.user_id, NEW.metric_type, v_threshold, NEW.year_month,
          CASE 
            WHEN v_threshold = 100 THEN 'Has alcanzado el 100% de tu cuota de ' || NEW.metric_type
            ELSE 'Has alcanzado el ' || v_threshold || '% de tu cuota de ' || NEW.metric_type
          END
        );
      END IF;
    END IF;
  END LOOP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Crear trigger para notificaciones
DROP TRIGGER IF EXISTS trigger_quota_threshold_check ON usage_metrics;
CREATE TRIGGER trigger_quota_threshold_check
AFTER INSERT OR UPDATE OF count, quota_limit ON usage_metrics
FOR EACH ROW
EXECUTE PROCEDURE check_quota_thresholds();

-- Crear trigger para partition de analytics
DROP TRIGGER IF EXISTS create_analytics_partition_trigger ON analytics;
CREATE TRIGGER create_analytics_partition_trigger
BEFORE INSERT ON analytics
FOR EACH ROW
EXECUTE PROCEDURE create_analytics_partition();

-- Notificación de finalización
DO $$
BEGIN
  RAISE NOTICE 'Tablas de enlaces y analytics creadas correctamente con particionamiento automático.';
END $$;