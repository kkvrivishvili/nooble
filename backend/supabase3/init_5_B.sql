-- ==============================================
-- ARCHIVO: init_5.sql - Tablas de Enlaces y Analytics
-- ==============================================
-- Propósito: Crear tablas para enlaces (Linktree), analytics, monitoreo de uso,
-- sistema de cuotas y notificaciones.
-- 
-- NOTA: Las tablas system_errors, analytics, usage_metrics y quota_notifications
-- se han movido al esquema 'app' para separar datos internos de datos públicos.
-- Las tablas links, link_groups y link_group_items permanecen en el esquema 'public'
-- por ser accesibles públicamente.
-- ==============================================

-- Eliminar funciones para recrearlas desde cero
DROP FUNCTION IF EXISTS create_analytics_partition() CASCADE;
DROP FUNCTION IF EXISTS check_quota_thresholds() CASCADE;

-- Eliminar índices para evitar conflictos
DO $$
DECLARE
    indices TEXT[] := ARRAY[
        'idx_links_user_position', 'idx_links_bot_id', 'idx_links_active', 
        'idx_links_featured', 'idx_links_date_range', 'idx_link_groups_user',
        'idx_link_group_items_group', 'idx_system_errors_type', 'idx_system_errors_user',
        'idx_system_errors_severity', 'idx_system_errors_date', 'idx_system_errors_resolved',
        'idx_usage_metrics_unique', 'idx_usage_metrics_type', 'idx_usage_metrics_reset',
        'idx_quota_notifications_user', 'idx_quota_notifications_month'
    ];
BEGIN
    FOR i IN 1..array_length(indices, 1) LOOP
        EXECUTE 'DROP INDEX IF EXISTS ' || indices[i];
    END LOOP;
END $$;

-- Eliminar triggers para recrearlos desde cero
DROP TRIGGER IF EXISTS trigger_quota_threshold_check ON usage_metrics;
DROP TRIGGER IF EXISTS trigger_quota_threshold_check ON app.usage_metrics;
DROP TRIGGER IF EXISTS create_analytics_partition_trigger ON analytics;
DROP TRIGGER IF EXISTS create_analytics_partition_trigger ON app.analytics;

-- Eliminar tablas para recrearlas desde cero
DROP TABLE IF EXISTS links CASCADE;
DROP TABLE IF EXISTS link_groups CASCADE;
DROP TABLE IF EXISTS link_group_items CASCADE;
DROP TABLE IF EXISTS system_errors CASCADE;
DROP TABLE IF EXISTS analytics CASCADE;
DROP TABLE IF EXISTS usage_metrics CASCADE;
DROP TABLE IF EXISTS quota_notifications CASCADE;
-- También eliminar las tablas en el nuevo esquema por si existen
DROP TABLE IF EXISTS app.system_errors CASCADE;
DROP TABLE IF EXISTS app.analytics CASCADE;
DROP TABLE IF EXISTS app.usage_metrics CASCADE;
DROP TABLE IF EXISTS app.quota_notifications CASCADE;

-- Buscar y eliminar particiones de analytics
DO $$
DECLARE
    partition_table TEXT;
    partition_tables CURSOR FOR 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public' AND tablename LIKE 'analytics_y%m%';
BEGIN
    OPEN partition_tables;
    LOOP
        FETCH partition_tables INTO partition_table;
        EXIT WHEN NOT FOUND;
        
        EXECUTE 'DROP TABLE IF EXISTS ' || partition_table || ' CASCADE';
    END LOOP;
    CLOSE partition_tables;
END $$;

-- Buscar y eliminar particiones en esquema app
DO $$
DECLARE
    partition_table TEXT;
    partition_tables CURSOR FOR 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'app' AND tablename LIKE 'analytics_y%m%';
BEGIN
    OPEN partition_tables;
    LOOP
        FETCH partition_tables INTO partition_table;
        EXIT WHEN NOT FOUND;
        
        EXECUTE 'DROP TABLE IF EXISTS app.' || partition_table || ' CASCADE';
    END LOOP;
    CLOSE partition_tables;
END $$;

-- ---------- SECCIÓN 1: TABLAS DE ENLACES (LINKTREE) ----------

