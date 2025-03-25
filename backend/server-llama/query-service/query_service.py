import os
from typing import List, Dict, Any, Optional, Union
import uuid
import time
import json
import logging
from fastapi import FastAPI, HTTPException, Depends, BackgroundTasks, Request, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import httpx
from supabase import create_client, Client
import redis
from redis.exceptions import ConnectionError
from tenacity import retry, stop_after_attempt, wait_exponential

# LlamaIndex imports
from llama_index.core import (
    VectorStoreIndex,
    ServiceContext,
    StorageContext,
    Settings,
)
from llama_index.vector_stores.supabase import SupabaseVectorStore
from llama_index.embeddings.openai import OpenAIEmbedding
from llama_index.core.node_parser import SimpleNodeParser
from llama_index.core.retrievers import VectorIndexRetriever
from llama_index.llms.openai import OpenAI
from llama_index.core.response_synthesizers import ResponseSynthesizer
from llama_index.core.query_engine import RetrieverQueryEngine
from llama_index.core.postprocessor import SimilarityPostprocessor
from llama_index.core.schema import NodeWithScore
from llama_index.core.callbacks import CallbackManager, LlamaDebugHandler

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("query-service")

# FastAPI app
app = FastAPI(title="Linktree AI - Query Service")

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Specify your frontend domain in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")
DEFAULT_EMBEDDING_MODEL = os.environ.get("DEFAULT_EMBEDDING_MODEL", "text-embedding-3-small")
DEFAULT_LLM_MODEL = os.environ.get("DEFAULT_LLM_MODEL", "gpt-3.5-turbo")
EMBEDDINGS_SERVICE_URL = os.environ.get("EMBEDDINGS_SERVICE_URL", "http://embeddings-service:8001")

# Redis connection for caching
try:
    redis_client = redis.from_url(REDIS_URL)
    print("Redis connected successfully")
except ConnectionError:
    print("Warning: Redis connection failed. Running without cache.")
    redis_client = None

# Supabase client
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# Initialize HTTP client for embedding service
http_client = httpx.AsyncClient(timeout=30.0)

# Debug handler for LlamaIndex
llama_debug = LlamaDebugHandler(print_trace_on_end=False)
callback_manager = CallbackManager([llama_debug])

# Pydantic models
class TenantInfo(BaseModel):
    tenant_id: str
    subscription_tier: str  # "free", "pro", "business"

class QueryRequest(BaseModel):
    tenant_id: str
    query: str
    collection_name: Optional[str] = "default"
    llm_model: Optional[str] = None
    similarity_top_k: Optional[int] = 4
    additional_metadata_filter: Optional[Dict[str, Any]] = None
    response_mode: Optional[str] = "compact"  # compact, refine, tree
    stream: Optional[bool] = False

class QueryContextItem(BaseModel):
    text: str
    metadata: Optional[Dict[str, Any]] = None
    score: Optional[float] = None

class QueryResponse(BaseModel):
    tenant_id: str
    query: str
    response: str
    sources: List[QueryContextItem]
    processing_time: float
    llm_model: str
    collection_name: str

class HealthcheckResponse(BaseModel):
    status: str
    components: Dict[str, str]
    version: str

class DocumentsListRequest(BaseModel):
    tenant_id: str
    collection_name: Optional[str] = None
    limit: Optional[int] = 50
    offset: Optional[int] = 0

class DocumentsListResponse(BaseModel):
    tenant_id: str
    documents: List[Dict[str, Any]]
    total: int
    limit: int
    offset: int
    collection_name: Optional[str]

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
    
    # Check token usage
    if limits.get("max_tokens_per_month") and current_usage.get("tokens_used", 0) >= limits["max_tokens_per_month"]:
        raise HTTPException(status_code=429, detail="Monthly token limit reached for your subscription tier")
    
    return True

# Generate embeddings through the embeddings service
async def generate_embedding(text: str, tenant_id: str) -> List[float]:
    payload = {
        "tenant_id": tenant_id,
        "texts": [text]
    }
    
    try:
        response = await http_client.post(f"{EMBEDDINGS_SERVICE_URL}/embed", json=payload)
        response.raise_for_status()
        result = response.json()
        
        if result.get("embeddings") and len(result["embeddings"]) > 0:
            return result["embeddings"][0]
        else:
            raise ValueError("No embedding returned from service")
    except Exception as e:
        logger.error(f"Error getting embedding: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Error getting embedding: {str(e)}"
        )

