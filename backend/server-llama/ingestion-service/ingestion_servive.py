import os
from typing import List, Dict, Any, Optional
import uuid
from fastapi import FastAPI, HTTPException, Depends, BackgroundTasks, UploadFile, File, Form
from pydantic import BaseModel
import httpx
from supabase import create_client, Client
import redis
from redis.exceptions import ConnectionError

# LlamaIndex imports
from llama_index.core import (
    SimpleDirectoryReader,
    Document,
    StorageContext,
    load_index_from_storage,
)
from llama_index.core.node_parser import SimpleNodeParser
from llama_index.core.schema import MetadataMode
from llama_index.vector_stores.supabase import SupabaseVectorStore
from llama_index.embeddings.openai import OpenAIEmbedding

# FastAPI app
app = FastAPI(title="Linktree AI - Ingestion Service")

# Configuration
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")

# Redis connection for caching
try:
    redis_client = redis.from_url(REDIS_URL)
except ConnectionError:
    print("Warning: Redis connection failed. Running without cache.")
    redis_client = None

# Supabase client
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# OpenAI Embedding model
embed_model = OpenAIEmbedding(
    model_name="text-embedding-3-small",
    api_key=OPENAI_API_KEY,
    embed_batch_size=100  # Process 100 texts at once for efficiency
)

# Pydantic models
class TenantInfo(BaseModel):
    tenant_id: str
    subscription_tier: str  # "free", "pro", "business"

class DocumentMetadata(BaseModel):
    source: str
    author: Optional[str] = None
    created_at: Optional[str] = None
    document_type: str
    tenant_id: str
    custom_metadata: Optional[Dict[str, Any]] = None

class DocumentIngestionRequest(BaseModel):
    tenant_id: str
    documents: List[str] = []  # Text content of documents
    document_metadatas: List[DocumentMetadata] = []  # Metadata for each document
    collection_name: Optional[str] = "default"  # Collection/namespace for the documents

class IngestionResponse(BaseModel):
    success: bool
    message: str
    document_ids: List[str]
    nodes_count: int

# Dependency to verify tenant exists and subscription is active
async def verify_tenant(tenant_id: str) -> TenantInfo:
    tenant_data = supabase.table("tenants").select("*").eq("tenant_id", tenant_id).execute()
    
    if not tenant_data.data:
        raise HTTPException(status_code=404, detail=f"Tenant {tenant_id} not found")
    
    # Check if subscription is active
    subscription_data = supabase.table("tenant_subscriptions").select("*") \
        .eq("tenant_id", tenant_id) \
        .eq("is_active", True) \
        .execute()
    
    if not subscription_data.data:
        raise HTTPException(status_code=403, detail=f"No active subscription for tenant {tenant_id}")
    
    return TenantInfo(
        tenant_id=tenant_id,
        subscription_tier=subscription_data.data[0]["subscription_tier"]
    )

# Check tenant quotas
async def check_tenant_quotas(tenant_info: TenantInfo) -> bool:
    # Get tenant's current usage
    usage_data = supabase.table("tenant_stats").select("*") \
        .eq("tenant_id", tenant_info.tenant_id) \
        .execute()
    
    if not usage_data.data:
        # No usage data yet, they're under quota
        return True
    
    current_usage = usage_data.data[0]
    
    # Get limits based on subscription tier
    tier_limits = supabase.table("tenant_features").select("*") \
        .eq("tier", tenant_info.subscription_tier) \
        .execute()
    
    if not tier_limits.data:
        raise HTTPException(status_code=500, detail="Subscription tier limits not found")
    
    limits = tier_limits.data[0]
    
    # Check document count
    if current_usage["document_count"] >= limits["max_docs"]:
        raise HTTPException(status_code=429, detail="Document limit reached for your subscription tier")
    
    return True

# Function to get vector store for a tenant
def get_tenant_vector_store(tenant_id: str, collection_name: str) -> SupabaseVectorStore:
    # Initialize the Supabase vector store
    vector_store = SupabaseVectorStore(
        client=supabase,
        table_name="document_chunks",  # From your schema
        content_field="content",
        embedding_field="embedding",
        metadata_field="metadata"
    )
    
    return vector_store

# Process document and create nodes
def process_document(
    doc_text: str, 
    metadata: DocumentMetadata,
    collection_name: str
) -> List[Dict[str, Any]]:
    # Create a LlamaIndex document
    document = Document(
        text=doc_text,
        metadata={
            "tenant_id": metadata.tenant_id,
            "source": metadata.source,
            "author": metadata.author,
            "created_at": metadata.created_at,
            "document_type": metadata.document_type,
            "collection": collection_name,
            **(metadata.custom_metadata or {})
        }
    )
    
    # Parse document into nodes
    parser = SimpleNodeParser.from_defaults(
        chunk_size=512,
        chunk_overlap=50
    )
    
    nodes = parser.get_nodes_from_documents([document])
    
    # Process all nodes and return node data
    node_data = []
    for node in nodes:
        node_id = str(uuid.uuid4())
        node_text = node.get_content(metadata_mode=MetadataMode.NONE)
        node_metadata = node.metadata
        
        node_data.append({
            "id": node_id,
            "text": node_text,
            "metadata": node_metadata
        })
    
    return node_data