-- Tabla de Enlaces mejorada (públicamente accesible)
CREATE TABLE IF NOT EXISTS public.links (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title VARCHAR(100) NOT NULL,
  url TEXT CHECK (url IS NULL OR url ~* '^https?://[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_\+.~#?&//=]*)$'),
  bot_id UUID REFERENCES public.bots(id) ON DELETE SET NULL,
  thumbnail_url TEXT CHECK (thumbnail_url IS NULL OR thumbnail_url ~* '^https?://[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_\+.~#?&//=]*)$'),
  icon_name VARCHAR(30),
  position INTEGER NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  is_featured BOOLEAN DEFAULT FALSE,
  start_date TIMESTAMP WITH TIME ZONE,
  end_date TIMESTAMP WITH TIME ZONE,
  click_count INTEGER DEFAULT 0,
  utm_source TEXT,
  utm_medium TEXT,
  utm_campaign TEXT,
  custom_css TEXT,
  mobile_only BOOLEAN DEFAULT FALSE,
  desktop_only BOOLEAN DEFAULT FALSE,
  require_login BOOLEAN DEFAULT FALSE,
  is_premium_feature BOOLEAN DEFAULT FALSE,
  custom_data JSONB DEFAULT '{}',
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
CREATE INDEX idx_links_user_position ON public.links(user_id, position);
CREATE INDEX idx_links_bot_id ON public.links(bot_id) WHERE bot_id IS NOT NULL;
CREATE INDEX idx_links_active ON public.links(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_links_featured ON public.links(is_featured) WHERE is_featured = TRUE;
CREATE INDEX idx_links_date_range ON public.links(start_date, end_date) 
  WHERE start_date IS NOT NULL OR end_date IS NOT NULL;
CREATE INDEX idx_links_title_search ON public.links USING gin(title gin_trgm_ops);

-- Tabla para grupos de enlaces (públicamente accesible)
CREATE TABLE IF NOT EXISTS public.link_groups (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
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
CREATE INDEX idx_link_groups_user ON public.link_groups(user_id, position);
CREATE INDEX idx_link_groups_name ON public.link_groups USING gin(name gin_trgm_ops);

-- Tabla para relacionar enlaces con grupos (públicamente accesible)
CREATE TABLE IF NOT EXISTS public.link_group_items (
  link_id UUID NOT NULL REFERENCES public.links(id) ON DELETE CASCADE,
  group_id UUID NOT NULL REFERENCES public.link_groups(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  PRIMARY KEY(link_id, group_id)
);

-- Índice para items en grupos
CREATE INDEX idx_link_group_items_group ON public.link_group_items(group_id, position);
CREATE INDEX idx_link_group_items_link ON public.link_group_items(link_id);

-- ---------- SECCIÓN 2: TABLAS DE ERRORES Y MONITOREO (movidas a esquema 'app') ----------

-- Tabla para registro de errores del sistema mejorada (interna)
CREATE TABLE IF NOT EXISTS app.system_errors (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  error_type VARCHAR(50) NOT NULL,
  error_message TEXT NOT NULL,
  severity VARCHAR(20) DEFAULT 'error' CHECK (severity IN ('info', 'warning', 'error', 'critical')),
  source VARCHAR(50),
  request_path TEXT,
  stack_trace TEXT,
  ip_address TEXT,
  user_agent TEXT,
  context JSONB DEFAULT '{}',
  is_resolved BOOLEAN DEFAULT FALSE,
  resolved_by UUID REFERENCES users(id) ON DELETE SET NULL,
  resolved_at TIMESTAMP WITH TIME ZONE,
  resolution_notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para errores
CREATE INDEX idx_system_errors_type ON app.system_errors(error_type);
CREATE INDEX idx_system_errors_user ON app.system_errors(user_id);
CREATE INDEX idx_system_errors_severity ON app.system_errors(severity);
CREATE INDEX idx_system_errors_date ON app.system_errors(created_at);
CREATE INDEX idx_system_errors_resolved ON app.system_errors(is_resolved, resolved_at);
CREATE INDEX idx_system_errors_source ON app.system_errors(source, error_type);

-- ---------- SECCIÓN 3: ANALÍTICA PARTICIONADA (movida a esquema 'app') ----------

-- Crear tabla particionada de analytics con mejor manejo (interna)
CREATE TABLE IF NOT EXISTS app.analytics (
  id UUID NOT NULL DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  link_id UUID REFERENCES public.links(id) ON DELETE SET NULL,
  visitor_ip TEXT,
  user_agent TEXT,
  referer TEXT,
  country TEXT,
  city TEXT,
  region TEXT,
  device_type VARCHAR(20),
  browser VARCHAR(50),
  browser_version VARCHAR(20),
  os VARCHAR(50),
  os_version VARCHAR(20),
  utm_source TEXT,
  utm_medium TEXT,
  utm_campaign TEXT,
  session_id UUID,
  is_unique BOOLEAN DEFAULT TRUE,
  duration_seconds INTEGER,
  page_views INTEGER DEFAULT 1,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Función para crear particiones de analytics
-- Manteniendo el search_path original pero añadiendo app
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
  policy_exists BOOLEAN;
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
    WHERE c.relname = partition_name AND n.nspname = 'app'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      -- Habilitar RLS en la partición creada
      EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', partition_name);
      
      -- Verificar si la política ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'app' AND tablename = partition_name 
        AND policyname = 'analytics_partition_select_policy'
      ) INTO policy_exists;
      
      -- Crear políticas RLS para la partición
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_select_policy ON app.%I
           FOR SELECT USING (
             user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
             is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
             has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), ''view_analytics'')
           )', 
          partition_name
        );
      END IF;
      
      -- Verificar si la política de inserción ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'app' AND tablename = partition_name 
        AND policyname = 'analytics_partition_insert_policy'
      ) INTO policy_exists;
      
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_insert_policy ON app.%I
           FOR INSERT WITH CHECK (
             user_id IN (SELECT id FROM users) -- Permitir inserción para usuarios reales
           )', 
          partition_name
        );
      END IF;
      
      -- Crear índices con nombres únicos
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (user_id, created_at)',
        partition_name || '_user_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (created_at)',
        partition_name || '_date_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (link_id, created_at) WHERE link_id IS NOT NULL',
        partition_name || '_link_idx' || unique_suffix, 
        partition_name
      );
      
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (country, city)',
        partition_name || '_geo_idx' || unique_suffix, 
        partition_name
      );

      -- Añadir índices para búsquedas comunes
      EXECUTE format(
        'CREATE INDEX %I ON app.%I (session_id)',
        partition_name || '_session_idx' || unique_suffix, 
        partition_name
      );

      EXECUTE format(
        'CREATE INDEX %I ON app.%I (utm_source, utm_medium, utm_campaign) 
         WHERE utm_source IS NOT NULL',
        partition_name || '_utm_idx' || unique_suffix, 
        partition_name
      );

      RAISE NOTICE 'Creada partición % para datos de analytics con RLS habilitado', partition_name;
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
    WHERE c.relname = partition_name AND n.nspname = 'app'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      -- Habilitar RLS en la partición creada
      EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', partition_name);

      -- Verificar si la política ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'app' AND tablename = partition_name 
        AND policyname = 'analytics_partition_select_policy'
      ) INTO policy_exists;
      
      -- Crear políticas RLS para la partición
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_select_policy ON app.%I
           FOR SELECT USING (
             user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
             is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
             has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), ''view_analytics'')
           )', 
          partition_name
        );
      END IF;
      
      -- Verificar si la política de inserción ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'app' AND tablename = partition_name 
        AND policyname = 'analytics_partition_insert_policy'
      ) INTO policy_exists;
      
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_insert_policy ON app.%I
           FOR INSERT WITH CHECK (
             user_id IN (SELECT id FROM users) -- Permitir inserción para usuarios reales
           )', 
          partition_name
        );
      END IF;
      
      RAISE NOTICE 'Creada partición anticipada % con RLS habilitado', partition_name;
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
    WHERE c.relname = partition_name AND n.nspname = 'app'
  ) THEN
    BEGIN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.analytics
         FOR VALUES FROM (%L) TO (%L)',
        partition_name, start_date, end_date
      );
      
      -- Habilitar RLS en la partición creada
      EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', partition_name);

      -- Verificar si la política ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'app' AND tablename = partition_name 
        AND policyname = 'analytics_partition_select_policy'
      ) INTO policy_exists;
      
      -- Crear políticas RLS para la partición
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_select_policy ON app.%I
           FOR SELECT USING (
             user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
             is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
             has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), ''view_analytics'')
           )', 
          partition_name
        );
      END IF;
      
      -- Verificar si la política de inserción ya existe
      SELECT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE schemaname = 'app' AND tablename = partition_name 
        AND policyname = 'analytics_partition_insert_policy'
      ) INTO policy_exists;
      
      IF NOT policy_exists THEN
        EXECUTE format(
          'CREATE POLICY analytics_partition_insert_policy ON app.%I
           FOR INSERT WITH CHECK (
             user_id IN (SELECT id FROM users) -- Permitir inserción para usuarios reales
           )', 
          partition_name
        );
      END IF;
      
      RAISE NOTICE 'Creada partición anticipada % con RLS habilitado', partition_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Error creando partición anticipada %: %', partition_name, SQLERRM;
    END;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, app, extensions;

