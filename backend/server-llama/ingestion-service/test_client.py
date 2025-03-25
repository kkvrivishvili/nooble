import requests
import json
import os
from dotenv import load_dotenv
import uuid

# Load environment variables
load_dotenv()

# Configuration
API_BASE_URL = "http://localhost:8000"
TENANT_ID = os.getenv("TEST_TENANT_ID", "00000000-0000-0000-0000-000000000000")  # Replace with a real tenant ID

def test_ingest_documents():
    """Test the /ingest endpoint with sample documents"""
    
    # Prepare sample documents
    documents = [
        "LlamaIndex es una herramienta potente para RAG. Permite indexar documentos y consultarlos con lenguaje natural.",
        "La arquitectura multitenancy implica que multiples clientes comparten la misma infraestructura pero con datos aislados."
    ]
    
    document_metadatas = [
        {
            "source": "manual",
            "author": "Juan Pérez",
            "document_type": "tech_doc",
            "tenant_id": TENANT_ID,
            "custom_metadata": {
                "category": "RAG",
                "importance": "high"
            }
        },
        {
            "source": "website",
            "author": "Ana García",
            "document_type": "architecture",
            "tenant_id": TENANT_ID,
            "custom_metadata": {
                "category": "Design",
                "importance": "medium"
            }
        }
    ]
    
    # Create request payload
    payload = {
        "tenant_id": TENANT_ID,
        "documents": documents,
        "document_metadatas": document_metadatas,
        "collection_name": "test_collection"
    }
    
    # Send request
    response = requests.post(f"{API_BASE_URL}/ingest", json=payload)
    
    # Print results
    print(f"Status Code: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    return response.json()

def test_file_upload():
    """Test file upload with a sample text file"""
    
    # Create a temporary test file
    test_file_path = "test_document.txt"
    with open(test_file_path, "w") as f:
        f.write("Este es un documento de prueba para el Servicio de Ingestión.\n")
        f.write("Contiene información que será procesada por LlamaIndex y indexada para RAG.\n")
        f.write("El sistema debe dividir este texto en chunks y generar embeddings para cada uno.")
    
    # Prepare form data
    form_data = {
        "tenant_id": TENANT_ID,
        "collection_name": "test_files",
        "document_type": "text_document",
        "author": "Test Script"
    }
    
    # Open file for upload
    with open(test_file_path, "rb") as f:
        files = {"file": (test_file_path, f, "text/plain")}
        
        # Send request
        response = requests.post(
            f"{API_BASE_URL}/ingest-file",
            data=form_data,
            files=files
        )
    
    # Print results
    print(f"Status Code: {response.status_code}")
    print(f"Response: {json.dumps(response.json(), indent=2)}")
    
    # Clean up