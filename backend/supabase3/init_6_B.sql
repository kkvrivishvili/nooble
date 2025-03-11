-- ==============================================
-- ARCHIVO: init_6.sql - Funciones y Triggers Principales
-- ==============================================
-- Propósito: Implementar la lógica de negocio central mediante funciones y triggers 
-- que controlan permisos, cuotas, configuración y operaciones del sistema.
-- ==============================================

-- Eliminar funciones existentes para recrearlas desde cero
DROP FUNCTION IF EXISTS update_modified_column() CASCADE;
DROP FUNCTION IF EXISTS increment_link_clicks() CASCADE;
DROP FUNCTION IF EXISTS is_admin() CASCADE;
DROP FUNCTION IF EXISTS has_permission() CASCADE;
DROP FUNCTION IF EXISTS log_system_error() CASCADE;
DROP FUNCTION IF EXISTS check_user_quota() CASCADE;
DROP FUNCTION IF EXISTS set_user_config() CASCADE;
DROP FUNCTION IF EXISTS bulk_update_config_by_plan() CASCADE;
DROP FUNCTION IF EXISTS reset_user_config_to_plan() CASCADE;
DROP FUNCTION IF EXISTS update_vector_dimensions() CASCADE;
DROP FUNCTION IF EXISTS validate_config_value() CASCADE;
DROP FUNCTION IF EXISTS enforce_bot_quota() CASCADE;
DROP FUNCTION IF EXISTS enforce_collection_quota() CASCADE;
DROP FUNCTION IF EXISTS enforce_document_quota() CASCADE;
DROP FUNCTION IF EXISTS enforce_vector_search_quota() CASCADE;
DROP FUNCTION IF EXISTS queue_document_for_embedding() CASCADE;
DROP FUNCTION IF EXISTS queue_collection_for_embedding() CASCADE;
DROP FUNCTION IF EXISTS check_database_integrity() CASCADE;
DROP FUNCTION IF EXISTS validate_config_changes() CASCADE;
DROP FUNCTION IF EXISTS update_conversation_last_activity() CASCADE;

-- ---------- SECCIÓN 1: FUNCIONES BÁSICAS DE UTILIDAD ----------

-- Función para actualizar campo "updated_at" automáticamente
CREATE OR REPLACE FUNCTION update_modified_column() 
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW; 
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función para incrementar contador de clics (Mejorada con lock explícito)
CREATE OR REPLACE FUNCTION increment_link_clicks() 
RETURNS TRIGGER AS $$
BEGIN
    -- Bloquear el registro para evitar condiciones de carrera
    PERFORM id FROM links WHERE id = NEW.link_id FOR UPDATE;
    
    -- Incrementar contador
    UPDATE links SET 
        click_count = click_count + 1,
        updated_at = NOW()
    WHERE id = NEW.link_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 2: FUNCIONES DE PERMISOS Y ROLES ----------