-- Crear particiones iniciales manualmente para datos históricos y actuales
DO $$
DECLARE
  current_date DATE := CURRENT_DATE;
  start_month DATE;
  partition_name TEXT;
  start_date TEXT;
  end_date TEXT;
  policy_exists BOOLEAN;
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
      WHERE c.relname = partition_name AND n.nspname = 'app'
    ) THEN
      BEGIN
        EXECUTE format(
          'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.analytics
           FOR VALUES FROM (%L) TO (%L)',
          partition_name, start_date, end_date
        );
        
        -- Habilitar RLS en la partición creada
        EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', partition_name);

        -- Verificar si la política ya existe
        SELECT EXISTS (
          SELECT 1 FROM pg_policies 
          WHERE schemaname = 'app' AND tablename = partition_name 
          AND policyname = 'analytics_partition_select_policy'
        ) INTO policy_exists;
        
        -- Crear políticas RLS para la partición
        IF NOT policy_exists THEN
          EXECUTE format(
            'CREATE POLICY analytics_partition_select_policy ON app.%I
             FOR SELECT USING (
               user_id IN (SELECT id FROM users WHERE auth.uid() = auth_id) OR
               is_admin((SELECT id FROM users WHERE auth.uid() = auth_id)) OR
               has_permission((SELECT id FROM users WHERE auth.uid() = auth_id), ''view_analytics'')
             )', 
            partition_name
          );
        END IF;
        
        -- Verificar si la política de inserción ya existe
        SELECT EXISTS (
          SELECT 1 FROM pg_policies 
          WHERE schemaname = 'app' AND tablename = partition_name 
          AND policyname = 'analytics_partition_insert_policy'
        ) INTO policy_exists;
        
        IF NOT policy_exists THEN
          EXECUTE format(
            'CREATE POLICY analytics_partition_insert_policy ON app.%I
             FOR INSERT WITH CHECK (
               user_id IN (SELECT id FROM users) -- Permitir inserción para usuarios reales
             )', 
            partition_name
          );
        END IF;
        
        -- Índices básicos para particiones
        EXECUTE format(
          'CREATE INDEX %I ON app.%I (user_id, created_at)',
          partition_name || '_user_idx', 
          partition_name
        );
        
        EXECUTE format(
          'CREATE INDEX %I ON app.%I (created_at)',
          partition_name || '_date_idx', 
          partition_name
        );
        
        EXECUTE format(
          'CREATE INDEX %I ON app.%I (link_id, created_at) WHERE link_id IS NOT NULL',
          partition_name || '_link_idx', 
          partition_name
        );
        
        RAISE NOTICE 'Creada partición % para datos de analytics con RLS habilitado', partition_name;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Error creando partición %: %', partition_name, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;

