# Enterprise Healthcare Data Platform: Automated AWS & Snowflake ELT Pipeline

An event-driven, production-grade cloud data engineering platform designed to ingest, process, and securely warehouse multi-vendor clinical vitals data. 

This repository demonstrates an advanced **Dynamic Compute Router Pattern** using AWS serverless architectures coupled with an automated, idempotent Change Data Capture (CDC) engine inside Snowflake.

---

## 🏗️ Architecture Blueprint

The platform implements a decoupled, three-tier data lake pattern optimized for operational cost efficiency and strict HIPAA data governance.

```mermaid
graph TD
    %% Styling Configuration
    classDef bronze fill:#b9770e,stroke:#333,stroke-width:2px,color:#fff;
    classDef router fill:#2471a3,stroke:#333,stroke-width:2px,color:#fff;
    classDef silver fill:#7d6608,stroke:#333,stroke-width:2px,color:#fff;
    classDef gold fill:#d4ac0d,stroke:#333,stroke-width:2px,color:#111;

    subgraph BRONZE_TIER [1. Bronze Ingestion Tier]
        A[Multi-Vendor Files<br>CSV / XML Drops] --> B(S3 Ingestion Bucket<br>Bronze Data Lake)
        B -->|S3 Event Notification| C[AWS SQS FIFO Queue<br>Ingestion Throttle]
    end
    class B,C bronze;

    subgraph COMPUTE_ROUTER [2. Dynamic Compute Router Gate]
        C --> D{Router Lambda Cop<br>Inspects File Size}
        D -->|< 50MB| E[Transformer Lambda<br>Serverless Compute]
        D -->|≥ 50MB or .xml| F[AWS Glue Spark Job<br>Distributed Cluster]
    end
    class D,E,F router;

    subgraph SILVER_TIER [3. Silver Storage Tier]
        E -->|Salted HMAC-SHA256 Masking| G(S3 Optimized Storage<br>Silver Lake: Parquet)
        F -->|Salted HMAC-SHA256 Masking| G
        G -->|Automated Snowpipe| H[(Snowflake Staging<br>Append-Only Table)]
    end
    class G,H silver;

    subgraph GOLD_WAREHOUSE [4. Change Data Capture Gold Warehouse]
        H -->|Continuous CDC| I[Snowflake Data Stream<br>Transaction Bookmark]
        I -->|CRON Trigger Condition| J{Snowflake Task<br>Windowed Deduplication}
        J -->|Idempotent MERGE| K[(CLINICAL_GOLD<br>FACT_PATIENT_VITALS)]
    end
    class I,J,K gold;
```
----

### 🧠 Core Engineering Design Patterns

1. **Dynamic Compute Routing:** To balance execution velocity against cloud expenditure, a lightweight traffic cop Lambda inspects file payloads streaming from an **SQS FIFO Queue**. Micro-batches under 50MB bypass heavy infrastructure and invoke an asynchronous, serverless Lambda execution tier. Payload files exceeding 50MB or requiring nested schema parsing (.xml) are routed to auto-scaling **AWS Glue (PySpark)** clusters to avoid execution timeouts.
2. **Cryptographic PHI Governance:** To ensure HIPAA alignment, sensitive patient cleartext identifiers (`patient_id`) are intercepted at the cloud compute boundary. A deterministic hash is generated using **HMAC SHA-256** combined with a secret, rotating organizational salt token. This eliminates the storage of raw protected health information while preserving relational join integrity across analytical pipelines.
3. **Idempotent Storage Strategy:** Concurrent network file drops can introduce duplicated transaction boundaries. To enforce absolute database idempotency, data is loaded via Snowpipe into an append-only staging table. A reactive Snowflake **Stream** acts as a micro-batch cursor tracking updates. An automated Snowflake **Task** uses windowed deduplication partition passes (`QUALIFY ROW_NUMBER()`) and updates the production Gold tier via an atomic atomic table `MERGE`.

---

## 📂 Repository Structure

```text
healthcare-data-platform-aws-snowflake/
├── .github/workflows/
│   └── ci-cd-pipeline.yml     # CI/CD: Automated Python linters & PyTest suites
├── terraform/                  # Infrastructure as Code (IaC) Tier
│   ├── main.tf                 # Core cloud network and permission architectures
│   ├── variables.tf            # Environment input mappings
│   └── providers.tf            # State-locking configuration blocks
├── src/                        # Compute Application Tier
│   ├── lambda/
│   │   ├── router_handler.py   # Traffic cop file size inspector
│   │   ├── lambda_function.py  # Lightweight Parquet processing module
│   │   └── test_lambda.py      # Deterministic validation and testing blocks
│   └── glue/
│       └── glue_spark_job.py   # Scale-out PySpark transformation script
├── snowflake/                  # Enterprise Warehousing Tier
│   └── setup_warehouse.sql     # Streams, tasks, clustering, and CDC architecture
└── README.md
