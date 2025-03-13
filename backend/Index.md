# Sistema de Base de Datos - Índice

## init_1_C.sql - Configuración Inicial y Extensiones
### Extensiones
- uuid-ossp
- pg_trgm
- vector
- pgcrypto

### Esquemas
- public
- app
- extensions
- auth
- audit

### Tablas Base
- app.system_config
  - Campos: id, key, value, description, created_at, updated_at

## init_2_C.sql - Tablas Fundamentales
### Tablas
- themes (public)
  - Campos: id, name, properties, is_active
- app.users
  - Campos: id, email, username, status, metadata, settings
- app.user_config
- app.subscription_plan_config

### Vistas
- users
- user_config
- subscription_plan_config

## init_3_C.sql - Gestión de Usuarios
### Tablas
- public.profiles
- app.user_roles
- app.subscriptions
- app.user_role_history
- app.subscription_history

### Funciones
- sync_user_config_on_subscription_change()
- generate_unique_username()
- handle_new_user()

## init_4_C.sql - Sistema RAG
### Tablas
- public.bots
- app.document_collections
- app.documents
- app.document_chunks
- app.conversations
- app.messages

### Configuración
- Dimensiones vectoriales
- Parámetros de embeddings

## init_5_C.sql - Analytics y Enlaces
### Tablas
- public.links
- public.link_groups
- public.link_group_items
- app.analytics
- app.system_errors
- app.usage_metrics
- app.quota_notifications

## init_6_C.sql - Funciones Core
### Funciones
- update_modified_column()
- increment_link_clicks()
- is_admin()
- has_permission()
- check_user_quota()
- set_user_config()
- validate_config_value()

## init_7_C.sql - Triggers e Índices
### Triggers
- Actualización automática de timestamps
- Contadores de clicks
- Control de cuotas de usuario
- Tracking de última actividad

### Índices
- Búsqueda por texto
- Índices vectoriales
- Optimización de consultas frecuentes

## init_8_C.sql - Seguridad RLS
### Configuración RLS
- Limpieza inicial de políticas
- Activación de RLS en tablas

### Políticas
- Usuarios y perfiles
- Bots y colecciones
- Interacciones y mensajes
- Analytics y métricas
- Permisos de administrador

## init_9_C.sql - Vistas
### Vistas Regulares
- daily_user_activity
- users_with_roles
- bot_performance
- document_usage

### Vistas Materializadas
- bot_performance_mat
- user_activity_summary_mat
- public_bots_mat