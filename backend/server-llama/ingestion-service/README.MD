# Servicio de Ingestión LlamaIndex

Este servicio forma parte de la plataforma Linktree AI y se encarga del procesamiento e indexación de documentos en un entorno multitenancy.

## Características

- Procesamiento de documentos en texto plano y archivos
- Chunking automático con control de tamaño y solapamiento
- Generación de embeddings a través de OpenAI
- Aislamiento completo entre tenants
- Control de cuotas según nivel de suscripción
- Procesamiento asíncrono para mejorar la experiencia del usuario
- Almacenamiento vectorial en Supabase

## Requisitos

- Python 3.10+
- Supabase (cuenta y proyecto configurado)
- API Key de OpenAI
- Redis (opcional, para caché)

## Configuración

1. Copia el archivo `.env.example` a `.env` y ajusta los valores:

```
cp .env.example .env
```

2. Edita el archivo `.env` con tus credenciales:

```
SUPABASE_URL=https://your-supabase-project.supabase.co
SUPABASE_KEY=your-supabase-service-key
OPENAI_API_KEY=your-openai-api-key
```

3. Configura el esquema de la base de datos ejecutando el script SQL en tu proyecto Supabase:

```
supabase_schema.sql
```

## Instalación y Ejecución

### Usando Docker (recomendado)

```bash
docker-compose up -d
```

### Instalación local

```bash
pip install -r requirements.txt
uvicorn ingestion_service:app --reload
```

## Endpoints API

### POST /ingest
Procesa documentos en texto plano.

**Request:**
```json
{
  "tenant_id": "123e4567-e89b-12d3-a456-426614174000",
  "documents": ["Contenido del documento 1", "Contenido del documento 2"],
  "document_metadatas": [
    {
      "source": "manual",
      "author": "Juan Pérez",
      "document_type": "policy",
      "tenant_id": "123e4567-e89b-12d3-a456-426614174000"
    },
    {
      "source": "website",
      "author": "Ana García",
      "document_type": "faq",
      "tenant_id": "123e4567-e89b-12d3-a456-426614174000"
    }
  ],
  "collection_name": "policies"
}
```

### POST /ingest-file
Procesa archivos subidos (multipart/form-data).

**Form Fields:**
- `file`: Archivo a procesar
- `tenant_id`: ID del tenant
- `collection_name`: (Opcional) Nombre de la colección
- `document_type`: Tipo de documento
- `author`: (Opcional) Autor del documento

### DELETE /documents/{tenant_id}/{document_id}
Elimina un documento específico de un tenant.

### DELETE /collections/{tenant_id}/{collection_name}
Elimina toda una colección de documentos de un tenant.

## Arquitectura

El servicio sigue una arquitectura de microservicios y utiliza:

- FastAPI para la API REST
- LlamaIndex para procesamiento de documentos
- OpenAI para generación de embeddings
- Supabase como base de datos vectorial
- Redis para caché (opcional)

## Estructura del Proyecto

```
.
├── Dockerfile
├── docker-compose.yml
├── ingestion_service.py
├── requirements.txt
├── .env.example
└── supabase_schema.sql
```

## Límites por Plan

| Plan | Documentos Máximos | Knowledge Bases | RAG Avanzado |
|------|-------------------|----------------|--------------|
| Free | 20                | 1              | No           |
| Pro  | 100               | 5              | Sí           |
| Business | 500           | 20             | Sí           |