-- Función para verificar si un usuario es administrador
CREATE OR REPLACE FUNCTION is_admin(user_uuid UUID) 
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar null
  IF user_uuid IS NULL THEN
    RETURN FALSE;
  END IF;
  
  -- Verificar rol de admin
  RETURN EXISTS (
    SELECT 1 FROM user_roles 
    WHERE user_id = user_uuid AND role = 'admin'
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al verificar rol de administrador: %', SQLERRM;
  RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función para verificar permisos específicos
CREATE OR REPLACE FUNCTION has_permission(
  user_uuid UUID,
  permission_name TEXT
) 
RETURNS BOOLEAN AS $$
DECLARE
  v_role VARCHAR(20);
  v_permissions JSONB;
BEGIN
  -- Verificar si es admin (tiene todos los permisos)
  IF is_admin(user_uuid) THEN
    RETURN TRUE;
  END IF;
  
  -- Buscar rol y permisos del usuario
  SELECT role, permissions INTO v_role, v_permissions
  FROM user_roles
  WHERE user_id = user_uuid;
  
  -- Si no tiene rol asignado, no tiene permisos
  IF v_role IS NULL THEN
    RETURN FALSE;
  END IF;
  
  -- Verificar permiso específico en el JSONB de permisos
  IF v_permissions IS NOT NULL AND 
     v_permissions ? permission_name AND
     v_permissions->>permission_name = 'true' THEN
    RETURN TRUE;
  END IF;
  
  -- Verificar permisos por rol predefinido
  RETURN 
    (v_role = 'moderator' AND permission_name IN (
      'manage_users', 'view_analytics', 'review_content'
    )) OR
    (v_role = 'support' AND permission_name IN (
      'view_users', 'reset_passwords', 'view_basic_analytics'
    )) OR
    (v_role = 'developer' AND permission_name IN (
      'manage_bots', 'manage_collections', 'manage_api_keys', 'view_system_logs'
    ));
    
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error al verificar permiso %: %', permission_name, SQLERRM;
  RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 3: SISTEMA DE LOGGING Y ERRORES ----------

-- Función para registrar errores del sistema
CREATE OR REPLACE FUNCTION log_system_error(
  p_user_id UUID,
  p_error_type VARCHAR(50),
  p_error_message TEXT,
  p_severity VARCHAR(20) DEFAULT 'error',
  p_source VARCHAR(50) DEFAULT NULL,
  p_context JSONB DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
  v_error_id UUID;
  v_context JSONB := p_context;
BEGIN
  -- Validar severidad
  IF p_severity NOT IN ('info', 'warning', 'error', 'critical') THEN
    p_severity := 'error';
  END IF;
  
  -- Agregar timestamp al contexto
  v_context := jsonb_set(v_context, '{timestamp}', to_jsonb(NOW()));
  
  -- Agregar a sistema de logs
  INSERT INTO system_errors (
    user_id, error_type, error_message, 
    severity, source, context
  )
  VALUES (
    p_user_id, p_error_type, p_error_message, 
    p_severity, p_source, v_context
  )
  RETURNING id INTO v_error_id;
  
  -- Log crítico, notificar a administradores
  IF p_severity = 'critical' THEN
    -- Aquí podría agregarse código para enviar notificaciones
    RAISE WARNING 'ERROR CRÍTICO: % - %', p_error_type, p_error_message;
  END IF;
  
  RETURN v_error_id;
EXCEPTION WHEN OTHERS THEN
  -- Fallback para errores durante el logging
  RAISE WARNING 'Error al registrar error: %', SQLERRM;
  RETURN extensions.uuid_generate_v4(); -- Devolver un UUID para evitar nulos
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 4: GESTIÓN DE CUOTAS DE USUARIO ----------

-- Función para verificar cuotas (Mejorada con locks explícitos)
CREATE OR REPLACE FUNCTION check_user_quota(
  p_user_id UUID,
  p_quota_type TEXT
) RETURNS BOOLEAN AS $$
DECLARE
  v_count INTEGER;
  v_quota INTEGER;
  v_quota_key TEXT;
  v_year_month INTEGER;
  v_usage_id UUID;
  v_daily_breakdown JSONB;
  v_today TEXT;
BEGIN
  -- Verificar parámetros
  IF p_user_id IS NULL OR p_quota_type IS NULL THEN
    RETURN FALSE;
  END IF;

  -- Verificar si es admin (los administradores no tienen límites)
  IF is_admin(p_user_id) THEN
    RETURN TRUE;
  END IF;

  -- Determinar la clave de configuración basada en el tipo de cuota
  CASE p_quota_type
    WHEN 'bots' THEN v_quota_key := 'default_user_quota_bots';
    WHEN 'collections' THEN v_quota_key := 'default_user_quota_collections';
    WHEN 'documents' THEN v_quota_key := 'default_user_quota_documents';
    WHEN 'vector_searches' THEN v_quota_key := 'default_user_quota_vector_searches';
    ELSE
      -- Tipo de cuota inválido
      PERFORM log_system_error(
        p_user_id, 
        'quota_check_error', 
        'Tipo de cuota inválido: ' || p_quota_type,
        'warning'
      );
      RETURN FALSE;
  END CASE;
  
  -- Obtener la cuota específica del usuario usando la función tipada
  v_quota := get_config_int(p_user_id, v_quota_key, 0);
  
  -- Si la cuota es 0 o negativa, significa ilimitado para casos especiales
  IF v_quota <= 0 THEN
    RETURN TRUE;
  END IF;
  
  -- Contar recursos actuales (considerando soft delete donde aplique)
  CASE p_quota_type
    WHEN 'bots' THEN
      SELECT COUNT(*) INTO v_count FROM bots 
      WHERE user_id = p_user_id AND deleted_at IS NULL;
    WHEN 'collections' THEN
      SELECT COUNT(*) INTO v_count FROM document_collections 
      WHERE user_id = p_user_id AND deleted_at IS NULL;
    WHEN 'documents' THEN
      SELECT COUNT(*) INTO v_count FROM documents 
      WHERE collection_id IN (
        SELECT id FROM document_collections 
        WHERE user_id = p_user_id AND deleted_at IS NULL
      ) AND deleted_at IS NULL;
    WHEN 'vector_searches' THEN
      -- Para vector_searches es uso diario
      SELECT COUNT(*) INTO v_count FROM vector_analytics 
      WHERE user_id = p_user_id AND DATE(created_at) = CURRENT_DATE;
    ELSE
      v_count := 0;
  END CASE;
  
  -- Obtener año-mes actual para registros
  v_year_month := EXTRACT(YEAR FROM CURRENT_DATE) * 100 + EXTRACT(MONTH FROM CURRENT_DATE);
  v_today := TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');
  
  -- Actualizar métricas de uso mensual con lock explícito
  SELECT id, daily_breakdown INTO v_usage_id, v_daily_breakdown
  FROM usage_metrics 
  WHERE user_id = p_user_id AND metric_type = p_quota_type AND year_month = v_year_month
  FOR UPDATE; -- Lock explícito
  
  IF v_usage_id IS NULL THEN
    -- Nuevo registro para este mes
    INSERT INTO usage_metrics (
      user_id, metric_type, count, year_month, quota_limit, 
      daily_breakdown, quota_reset_date
    )
    VALUES (
      p_user_id, p_quota_type, 1, v_year_month, v_quota,
      jsonb_build_object(v_today, 1),
      DATE_TRUNC('MONTH', CURRENT_DATE) + INTERVAL '1 MONTH'
    )
    RETURNING id INTO v_usage_id;
  ELSE
    -- Actualizar registro existente con incremento y desglose diario
    IF v_daily_breakdown ? v_today THEN
      v_daily_breakdown := jsonb_set(
        v_daily_breakdown, 
        ARRAY[v_today], 
        to_jsonb((v_daily_breakdown->>v_today)::INT + 1)
      );
    ELSE
      v_daily_breakdown := jsonb_set(
        v_daily_breakdown, 
        ARRAY[v_today], 
        to_jsonb(1)
      );
    END IF;
    
    UPDATE usage_metrics 
    SET 
      count = count + 1, 
      daily_breakdown = v_daily_breakdown,
      updated_at = NOW()
    WHERE id = v_usage_id;
  END IF;
  
  RETURN v_count < v_quota;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 5: VALIDACIÓN Y GESTIÓN DE CONFIGURACIÓN ----------

-- Función para validar valores de configuración
CREATE OR REPLACE FUNCTION validate_config_value(
  p_value TEXT,
  p_data_type TEXT,
  p_min_value TEXT,
  p_max_value TEXT
) RETURNS TEXT AS $$
DECLARE
  v_is_valid BOOLEAN := TRUE;
  v_message TEXT;
BEGIN
  -- Verificar NULL
  IF p_value IS NULL THEN
    RAISE EXCEPTION 'El valor no puede ser NULL';
  END IF;
  
  -- Validar según tipo
  CASE p_data_type
    WHEN 'integer' THEN
      -- Verificar que es un número entero válido
      IF p_value !~ '^[0-9]+$' THEN
        v_is_valid := FALSE;
        v_message := 'El valor debe ser un número entero';
      -- Verificar mínimo
      ELSIF p_min_value IS NOT NULL AND p_value::INTEGER < p_min_value::INTEGER THEN
        v_is_valid := FALSE;
        v_message := 'El valor no puede ser menor que ' || p_min_value;
      -- Verificar máximo
      ELSIF p_max_value IS NOT NULL AND p_value::INTEGER > p_max_value::INTEGER THEN
        v_is_valid := FALSE;
        v_message := 'El valor no puede ser mayor que ' || p_max_value;
      END IF;
      
    WHEN 'boolean' THEN
      -- Normalizar valores booleanos
      IF p_value IN ('true', 't', '1') THEN
        RETURN 'true';
      ELSIF p_value IN ('false', 'f', '0') THEN
        RETURN 'false';
      ELSE
        v_is_valid := FALSE;
        v_message := 'El valor debe ser un booleano (true/false)';
      END IF;
      
    WHEN 'json' THEN
      -- Verificar que es JSON válido
      BEGIN
        PERFORM jsonb_typeof(p_value::jsonb);
      EXCEPTION WHEN OTHERS THEN
        v_is_valid := FALSE;
        v_message := 'El valor debe ser un JSON válido: ' || SQLERRM;
      END;
  END CASE;
  
  IF NOT v_is_valid THEN
    RAISE EXCEPTION 'Validación fallida: %', v_message;
  END IF;
  
  RETURN p_value;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función para establecer configuración de usuario (Mejorada con transacción explícita)
CREATE OR REPLACE FUNCTION set_user_config(
  p_admin_id UUID,
  p_user_id UUID,
  p_config_key TEXT,
  p_value TEXT,
  p_override_reason TEXT DEFAULT 'Configuración manual desde backoffice'
) RETURNS BOOLEAN AS $$
DECLARE
  v_is_valid BOOLEAN;
  v_config_record RECORD;
  v_old_value TEXT;
  v_audit_id UUID;
BEGIN
  -- Iniciar transacción explícita
  BEGIN
    -- Verificar parámetros
    IF p_admin_id IS NULL OR p_user_id IS NULL OR p_config_key IS NULL THEN
      RAISE EXCEPTION 'Parámetros no pueden ser NULL';
    END IF;
  
    -- Verificar que quien ejecuta es admin o tiene permiso
    IF NOT is_admin(p_admin_id) AND NOT has_permission(p_admin_id, 'manage_user_configs') THEN
      RAISE EXCEPTION 'Operación no autorizada. Se requieren permisos de administrador.';
    END IF;
    
    -- Verificar que el usuario existe
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id AND deleted_at IS NULL) THEN
      RAISE EXCEPTION 'Usuario no existe o está eliminado';
    END IF;
    
    -- Verificar que la clave de configuración existe
    SELECT * INTO v_config_record FROM app.system_config WHERE key = p_config_key;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Clave de configuración % no existe', p_config_key;
    END IF;
    
    -- Verificar que la configuración es editable
    IF NOT v_config_record.editable THEN
      RAISE EXCEPTION 'La configuración % no es editable', p_config_key;
    END IF;
    
    -- Validar valor según tipo
    p_value := validate_config_value(
      p_value, 
      v_config_record.data_type, 
      v_config_record.min_value, 
      v_config_record.max_value
    );
    
    -- Obtener valor anterior si existe
    SELECT value INTO v_old_value
    FROM user_config
    WHERE user_id = p_user_id AND config_key = p_config_key;
    
    -- Insertar o actualizar configuración
    INSERT INTO user_config (
      user_id, config_key, value, override_reason, created_by
    )
    VALUES (
      p_user_id, p_config_key, p_value, p_override_reason, p_admin_id
    )
    ON CONFLICT (user_id, config_key)
    DO UPDATE SET 
      value = EXCLUDED.value,
      override_reason = EXCLUDED.override_reason,
      created_by = EXCLUDED.created_by,
      updated_at = NOW();
    
    -- Registrar en auditoría
    INSERT INTO audit.config_changes (
      config_key, old_value, new_value, change_type, changed_by
    ) VALUES (
      p_config_key || ':' || p_user_id::TEXT,
      v_old_value,
      p_value,
      CASE WHEN v_old_value IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
      p_admin_id::TEXT
    )
    RETURNING id INTO v_audit_id;
    
    -- Registrar acción para monitoring
    PERFORM log_system_error(
      p_admin_id,
      'config_change',
      'Cambio de configuración para usuario',
      'info',
      'admin_action',
      jsonb_build_object(
        'target_user', p_user_id,
        'config_key', p_config_key,
        'old_value', v_old_value,
        'new_value', p_value,
        'reason', p_override_reason,
        'audit_id', v_audit_id
      )
    );
    
    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN
    -- Capturar y registrar error
    PERFORM log_system_error(
      p_admin_id,
      'config_change_error',
      'Error al cambiar configuración: ' || SQLERRM,
      'error',
      'admin_action',
      jsonb_build_object(
        'target_user', p_user_id,
        'config_key', p_config_key,
        'value', p_value
      )
    );
    RAISE;
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función para gestión en masa de configuración (actualizada con esquema app)
CREATE OR REPLACE FUNCTION bulk_update_config_by_plan(
  p_admin_id UUID,
  p_plan_type VARCHAR(20),
  p_config_key TEXT,
  p_value TEXT,
  p_override_reason TEXT DEFAULT 'Actualización masiva por plan',
  p_apply_to_users BOOLEAN DEFAULT TRUE
) RETURNS INTEGER AS $$
DECLARE
  v_updated_count INTEGER := 0;
  v_user_record RECORD;
  v_config_record RECORD;
  v_old_value TEXT;
BEGIN
  -- Iniciar transacción explícita
  BEGIN
    -- Verificar parámetros
    IF p_admin_id IS NULL OR p_plan_type IS NULL OR p_config_key IS NULL THEN
      RAISE EXCEPTION 'Parámetros no pueden ser NULL';
    END IF;
  
    -- Verificar que quien ejecuta es admin
    IF NOT is_admin(p_admin_id) AND NOT has_permission(p_admin_id, 'manage_subscription_configs') THEN
      RAISE EXCEPTION 'Operación no autorizada. Se requieren permisos de administrador.';
    END IF;
    
    -- Verificar que el tipo de plan es válido
    IF p_plan_type NOT IN ('free', 'basic', 'premium', 'enterprise') THEN
      RAISE EXCEPTION 'Tipo de plan % no válido', p_plan_type;
    END IF;
    
    -- Verificar que la clave de configuración existe
    SELECT * INTO v_config_record FROM app.system_config WHERE key = p_config_key;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Clave de configuración % no existe', p_config_key;
    END IF;
    
    -- Validar valor según tipo
    p_value := validate_config_value(
      p_value, 
      v_config_record.data_type, 
      v_config_record.min_value, 
      v_config_record.max_value
    );
    
    -- Obtener valor anterior
    SELECT value INTO v_old_value
    FROM subscription_plan_config
    WHERE plan_type = p_plan_type AND config_key = p_config_key;
    
    -- Actualizar la configuración en la tabla subscription_plan_config
    INSERT INTO subscription_plan_config (plan_type, config_key, value)
    VALUES (p_plan_type, p_config_key, p_value)
    ON CONFLICT (plan_type, config_key)
    DO UPDATE SET 
      value = EXCLUDED.value,
      updated_at = NOW();
    
    -- Registrar en auditoría
    INSERT INTO audit.config_changes (
      config_key, old_value, new_value, change_type, changed_by
    ) VALUES (
      'plan:' || p_plan_type || ':' || p_config_key,
      v_old_value,
      p_value,
      CASE WHEN v_old_value IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
      p_admin_id::TEXT
    );
    
    -- Si se indica, aplicar a todos los usuarios con ese plan
    IF p_apply_to_users THEN
      FOR v_user_record IN 
        SELECT user_id 
        FROM subscriptions 
        WHERE plan_type = p_plan_type AND status = 'active'
      LOOP
        BEGIN
          PERFORM set_user_config(
            p_admin_id, 
            v_user_record.user_id, 
            p_config_key, 
            p_value, 
            p_override_reason || ' (Plan: ' || p_plan_type || ')'
          );
          v_updated_count := v_updated_count + 1;
        EXCEPTION WHEN OTHERS THEN
          -- Registrar error pero continuar con el siguiente usuario
          PERFORM log_system_error(
            p_admin_id,
            'config_bulk_update_error',
            'Error al actualizar configuración para usuario ' || v_user_record.user_id,
            'warning',
            'bulk_update',
            jsonb_build_object(
              'plan', p_plan_type,
              'config_key', p_config_key,
              'error', SQLERRM
            )
          );
        END;
      END LOOP;
    END IF;
    
    -- Registrar acción completa
    PERFORM log_system_error(
      p_admin_id,
      'bulk_config_change',
      'Actualización masiva de configuración para plan ' || p_plan_type,
      'info',
      'admin_action',
      jsonb_build_object(
        'plan_type', p_plan_type,
        'config_key', p_config_key,
        'old_value', v_old_value,
        'new_value', p_value,
        'users_updated', v_updated_count,
        'apply_to_users', p_apply_to_users
      )
    );
    
    RETURN v_updated_count;
  EXCEPTION WHEN OTHERS THEN
    -- Capturar y registrar error
    PERFORM log_system_error(
      p_admin_id,
      'bulk_config_change_error',
      'Error en actualización masiva: ' || SQLERRM,
      'error',
      'admin_action',
      jsonb_build_object(
        'plan_type', p_plan_type,
        'config_key', p_config_key
      )
    );
    RAISE;
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 6: FUNCIONES DE VECTOR EMBEDDING ----------

-- Función para actualizar dimensiones de vectores
CREATE OR REPLACE FUNCTION update_vector_dimensions() 
RETURNS BOOLEAN AS $$
DECLARE
  new_dim INTEGER;
BEGIN
  -- Obtener nueva dimensión de configuración
  SELECT get_vector_dimension() INTO new_dim;
  
  -- Llamar a la función de actualización de columnas vectoriales
  PERFORM update_vector_fields_to_current_dimension();
  
  -- Registrar acción
  PERFORM log_system_error(
    NULL, -- Sistema
    'vector_dimension_update',
    'Dimensiones vectoriales actualizadas a ' || new_dim,
    'info',
    'system',
    jsonb_build_object(
      'new_dimension', new_dim,
      'tables_updated', 3 -- document_chunks, messages, vector_analytics
    )
  );
  
  RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
  PERFORM log_system_error(
    NULL, -- Sistema
    'vector_dimension_update_error',
    'Error al actualizar dimensiones vectoriales: ' || SQLERRM,
    'error',
    'system',
    jsonb_build_object(
      'new_dimension', new_dim
    )
  );
  
  RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 7: TRIGGERS DE VALIDACIÓN DE CUOTA ----------

-- Trigger para verificar cuota de bots
CREATE OR REPLACE FUNCTION enforce_bot_quota() RETURNS TRIGGER AS $$
BEGIN
  -- Verificar si el usuario está dentro de su cuota de bots
  IF NOT check_user_quota(NEW.user_id, 'bots') THEN
    PERFORM log_system_error(
      NEW.user_id, 
      'quota_exceeded', 
      'Bot quota exceeded for user', 
      'warning',
      'quota_check',
      jsonb_build_object('attempted_bot_name', NEW.name)
    );
    RAISE EXCEPTION 'Has alcanzado el límite de bots permitidos para tu plan. Por favor, actualiza tu suscripción para crear más bots.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Trigger para verificar cuota de colecciones
CREATE OR REPLACE FUNCTION enforce_collection_quota() RETURNS TRIGGER AS $$
BEGIN
  -- Verificar si el usuario está dentro de su cuota de colecciones
  IF NOT check_user_quota(NEW.user_id, 'collections') THEN
    PERFORM log_system_error(
      NEW.user_id, 
      'quota_exceeded', 
      'Collection quota exceeded for user', 
      'warning',
      'quota_check',
      jsonb_build_object('attempted_collection_name', NEW.name)
    );
    RAISE EXCEPTION 'Has alcanzado el límite de colecciones permitidas para tu plan. Por favor, actualiza tu suscripción para crear más colecciones.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Trigger para verificar cuota de documentos
CREATE OR REPLACE FUNCTION enforce_document_quota() RETURNS TRIGGER AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- Obtener el ID del usuario propietario de la colección
  SELECT user_id INTO v_user_id 
  FROM document_collections 
  WHERE id = NEW.collection_id;
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Colección no encontrada o sin propietario válido';
  END IF;
  
  -- Verificar si el usuario está dentro de su cuota de documentos
  IF NOT check_user_quota(v_user_id, 'documents') THEN
    PERFORM log_system_error(
      v_user_id, 
      'quota_exceeded', 
      'Document quota exceeded for user', 
      'warning',
      'quota_check',
      jsonb_build_object(
        'attempted_document_title', NEW.title, 
        'collection_id', NEW.collection_id
      )
    );
    RAISE EXCEPTION 'Has alcanzado el límite de documentos permitidos para tu plan. Por favor, actualiza tu suscripción para añadir más documentos.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Trigger para verificar cuota de búsquedas vectoriales
CREATE OR REPLACE FUNCTION enforce_vector_search_quota() RETURNS TRIGGER AS $$
BEGIN
  -- Verificar si el usuario está dentro de su cuota diaria de búsquedas
  IF NOT check_user_quota(NEW.user_id, 'vector_searches') THEN
    PERFORM log_system_error(
      NEW.user_id, 
      'quota_exceeded', 
      'Vector search quota exceeded for user', 
      'warning',
      'quota_check',
      jsonb_build_object('query', NEW.query)
    );
    RAISE EXCEPTION 'Has alcanzado el límite diario de búsquedas vectoriales para tu plan. Por favor, intenta de nuevo mañana o actualiza tu suscripción.';
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 8: FUNCIONES DE MANTENIMIENTO Y DIAGNÓSTICO ----------

-- Función para regenerar embeddings para documentos
CREATE OR REPLACE FUNCTION queue_document_for_embedding(
  p_document_id UUID
) RETURNS BOOLEAN AS $$
BEGIN
  -- Marcar documento para reprocesamiento
  UPDATE documents
  SET 
    processing_status = 'pending',
    updated_at = NOW()
  WHERE id = p_document_id;
  
  -- Registrar acción
  PERFORM log_system_error(
    NULL, -- Sistema
    'document_reindex',
    'Documento en cola para reprocesamiento',
    'info',
    'embedding',
    jsonb_build_object(
      'document_id', p_document_id
    )
  );
  
  RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
  PERFORM log_system_error(
    NULL,
    'document_reindex_error',
    'Error al poner documento en cola: ' || SQLERRM,
    'error',
    'embedding',
    jsonb_build_object(
      'document_id', p_document_id
    )
  );
  
  RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función para regenerar embeddings para colecciones completas
CREATE OR REPLACE FUNCTION queue_collection_for_embedding(
  p_collection_id UUID
) RETURNS INTEGER AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  -- Marcar todos los documentos para reprocesamiento
  UPDATE documents
  SET 
    processing_status = 'pending',
    updated_at = NOW()
  WHERE 
    collection_id = p_collection_id AND
    deleted_at IS NULL
  RETURNING COUNT(*) INTO v_count;
  
  -- Registrar acción
  PERFORM log_system_error(
    NULL, -- Sistema
    'collection_reindex',
    'Colección en cola para reprocesamiento',
    'info',
    'embedding',
    jsonb_build_object(
      'collection_id', p_collection_id,
      'document_count', v_count
    )
  );
  
  RETURN v_count;
EXCEPTION WHEN OTHERS THEN
  PERFORM log_system_error(
    NULL,
    'collection_reindex_error',
    'Error al poner colección en cola: ' || SQLERRM,
    'error',
    'embedding',
    jsonb_build_object(
      'collection_id', p_collection_id
    )
  );
  
  RETURN 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Función para verificación de integridad de la base de datos
CREATE OR REPLACE FUNCTION check_database_integrity() 
RETURNS JSONB AS $$
DECLARE
  result JSONB := '{"issues": []}';
  v_missing_vectors INTEGER;
  v_orphaned_chunks INTEGER;
  v_orphaned_configs INTEGER;
BEGIN
  -- Verificar vectores faltantes
  SELECT COUNT(*) INTO v_missing_vectors
  FROM document_chunks
  WHERE content_vector IS NULL;
  
  IF v_missing_vectors > 0 THEN
    result := jsonb_set(result, '{issues}', result->'issues' || jsonb_build_object(
      'type', 'missing_vectors',
      'count', v_missing_vectors,
      'description', 'Chunks sin vectores de embeddings'
    ));
  END IF;
  
  -- Verificar chunks huérfanos
  SELECT COUNT(*) INTO v_orphaned_chunks
  FROM document_chunks dc
  LEFT JOIN documents d ON dc.document_id = d.id
  WHERE d.id IS NULL;
  
  IF v_orphaned_chunks > 0 THEN
    result := jsonb_set(result, '{issues}', result->'issues' || jsonb_build_object(
      'type', 'orphaned_chunks',
      'count', v_orphaned_chunks,
      'description', 'Chunks sin documento padre'
    ));
  END IF;
  
  -- Verificar configuraciones huérfanas
  SELECT COUNT(*) INTO v_orphaned_configs
  FROM user_config uc
  LEFT JOIN users u ON uc.user_id = u.id
  WHERE u.id IS NULL;
  
  IF v_orphaned_configs > 0 THEN
    result := jsonb_set(result, '{issues}', result->'issues' || jsonb_build_object(
      'type', 'orphaned_configs',
      'count', v_orphaned_configs,
      'description', 'Configuraciones para usuarios inexistentes'
    ));
  END IF;
  
  -- Añadir resumen
  result := jsonb_set(result, '{summary}', jsonb_build_object(
    'has_issues', (v_missing_vectors + v_orphaned_chunks + v_orphaned_configs) > 0,
    'total_issues', v_missing_vectors + v_orphaned_chunks + v_orphaned_configs,
    'checked_at', NOW()
  ));
  
  -- Registrar resultados
  PERFORM log_system_error(
    NULL, -- Sistema
    'db_integrity_check',
    'Verificación de integridad de base de datos',
    CASE WHEN (v_missing_vectors + v_orphaned_chunks + v_orphaned_configs) > 0 THEN 'warning' ELSE 'info' END,
    'system',
    result
  );
  
  RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN 9: TRIGGERS DE ACTUALIZACIÓN ----------

-- Trigger para validar configuración al insertar o actualizar
CREATE OR REPLACE FUNCTION validate_config_changes() RETURNS TRIGGER AS $$
BEGIN
  -- Validar valor según el tipo de dato
  BEGIN
    NEW.value := validate_config_value(
      NEW.value, NEW.data_type, NEW.min_value, NEW.max_value
    );
    RETURN NEW;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error en configuración: %', SQLERRM;
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- Trigger para actualizar campo last_activity_at en conversaciones
CREATE OR REPLACE FUNCTION update_conversation_last_activity() RETURNS TRIGGER AS $$
BEGIN
  UPDATE conversations 
  SET 
    last_activity_at = NOW(),
    updated_at = NOW()
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, app, extensions;

-- ---------- SECCIÓN FINAL: NOTIFICACIÓN ----------

DO $$
BEGIN
  RAISE NOTICE 'Funciones y triggers creados correctamente con mejoras de concurrencia y seguridad.';
END $$;