-- ---------- SECCIÓN 4: MÉTRICAS DE USO Y NOTIFICACIONES (movidas a esquema 'app') ----------

-- Tabla mejorada para cuotas de uso mensual (interna)
CREATE TABLE IF NOT EXISTS app.usage_metrics (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  metric_type VARCHAR(30) NOT NULL,
  count INTEGER NOT NULL DEFAULT 1,
  year_month INTEGER NOT NULL, -- formato YYYYMM
  daily_breakdown JSONB DEFAULT '{}',
  quota_limit INTEGER,
  quota_reset_date TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices mejorados para métricas
CREATE UNIQUE INDEX idx_usage_metrics_unique ON app.usage_metrics(user_id, metric_type, year_month);
CREATE INDEX idx_usage_metrics_type ON app.usage_metrics(metric_type, year_month);
CREATE INDEX idx_usage_metrics_reset ON app.usage_metrics(quota_reset_date);
CREATE INDEX idx_usage_metrics_user_metrics ON app.usage_metrics(user_id, metric_type);

-- Tabla para notificaciones de cuota (interna)
CREATE TABLE IF NOT EXISTS app.quota_notifications (
  id UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
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
CREATE INDEX idx_quota_notifications_user ON app.quota_notifications(user_id, is_read);
CREATE INDEX idx_quota_notifications_month ON app.quota_notifications(user_id, year_month);
CREATE INDEX idx_quota_notifications_sent ON app.quota_notifications(sent_at DESC);

-- Trigger para monitorizar % de uso de cuota (mejorado con concurrencia)
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
      -- Verificar si ya existe notificación para este umbral (con FOR UPDATE para evitar condiciones de carrera)
      SELECT EXISTS (
        SELECT 1 FROM app.quota_notifications
        WHERE user_id = NEW.user_id
        AND metric_type = NEW.metric_type
        AND year_month = NEW.year_month
        AND threshold_percent = v_threshold
        FOR UPDATE
      ) INTO v_notification_exists;
      
      -- Si no existe, crear notificación
      IF NOT v_notification_exists THEN
        INSERT INTO app.quota_notifications (
          user_id, metric_type, threshold_percent, year_month,
          message
        ) VALUES (
          NEW.user_id, NEW.metric_type, v_threshold, NEW.year_month,
          CASE 
            WHEN v_threshold = 100 THEN 'Has alcanzado el 100% de tu cuota de ' || NEW.metric_type
            ELSE 'Has alcanzado el ' || v_threshold || '% de tu cuota de ' || NEW.metric_type
          END
        );
        
        -- Registrar la notificación en el log del sistema
        PERFORM log_system_error(
          NEW.user_id,
          'quota_threshold_reached',
          'Usuario alcanzó ' || v_threshold || '% de su cuota de ' || NEW.metric_type,
          'info',
          'quota_monitor',
          jsonb_build_object(
            'metric_type', NEW.metric_type,
            'threshold', v_threshold,
            'current_usage', NEW.count,
            'quota_limit', NEW.quota_limit,
            'year_month', NEW.year_month
          )
        );
      END IF;
    END IF;
  END LOOP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, app, extensions;

-- Crear trigger para notificaciones
CREATE TRIGGER trigger_quota_threshold_check
AFTER INSERT OR UPDATE OF count, quota_limit ON app.usage_metrics
FOR EACH ROW
EXECUTE PROCEDURE check_quota_thresholds();

-- Crear trigger para partition de analytics
CREATE TRIGGER create_analytics_partition_trigger
BEFORE INSERT ON app.analytics
FOR EACH ROW
EXECUTE PROCEDURE create_analytics_partition();

-- Crear vistas de compatibilidad para mantener código existente funcionando
-- Estas vistas pueden eliminarse en una fase posterior de la migración
CREATE OR REPLACE VIEW analytics AS 
  SELECT * FROM app.analytics;

CREATE OR REPLACE VIEW system_errors AS 
  SELECT * FROM app.system_errors;

CREATE OR REPLACE VIEW usage_metrics AS 
  SELECT * FROM app.usage_metrics;

CREATE OR REPLACE VIEW quota_notifications AS 
  SELECT * FROM app.quota_notifications;

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  RAISE NOTICE 'Tablas de enlaces y analytics creadas correctamente con particionamiento automático y RLS habilitado.';
  RAISE NOTICE 'Tablas públicas: links, link_groups, link_group_items';
  RAISE NOTICE 'Tablas internas: app.analytics, app.system_errors, app.usage_metrics, app.quota_notifications';
  RAISE NOTICE 'Vistas de compatibilidad creadas para facilitar la migración.';
END $$;