# Background task to index documents
async def index_documents_task(
    node_data_list: List[Dict[str, Any]],
    tenant_id: str,
    collection_name: str
):
    try:
        # Get vector store for tenant
        vector_store = get_tenant_vector_store(tenant_id, collection_name)
        
        # Extract texts for batch embedding
        texts = [node["text"] for node in node_data_list]
        
        # Generate embeddings in batch
        embeddings = embed_model.get_text_embedding_batch(texts)
        
        # Add each node to vector store
        for i, node_data in enumerate(node_data_list):
            # Add document chunk to Supabase
            supabase.table("document_chunks").insert({
                "id": node_data["id"],
                "tenant_id": tenant_id,
                "content": node_data["text"],
                "metadata": node_data["metadata"],
                "embedding": embeddings[i]
            }).execute()
        
        # Update document count for tenant
        supabase.rpc(
            "increment_document_count",
            {"p_tenant_id": tenant_id, "p_count": 1}
        ).execute()
        
        print(f"Successfully indexed {len(node_data_list)} nodes for tenant {tenant_id}")
    except Exception as e:
        print(f"Error indexing documents: {str(e)}")
        # Log error to monitoring system

# API endpoints
@app.post("/ingest", response_model=IngestionResponse)
async def ingest_documents(
    request: DocumentIngestionRequest,
    background_tasks: BackgroundTasks,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    # Check quotas
    await check_tenant_quotas(tenant_info)
    
    if len(request.documents) != len(request.document_metadatas):
        raise HTTPException(
            status_code=400, 
            detail="Number of documents must match number of metadata objects"
        )
    
    document_ids = []
    all_nodes = []
    
    # Process each document
    for i, doc_text in enumerate(request.documents):
        metadata = request.document_metadatas[i]
        doc_id = str(uuid.uuid4())
        document_ids.append(doc_id)
        
        # Add document ID to metadata
        metadata.custom_metadata = metadata.custom_metadata or {}
        metadata.custom_metadata["document_id"] = doc_id
        
        # Process document to get nodes
        node_data = process_document(
            doc_text=doc_text,
            metadata=metadata,
            collection_name=request.collection_name
        )
        
        all_nodes.extend(node_data)
    
    # Schedule background task to index documents
    background_tasks.add_task(
        index_documents_task,
        all_nodes,
        request.tenant_id,
        request.collection_name
    )
    
    return IngestionResponse(
        success=True,
        message=f"Processing {len(request.documents)} documents with {len(all_nodes)} total chunks",
        document_ids=document_ids,
        nodes_count=len(all_nodes)
    )

@app.post("/ingest-file")
async def ingest_file(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    tenant_id: str = Form(...),
    collection_name: str = Form("default"),
    document_type: str = Form(...),
    author: Optional[str] = Form(None),
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    # Check quotas
    await check_tenant_quotas(tenant_info)
    
    # Read file content
    content = await file.read()
    file_text = content.decode("utf-8")
    
    # Create metadata
    metadata = DocumentMetadata(
        source=file.filename,
        author=author,
        created_at=None,  # Will be filled in by the system
        document_type=document_type,
        tenant_id=tenant_id,
        custom_metadata={"filename": file.filename}
    )
    
    # Generate document ID
    doc_id = str(uuid.uuid4())
    
    # Add document ID to metadata
    metadata.custom_metadata = metadata.custom_metadata or {}
    metadata.custom_metadata["document_id"] = doc_id
    
    # Process document to get nodes
    node_data = process_document(
        doc_text=file_text,
        metadata=metadata,
        collection_name=collection_name
    )
    
    # Schedule background task to index documents
    background_tasks.add_task(
        index_documents_task,
        node_data,
        tenant_id,
        collection_name
    )
    
    return {
        "success": True,
        "message": f"Processing file {file.filename} with {len(node_data)} chunks",
        "document_id": doc_id,
        "nodes_count": len(node_data)
    }

@app.delete("/documents/{tenant_id}/{document_id}")
async def delete_document(
    tenant_id: str,
    document_id: str,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    # Delete document chunks
    result = supabase.table("document_chunks").delete() \
        .eq("tenant_id", tenant_id) \
        .eq("metadata->>document_id", document_id) \
        .execute()
    
    # Update document count for tenant
    supabase.rpc(
        "decrement_document_count",
        {"p_tenant_id": tenant_id, "p_count": 1}
    ).execute()
    
    return {
        "success": True,
        "message": f"Document {document_id} deleted",
        "deleted_chunks": len(result.data) if result.data else 0
    }

@app.delete("/collections/{tenant_id}/{collection_name}")
async def delete_collection(
    tenant_id: str,
    collection_name: str,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    # Delete document chunks for this collection
    result = supabase.table("document_chunks").delete() \
        .eq("tenant_id", tenant_id) \
        .eq("metadata->>collection", collection_name) \
        .execute()
    
    # Update document count for tenant
    if result.data and len(result.data) > 0:
        # Estimate document count (this is approximate)
        doc_count = len(set([item["metadata"]["document_id"] for item in result.data if "document_id" in item["metadata"]]))
        
        supabase.rpc(
            "decrement_document_count",
            {"p_tenant_id": tenant_id, "p_count": doc_count}
        ).execute()
    
    return {
        "success": True,
        "message": f"Collection {collection_name} deleted for tenant {tenant_id}",
        "deleted_chunks": len(result.data) if result.data else 0
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)