# Class to fetch embeddings from the embedding service
class EmbeddingServiceProvider(OpenAIEmbedding):
    """Custom embedding provider that uses the embedding service."""
    
    def __init__(self, tenant_id: str):
        super().__init__(
            model_name=DEFAULT_EMBEDDING_MODEL,
        )
        self.tenant_id = tenant_id
    
    async def _aget_text_embedding(self, text: str) -> List[float]:
        return await generate_embedding(text, self.tenant_id)
    
    async def _aget_text_embedding_batch(self, texts: List[str]) -> List[List[float]]:
        payload = {
            "tenant_id": self.tenant_id,
            "texts": texts
        }
        
        try:
            response = await http_client.post(f"{EMBEDDINGS_SERVICE_URL}/embed", json=payload)
            response.raise_for_status()
            result = response.json()
            
            if result.get("embeddings"):
                return result["embeddings"]
            else:
                raise ValueError("No embeddings returned from service")
        except Exception as e:
            logger.error(f"Error getting batch embeddings: {str(e)}")
            # Fallback to individual requests
            results = []
            for text in texts:
                results.append(await self._aget_text_embedding(text))
            return results

# Get vector store for a tenant
def get_tenant_vector_store(tenant_id: str, collection_name: Optional[str] = None) -> SupabaseVectorStore:
    """Initialize a vector store for a specific tenant"""
    
    metadata_filters = {"tenant_id": tenant_id}
    if collection_name:
        metadata_filters["collection"] = collection_name
    
    vector_store = SupabaseVectorStore(
        client=supabase,
        table_name="document_chunks",
        content_field="content",
        embedding_field="embedding",
        metadata_field="metadata",
        metadata_filters=metadata_filters
    )
    
    return vector_store

# Create LLM based on tenant tier
def get_llm_for_tenant(tenant_info: TenantInfo, requested_model: Optional[str] = None) -> OpenAI:
    """Get appropriate LLM based on tenant subscription tier"""
    
    # Map subscription tiers to allowed models
    tier_models = {
        "free": ["gpt-3.5-turbo"],
        "pro": ["gpt-3.5-turbo", "gpt-4-turbo"],
        "business": ["gpt-3.5-turbo", "gpt-4-turbo", "gpt-4-turbo-vision", "claude-3-5-sonnet"]
    }
    
    # Default model based on tier
    default_models = {
        "free": "gpt-3.5-turbo",
        "pro": "gpt-4-turbo",
        "business": "gpt-4-turbo"
    }
    
    # Get allowed models for tenant tier
    allowed_models = tier_models.get(tenant_info.subscription_tier, ["gpt-3.5-turbo"])
    
    # Use requested model if specified and allowed, otherwise use default
    model_name = None
    if requested_model and requested_model in allowed_models:
        model_name = requested_model
    else:
        model_name = default_models.get(tenant_info.subscription_tier, "gpt-3.5-turbo")
    
    return OpenAI(
        model=model_name,
        temperature=0.1,
        api_key=OPENAI_API_KEY
    )

# Create QueryEngine for tenant
async def create_query_engine(
    tenant_info: TenantInfo,
    collection_name: str,
    llm_model: Optional[str] = None,
    similarity_top_k: int = 4,
    response_mode: str = "compact"
) -> RetrieverQueryEngine:
    """Create a query engine for retrieving and generating responses"""
    
    # Get the vector store
    vector_store = get_tenant_vector_store(tenant_info.tenant_id, collection_name)
    
    # Create empty index with the vector store
    vector_index = VectorStoreIndex.from_vector_store(vector_store)
    
    # Configure retriever
    retriever = VectorIndexRetriever(
        index=vector_index,
        similarity_top_k=similarity_top_k
    )
    
    # Get LLM based on tenant tier
    llm = get_llm_for_tenant(tenant_info, llm_model)
    
    # Create response synthesizer based on response mode
    response_synthesizer = ResponseSynthesizer.from_args(
        response_mode=response_mode,
        llm=llm,
        callback_manager=callback_manager
    )
    
    # Create the query engine
    query_engine = RetrieverQueryEngine(
        retriever=retriever,
        response_synthesizer=response_synthesizer,
        node_postprocessors=[
            SimilarityPostprocessor(similarity_cutoff=0.7)
        ]
    )
    
    return query_engine

