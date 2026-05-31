# Streamlit + DynamoDB Demo

This app inserts and queries DynamoDB items with fields:

- `id`
- `timestamp`

## 1) Create DynamoDB table

Recommended table schema:

- Partition key: `id` (String)
- Sort key: `timestamp` (String)

Use ISO-8601 timestamps (for example `2026-05-26T14:15:00+00:00`) so time ordering and range queries behave correctly.

## 2) Install dependencies

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 3) Run app

```bash
streamlit run app.py
```

## 4) Configure connection in sidebar

- AWS Region (for example `us-east-1`)
- Table Name
- DynamoDB Endpoint (optional, for local DynamoDB)

The app uses standard AWS credential resolution (environment variables, AWS profile, IAM role, etc.).
# extend-db-hybrid