# Track token usage
async def track_token_usage(tenant_id: str, estimated_tokens: int, model: str):
    """Track token usage for billing and quotas"""
    
    try:
        # Adjust cost factor based on model
        model_cost_factor = {
            "gpt-3.5-turbo": 1.0,
            "gpt-4-turbo": 5.0,
            "gpt-4-turbo-vision": 10.0,
            "claude-3-5-sonnet": 8.0
        }
        
        cost_factor = model_cost_factor.get(model, 1.0)
        adjusted_tokens = int(estimated_tokens * cost_factor)
        
        # Call the token usage tracking function
        supabase.rpc(
            "increment_token_usage",
            {
                "p_tenant_id": tenant_id,
                "p_tokens": adjusted_tokens
            }
        ).execute()
    except Exception as e:
        logger.error(f"Error tracking token usage: {str(e)}")

# API endpoints
@app.post("/query", response_model=QueryResponse)
async def process_query(
    request: QueryRequest,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    """Process a search query using RAG and return results with sources"""
    
    start_time = time.time()
    
    # Check quotas
    await check_tenant_quotas(tenant_info)
    
    try:
        # Create query engine
        query_engine = await create_query_engine(
            tenant_info=tenant_info,
            collection_name=request.collection_name,
            llm_model=request.llm_model,
            similarity_top_k=request.similarity_top_k or 4,
            response_mode=request.response_mode or "compact"
        )
        
        # Execute query
        response = await query_engine.aquery(request.query)
        
        # Extract source nodes
        source_nodes: List[QueryContextItem] = []
        if hasattr(response, "source_nodes"):
            for node in response.source_nodes:
                metadata = node.node.metadata.copy() if node.node.metadata else {}
                
                # Remove tenant-specific metadata that's not relevant to return
                if "tenant_id" in metadata:
                    del metadata["tenant_id"]
                
                source_nodes.append(
                    QueryContextItem(
                        text=node.node.text,
                        metadata=metadata,
                        score=node.score if hasattr(node, "score") else None
                    )
                )
        
        # Estimate token usage (very approximate)
        query_tokens = len(request.query.split()) * 1.3
        response_tokens = len(str(response).split()) * 1.3
        context_tokens = sum([len(node.text.split()) for node in source_nodes]) * 0.5  # Only count fraction as they're embeddings
        total_tokens = int(query_tokens + response_tokens + context_tokens)
        
        # Get actual LLM model used
        llm = get_llm_for_tenant(tenant_info, request.llm_model)
        actual_model = llm.model
        
        # Track usage
        await track_token_usage(request.tenant_id, total_tokens, actual_model)
        
        # Log query for analytics
        try:
            supabase.table("query_logs").insert({
                "tenant_id": request.tenant_id,
                "query": request.query,
                "collection": request.collection_name,
                "llm_model": actual_model,
                "tokens_estimated": total_tokens,
                "response_time_ms": int((time.time() - start_time) * 1000)
            }).execute()
        except Exception as e:
            logger.error(f"Error logging query: {str(e)}")
        
        return QueryResponse(
            tenant_id=request.tenant_id,
            query=request.query,
            response=str(response),
            sources=source_nodes,
            processing_time=time.time() - start_time,
            llm_model=actual_model,
            collection_name=request.collection_name or "default"
        )
    
    except Exception as e:
        logger.error(f"Error processing query: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Error processing query: {str(e)}"
        )

@app.get("/documents", response_model=DocumentsListResponse)
async def list_documents(
    tenant_id: str,
    collection_name: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    """List documents for a tenant with optional filtering by collection"""
    
    # Security check - only allow a tenant to see their own documents
    if tenant_id != tenant_info.tenant_id:
        raise HTTPException(
            status_code=403,
            detail="You can only access your own documents"
        )
    
    try:
        # Query to get unique document IDs and metadata
        query = supabase.table("document_chunks").select("metadata")
        
        # Add filters
        query = query.eq("tenant_id", tenant_id)
        if collection_name:
            query = query.filter("metadata->collection", "eq", collection_name)
        
        # Execute query
        result = query.execute()
        
        if not result.data:
            return DocumentsListResponse(
                tenant_id=tenant_id,
                documents=[],
                total=0,
                limit=limit,
                offset=offset,
                collection_name=collection_name
            )
        
        # Extract unique document IDs and their metadata
        document_map = {}
        for chunk in result.data:
            metadata = chunk["metadata"]
            if "document_id" in metadata:
                doc_id = metadata["document_id"]
                if doc_id not in document_map:
                    # Extract document metadata
                    doc_info = {
                        "document_id": doc_id,
                        "source": metadata.get("source", "Unknown"),
                        "author": metadata.get("author"),
                        "document_type": metadata.get("document_type"),
                        "collection": metadata.get("collection", "default"),
                        "created_at": metadata.get("created_at")
                    }
                    document_map[doc_id] = doc_info
        
        # Convert to list and apply pagination
        documents = list(document_map.values())
        total = len(documents)
        
        # Simple pagination
        paginated_documents = documents[offset:offset+limit]
        
        return DocumentsListResponse(
            tenant_id=tenant_id,
            documents=paginated_documents,
            total=total,
            limit=limit,
            offset=offset,
            collection_name=collection_name
        )
    
    except Exception as e:
        logger.error(f"Error listing documents: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Error listing documents: {str(e)}"
        )

@app.get("/collections", response_model=Dict[str, Any])
async def list_collections(
    tenant_id: str,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    """List all collections for a tenant"""
    
    # Security check - only allow a tenant to see their own collections
    if tenant_id != tenant_info.tenant_id:
        raise HTTPException(
            status_code=403,
            detail="You can only access your own collections"
        )
    
    try:
        # Query to get all collections
        query = supabase.table("document_chunks").select("metadata->collection")
        
        # Add tenant filter
        query = query.eq("tenant_id", tenant_id)
        
        # Execute query
        result = query.execute()
        
        if not result.data:
            return {"collections": []}
        
        # Extract unique collection names
        collections = set()
        for row in result.data:
            collection = row.get("collection")
            if collection:
                collections.add(collection)
        
        # Get document counts for each collection
        collection_stats = []
        for collection in collections:
            # Count documents in this collection
            count_query = supabase.table("document_chunks").select("metadata->document_id", "count")
            count_query = count_query.eq("tenant_id", tenant_id)
            count_query = count_query.filter("metadata->collection", "eq", collection)
            count_result = count_query.execute()
            
            document_count = 0
            if count_result.data and count_result.data[0].get("count"):
                document_count = count_result.data[0]["count"]
            
            collection_stats.append({
                "name": collection,
                "document_count": document_count
            })
        
        return {
            "tenant_id": tenant_id,
            "collections": collection_stats
        }
    
    except Exception as e:
        logger.error(f"Error listing collections: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Error listing collections: {str(e)}"
        )

@app.get("/healthcheck", response_model=HealthcheckResponse)
async def healthcheck():
    """Check the health of the service and its dependencies"""
    
    try:
        # Check if Supabase is available
        supabase_status = "available"
        try:
            supabase.table("tenants").select("tenant_id").limit(1).execute()
        except Exception:
            supabase_status = "unavailable"
        
        # Check if Redis is available
        redis_status = "available" if redis_client and redis_client.ping() else "unavailable"
        
        # Check if embedding service is available
        embedding_status = "available"
        try:
            response = await http_client.get(f"{EMBEDDINGS_SERVICE_URL}/status")
            if response.status_code != 200:
                embedding_status = "degraded"
        except Exception:
            embedding_status = "unavailable"
        
        # Overall status
        overall_status = "healthy"
        if "unavailable" in [supabase_status, redis_status, embedding_status]:
            overall_status = "degraded"
        
        return HealthcheckResponse(
            status=overall_status,
            components={
                "supabase": supabase_status,
                "redis": redis_status,
                "embedding_service": embedding_status
            },
            version="1.0.0"
        )
    
    except Exception as e:
        logger.error(f"Error in healthcheck: {str(e)}")
        return HealthcheckResponse(
            status="error",
            components={
                "error": str(e)
            },
            version="1.0.0"
        )

@app.get("/llm/models")
async def list_llm_models(
    tenant_id: str,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    """List available LLM models based on tenant subscription tier"""
    
    # Map subscription tiers to allowed models
    tier_models = {
        "free": [
            {
                "id": "gpt-3.5-turbo",
                "name": "GPT-3.5 Turbo",
                "provider": "openai",
                "description": "Fast and cost-effective model for most queries"
            }
        ],
        "pro": [
            {
                "id": "gpt-3.5-turbo",
                "name": "GPT-3.5 Turbo",
                "provider": "openai",
                "description": "Fast and cost-effective model for most queries"
            },
            {
                "id": "gpt-4-turbo",
                "name": "GPT-4 Turbo",
                "provider": "openai",
                "description": "Advanced reasoning capabilities for complex queries"
            }
        ],
        "business": [
            {
                "id": "gpt-3.5-turbo",
                "name": "GPT-3.5 Turbo",
                "provider": "openai",
                "description": "Fast and cost-effective model for most queries"
            },
            {
                "id": "gpt-4-turbo",
                "name": "GPT-4 Turbo",
                "provider": "openai",
                "description": "Advanced reasoning capabilities for complex queries"
            },
            {
                "id": "gpt-4-turbo-vision",
                "name": "GPT-4 Turbo Vision",
                "provider": "openai",
                "description": "Vision capabilities for image analysis (if needed)"
            },
            {
                "id": "claude-3-5-sonnet",
                "name": "Claude 3.5 Sonnet",
                "provider": "anthropic",
                "description": "Alternative model with excellent instruction following"
            }
        ]
    }
    
    # Get allowed models for tenant tier
    available_models = tier_models.get(tenant_info.subscription_tier, [])
    
    return {
        "models": available_models
    }

@app.get("/stats")
async def get_tenant_stats(
    tenant_id: str,
    tenant_info: TenantInfo = Depends(verify_tenant)
):
    """Get usage statistics for a tenant"""
    
    # Security check - only allow a tenant to see their own stats
    if tenant_id != tenant_info.tenant_id:
        raise HTTPException(
            status_code=403,
            detail="You can only access your own statistics"
        )
    
    try:
        # Get tenant stats
        stats_query = supabase.table("tenant_stats").select("*").eq("tenant_id", tenant_id).execute()
        
        if not stats_query.data:
            return {
                "tenant_id": tenant_id,
                "document_count": 0,
                "tokens_used": 0,
                "last_activity": None
            }
        
        stats = stats_query.data[0]
        
        # Get query logs for recent activity
        logs_query = supabase.table("query_logs").select("*") \
            .eq("tenant_id", tenant_id) \
            .order("created_at", desc=True) \
            .limit(5) \
            .execute()
        
        recent_queries = logs_query.data if logs_query.data else []
        
        # Get subscription info
        sub_query = supabase.table("tenant_subscriptions").select("*") \
            .eq("tenant_id", tenant_id) \
            .eq("is_active", True) \
            .execute()
        
        subscription = sub_query.data[0] if sub_query.data else None
        
        # Get tier limits
        tier = tenant_info.subscription_tier
        tier_query = supabase.table("tenant_features").select("*").eq("tier", tier).execute()
        tier_limits = tier_query.data[0] if tier_query.data else None
        
        return {
            "tenant_id": tenant_id,
            "document_count": stats.get("document_count", 0),
            "tokens_used": stats.get("tokens_used", 0),
            "last_activity": stats.get("last_activity"),
            "token_limit": tier_limits.get("max_tokens_per_month") if tier_limits else None,
            "subscription": {
                "tier": tier,
                "started_at": subscription.get("started_at") if subscription else None,
                "expires_at": subscription.get("expires_at") if subscription else None
            },
            "recent_queries": [
                {
                    "query": q.get("query"),
                    "collection": q.get("collection"),
                    "llm_model": q.get("llm_model"),
                    "tokens": q.get("tokens_estimated"),
                    "timestamp": q.get("created_at")
                } for q in recent_queries
            ]
        }
    
    except Exception as e:
        logger.error(f"Error getting tenant stats: {str(e)}")
        raise HTTPException(
            status_code=500,
            detail=f"Error getting tenant stats: {str(e)}"
        )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8002)